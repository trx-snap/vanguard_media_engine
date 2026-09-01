#pragma once
// P5-COMPOSITOR-TRANS (sub-slice NODE-TOPOLOGY-MATH): VGTimelineCompositorNode
// pure C++ DAG topology plus timeline clip overlap / transition progress
// evaluation math foundation.
//
// This header carries NO pixel, texture, GPU, decoder, or render state. It only
// exposes:
//   * plain descriptor structs for timeline clips and transitions,
//   * pure, side-effect-free evaluation functions (testable without a graph),
//   * a logical DAG processing node wrapping those functions.
//
// No Vulkan/GLES rendering, shader blend routines, MediaCodec decode
// synchronization, or export-session integration lives here; those remain
// open work under P5-COMPOSITOR-TRANS.

#include "vanguard/graph/node.h"

#include <cstdint>
#include <string>
#include <vector>

namespace vanguard {
namespace compositors {

// Transition family applied during a clip overlap window.
enum class TransitionType {
    kNone,
    kCrossfade,
    kWipeLeft,
    kWipeRight,
    kWipeUp,
    kWipeDown,
    kSlideLeft,
    kSlideRight,
    kSlideUp,
    kSlideDown
};

// A single clip placed on the timeline.
//
// Activity interval: [timelineStartPtsUs, timelineStartPtsUs + durationUs),
// end-exclusive, with the end saturating at UINT64_MAX instead of wrapping.
// A zero-duration clip is never active.
//
// Local PTS mapping:
//   sourceTrimInPtsUs + floor((timelinePtsUs - timelineStartPtsUs) * speedRatio)
// where a non-finite or non-positive speedRatio is sanitized to 1.0 and every
// intermediate result saturates at UINT64_MAX.
struct TimelineClipDescriptor {
    std::string clipId;
    uint64_t    timelineStartPtsUs = 0;
    uint64_t    durationUs         = 0;
    uint64_t    sourceTrimInPtsUs  = 0;
    double      speedRatio         = 1.0;
};

// A transition between two clips over an explicit timeline window.
//
// Active interval: [timelineStartPtsUs, timelineStartPtsUs + durationUs),
// end-exclusive, saturating. Documented zero-duration choice: a transition
// with durationUs == 0 is NEVER active (it degenerates to a hard cut), so
// progress evaluation never divides by zero.
struct TimelineTransitionDescriptor {
    std::string    transitionId;
    TransitionType type = TransitionType::kNone;
    std::string    fromClipId;
    std::string    toClipId;
    uint64_t       timelineStartPtsUs = 0;
    uint64_t       durationUs         = 0;
};

// Rectangle in normalized canvas coordinates (top-left origin, Y-down).
// Named distinctly from the MultiCam `NormalizedRect` so both headers can be
// included in one translation unit without ODR/redefinition conflicts.
//
// Viewport rects describe where a layer is placed on the canvas and MAY lie
// outside [0,1] on x/y to describe off-canvas slide motion. Crop rects
// describe which portion of the source layer is visible and are always
// inside [0,1]. Every field is guaranteed finite.
struct TimelineNormalizedRect {
    double x      = 0.0;
    double y      = 0.0;
    double width  = 1.0;
    double height = 1.0;
};

// Resolved transition progress and geometry at one timeline instant.
//
// Blend weights: for kCrossfade, from = 1 - progress and to = progress. For
// slide/wipe families both layers are fully opaque (1.0) and the geometry
// alone describes visibility. When no transition is active the struct holds
// identity geometry with from = 1.0, to = 0.0.
struct TimelineTransitionProgress {
    bool                   isTransitionActive = false;
    TransitionType         type               = TransitionType::kNone;
    double                 progress           = 0.0;
    double                 blendWeightFrom    = 1.0;
    double                 blendWeightTo      = 0.0;
    TimelineNormalizedRect fromViewport;
    TimelineNormalizedRect toViewport;
    TimelineNormalizedRect fromCrop;
    TimelineNormalizedRect toCrop;
};

// Full composition state at one timeline instant.
//
// * hasActiveClip == false: nothing to composite (identity transition).
// * hasActiveClip == true, transition inactive: primary clip solo (hard cut).
// * hasActiveClip == true, transition active: primary == transition "from"
//   clip, secondary == transition "to" clip, both local PTS derived from
//   their own descriptors.
struct TimelineCompositionState {
    bool                       hasActiveClip       = false;
    std::string                primaryClipId;
    uint64_t                   primaryLocalPtsUs   = 0;
    std::string                secondaryClipId;
    uint64_t                   secondaryLocalPtsUs = 0;
    TimelineTransitionProgress transition;
};

// ── Pure helper math (no node/graph state) ──────────────────────────────────

// a + b saturating at UINT64_MAX (never wraps).
uint64_t SaturatingAddPtsUs(uint64_t a, uint64_t b);

// End-exclusive clip end: timelineStartPtsUs + durationUs, saturating.
uint64_t ClipEndPtsUs(const TimelineClipDescriptor& clip);

// True when timelinePtsUs lies inside [start, start + duration).
bool IsClipActiveAt(const TimelineClipDescriptor& clip, uint64_t timelinePtsUs);

// Local (source) PTS for a timeline instant. When timelinePtsUs precedes the
// clip start the delta is clamped to zero (result == sourceTrimInPtsUs).
uint64_t MapClipTimelineToLocalPts(const TimelineClipDescriptor& clip, uint64_t timelinePtsUs);

// True when timelinePtsUs lies inside the transition window and the window
// has non-zero duration.
bool IsTransitionActiveAt(const TimelineTransitionDescriptor& transition, uint64_t timelinePtsUs);

// Normalized progress in [0,1] for an active transition; 0.0 when inactive.
double TransitionProgressAt(const TimelineTransitionDescriptor& transition, uint64_t timelinePtsUs);

// Pure geometry/weights for a transition family at progress p (clamped to
// [0,1], non-finite sanitized to 0). kNone yields an inactive identity result.
TimelineTransitionProgress ComputeTransitionGeometry(TransitionType type, double progress);

// Full evaluation entry point (pure function).
//
// Selection rules:
//  1. The first transition (in vector order) whose window contains
//     timelinePtsUs, whose type != kNone, and whose from/to clip IDs both
//     resolve to distinct descriptors in `clips` wins. Its endpoints are not
//     required to be active by their own intervals; the transition window
//     itself defines the overlap.
//  2. Transitions with unknown/identical endpoint IDs or zero duration are
//     ignored (fail-safe), falling through to hard-cut evaluation.
//  3. Hard-cut primary: among clips active by interval, the one with the
//     greatest timelineStartPtsUs (later-placed clip wins); ties keep vector
//     order (first wins).
//  4. Nothing active: hasActiveClip == false with identity geometry.
TimelineCompositionState EvaluateTimelineComposition(
    uint64_t                                          timelinePtsUs,
    const std::vector<TimelineClipDescriptor>&        clips,
    const std::vector<TimelineTransitionDescriptor>&  transitions);

// ── Logical DAG node ────────────────────────────────────────────────────────

// Two-input timeline compositor processing node. Carries only DAG topology
// (ports/kind/type) plus the clip/transition descriptor lists needed to
// evaluate the pure math above at a timeline instant.
//
// Node timeline overrides are derived from evaluate():
//   * isActiveAt            -> evaluate(pts).hasActiveClip
//   * mapTimelineToLocalPts -> primaryLocalPtsUs when active, else pts
//   * blendWeightAt         -> primary clip weight: transition.blendWeightFrom
//                              when a transition is active, 1.0 when a clip is
//                              solo, 0.0 when nothing is active.
class VGTimelineCompositorNode : public vanguard::graph::Node {
public:
    explicit VGTimelineCompositorNode(std::string id);

    const std::string&                                  id()          const override;
    vanguard::graph::NodeKind                           kind()        const override;
    vanguard::graph::NodeType                           type()        const override;
    const std::vector<vanguard::graph::PortDescriptor>& inputPorts()  const override;
    const std::vector<vanguard::graph::PortDescriptor>& outputPorts() const override;

    bool     isActiveAt(uint64_t timelinePtsUs) const override;
    uint64_t mapTimelineToLocalPts(uint64_t timelinePtsUs) const override;
    float    blendWeightAt(uint64_t timelinePtsUs) const override;

    void setClips(std::vector<TimelineClipDescriptor> clips);
    void setTransitions(std::vector<TimelineTransitionDescriptor> transitions);

    const std::vector<TimelineClipDescriptor>&       clips()       const;
    const std::vector<TimelineTransitionDescriptor>& transitions() const;

    TimelineCompositionState evaluate(uint64_t timelinePtsUs) const;

private:
    std::string                                   id_;
    std::vector<vanguard::graph::PortDescriptor>  inputPorts_;
    std::vector<vanguard::graph::PortDescriptor>  outputPorts_;
    std::vector<TimelineClipDescriptor>           clips_;
    std::vector<TimelineTransitionDescriptor>     transitions_;
};

} // namespace compositors
} // namespace vanguard
