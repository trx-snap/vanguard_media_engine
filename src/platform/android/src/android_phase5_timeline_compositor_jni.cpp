// P5-COMPOSITOR-TRANS (sub-slice NODE-TOPOLOGY-MATH): VGTimelineCompositorNode
// native topology + clip overlap / transition progress math foundation
// validation diagnostic. Pure in-memory C++ math only: no threads, no
// MediaCodec, no GLES/Vulkan, no file IO, no export session. This diagnostic
// constructs vanguard::compositors::VGTimelineCompositorNode instances with
// synthetic clip/transition descriptors and gates the evaluated composition
// state against the frozen acceptance scenarios.
//
// This translation unit is Android-only and must NOT be included in iOS or
// host builds. It is added via the Android-only target_sources block in
// src/CMakeLists.txt.
//
// JNI entry point (matching VanguardNativeBridge.kt P5-COMPOSITOR-TRANS
// declaration):
//   runAndroidDagPhase5TimelineCompositorSmoke -> jstring (JSON object)

#include <jni.h>

#include <cmath>
#include <cstdint>
#include <cstdio>
#include <limits>
#include <sstream>
#include <string>
#include <vector>

#include "vanguard/compositors/vg_timeline_compositor_node.h"
#include "vanguard/graph/node.h"

namespace {

using vanguard::compositors::EvaluateTimelineComposition;
using vanguard::compositors::TimelineClipDescriptor;
using vanguard::compositors::TimelineCompositionState;
using vanguard::compositors::TimelineNormalizedRect;
using vanguard::compositors::TimelineTransitionDescriptor;
using vanguard::compositors::TransitionType;
using vanguard::compositors::VGTimelineCompositorNode;

constexpr const char* kProofBoundary =
    "native_vg_timeline_compositor_node_topology_and_transition_math_only_no_render_no_decode";
constexpr const char* kPassMarker =
    "ANDROID_DAG_PHASE5_TIMELINE_COMPOSITOR_NODE_TOPOLOGY_MATH_PHYSICAL_SMOKE_PASS";
constexpr const char* kFailMarker =
    "ANDROID_DAG_PHASE5_TIMELINE_COMPOSITOR_NODE_TOPOLOGY_MATH_PHYSICAL_SMOKE_FAIL";

constexpr double   kEpsilon = 1e-9;
constexpr uint64_t kMaxPts  = std::numeric_limits<uint64_t>::max();

bool NearlyEqual(double a, double b, double epsilon = kEpsilon) {
    return std::isfinite(a) && std::isfinite(b) && std::fabs(a - b) <= epsilon;
}

bool RectIsFinite(const TimelineNormalizedRect& r) {
    return std::isfinite(r.x) && std::isfinite(r.y) &&
           std::isfinite(r.width) && std::isfinite(r.height);
}

bool RectNearlyEquals(const TimelineNormalizedRect& r, double x, double y, double w, double h) {
    return NearlyEqual(r.x, x) && NearlyEqual(r.y, y) &&
           NearlyEqual(r.width, w) && NearlyEqual(r.height, h);
}

bool RectIsIdentity(const TimelineNormalizedRect& r) {
    return RectNearlyEquals(r, 0.0, 0.0, 1.0, 1.0);
}

bool GeometryIsIdentityInactive(const TimelineCompositionState& s) {
    return !s.transition.isTransitionActive &&
           s.transition.type == TransitionType::kNone &&
           NearlyEqual(s.transition.progress, 0.0) &&
           NearlyEqual(s.transition.blendWeightFrom, 1.0) &&
           NearlyEqual(s.transition.blendWeightTo, 0.0) &&
           RectIsIdentity(s.transition.fromViewport) &&
           RectIsIdentity(s.transition.toViewport) &&
           RectIsIdentity(s.transition.fromCrop) &&
           RectIsIdentity(s.transition.toCrop);
}

bool GeometryIsFinite(const TimelineCompositionState& s) {
    return std::isfinite(s.transition.progress) &&
           std::isfinite(s.transition.blendWeightFrom) &&
           std::isfinite(s.transition.blendWeightTo) &&
           RectIsFinite(s.transition.fromViewport) &&
           RectIsFinite(s.transition.toViewport) &&
           RectIsFinite(s.transition.fromCrop) &&
           RectIsFinite(s.transition.toCrop);
}

TimelineClipDescriptor MakeClip(const char* id,
                                uint64_t start,
                                uint64_t duration,
                                uint64_t trimIn,
                                double speed) {
    TimelineClipDescriptor clip;
    clip.clipId             = id;
    clip.timelineStartPtsUs = start;
    clip.durationUs         = duration;
    clip.sourceTrimInPtsUs  = trimIn;
    clip.speedRatio         = speed;
    return clip;
}

TimelineTransitionDescriptor MakeTransition(const char* id,
                                            TransitionType type,
                                            const char* from,
                                            const char* to,
                                            uint64_t start,
                                            uint64_t duration) {
    TimelineTransitionDescriptor t;
    t.transitionId       = id;
    t.type               = type;
    t.fromClipId         = from;
    t.toClipId           = to;
    t.timelineStartPtsUs = start;
    t.durationUs         = duration;
    return t;
}

// Minimal JSON string escaper; all emitted values are ASCII diagnostics.
std::string JsonEscape(const std::string& in) {
    std::string out;
    out.reserve(in.size() + 8);
    for (const char c : in) {
        switch (c) {
            case '"':  out += "\\\""; break;
            case '\\': out += "\\\\"; break;
            case '\n': out += "\\n";  break;
            case '\r': out += "\\r";  break;
            case '\t': out += "\\t";  break;
            default:
                if (static_cast<unsigned char>(c) < 0x20) {
                    char buf[8];
                    std::snprintf(buf, sizeof(buf), "\\u%04x", static_cast<unsigned>(c));
                    out += buf;
                } else {
                    out += c;
                }
        }
    }
    return out;
}

const char* BoolStr(bool v) { return v ? "true" : "false"; }

} // namespace

extern "C" JNIEXPORT jstring JNICALL
Java_com_connects_vanguard_1media_1engine_bridge_VanguardNativeBridge_runAndroidDagPhase5TimelineCompositorSmoke(
    JNIEnv* env,
    jobject /* this */) {

    std::string failureReason;
    auto fail = [&failureReason](const char* reason) {
        if (failureReason.empty()) {
            failureReason = reason;
        }
    };

    // ── Scenario 1: DAG topology ────────────────────────────────────────────
    VGTimelineCompositorNode node("timeline_compositor_node_smoke");
    const bool kindOk = node.kind() == vanguard::graph::NodeKind::kProcessing;
    const bool typeOk = node.type() == vanguard::graph::NodeType::kVGTimelineCompositor;
    const auto& inputs  = node.inputPorts();
    const auto& outputs = node.outputPorts();
    const bool inputPortCountOk  = inputs.size() == 2;
    const bool outputPortCountOk = outputs.size() == 1;
    const bool portIdsOk =
        inputPortCountOk && outputPortCountOk &&
        inputs[0].id == "clip_0_video_in" &&
        inputs[0].dataType == vanguard::graph::PortDataType::kVideoFrame &&
        inputs[1].id == "clip_1_video_in" &&
        inputs[1].dataType == vanguard::graph::PortDataType::kVideoFrame &&
        outputs[0].id == "composited_video_out" &&
        outputs[0].dataType == vanguard::graph::PortDataType::kVideoFrame &&
        node.id() == "timeline_compositor_node_smoke";
    if (!kindOk)            fail("node_kind_not_processing");
    if (!typeOk)            fail("node_type_not_vg_timeline_compositor");
    if (!inputPortCountOk)  fail("input_port_count_mismatch");
    if (!outputPortCountOk) fail("output_port_count_mismatch");
    if (!portIdsOk)         fail("port_ids_mismatch");

    // ── Scenario 2: single-clip speed mapping ───────────────────────────────
    bool speedMappingOk = false;
    {
        const double nan = std::numeric_limits<double>::quiet_NaN();
        VGTimelineCompositorNode n("speed");
        n.setClips({MakeClip("A", 1000000, 2000000, 500000, 1.0)});
        const auto s1 = n.evaluate(1250000);
        const bool speed1Ok = s1.hasActiveClip && s1.primaryClipId == "A" &&
                              s1.primaryLocalPtsUs == 750000 &&
                              n.mapTimelineToLocalPts(1250000) == 750000;

        n.setClips({MakeClip("A", 1000000, 2000000, 500000, 2.0)});
        const auto s2 = n.evaluate(1250000);
        const bool speed2Ok = s2.hasActiveClip && s2.primaryLocalPtsUs == 1000000 &&
                              n.mapTimelineToLocalPts(1250000) == 1000000;

        // Half speed uses floor(): 250000 * 0.5 = 125000 exactly.
        n.setClips({MakeClip("A", 1000000, 2000000, 500000, 0.5)});
        const bool speedHalfOk = n.evaluate(1250000).primaryLocalPtsUs == 625000;

        // Non-positive / non-finite speeds sanitize to 1.0.
        n.setClips({MakeClip("A", 1000000, 2000000, 500000, 0.0)});
        const bool speedZeroOk = n.evaluate(1250000).primaryLocalPtsUs == 750000;
        n.setClips({MakeClip("A", 1000000, 2000000, 500000, -3.0)});
        const bool speedNegOk = n.evaluate(1250000).primaryLocalPtsUs == 750000;
        n.setClips({MakeClip("A", 1000000, 2000000, 500000, nan)});
        const bool speedNanOk = n.evaluate(1250000).primaryLocalPtsUs == 750000;

        speedMappingOk = speed1Ok && speed2Ok && speedHalfOk &&
                         speedZeroOk && speedNegOk && speedNanOk;
        if (!speedMappingOk) fail("speed_mapping_mismatch");
    }

    // ── Scenario 3: hard cuts ───────────────────────────────────────────────
    bool hardCutOk = false;
    {
        VGTimelineCompositorNode n("hardcut");
        n.setClips({MakeClip("A", 0, 2000000, 0, 1.0),
                    MakeClip("B", 2000000, 2000000, 0, 1.0)});
        const auto sA = n.evaluate(1999999);
        const auto sB = n.evaluate(2000000);
        const bool aOk = sA.hasActiveClip && sA.primaryClipId == "A" &&
                         sA.primaryLocalPtsUs == 1999999 &&
                         sA.secondaryClipId.empty() &&
                         GeometryIsIdentityInactive(sA);
        const bool bOk = sB.hasActiveClip && sB.primaryClipId == "B" &&
                         sB.primaryLocalPtsUs == 0 &&
                         sB.secondaryClipId.empty() &&
                         GeometryIsIdentityInactive(sB);
        // Node timeline overrides mirror evaluate().
        const bool overridesOk =
            n.isActiveAt(1999999) && n.isActiveAt(2000000) &&
            !n.isActiveAt(4000000) &&
            n.mapTimelineToLocalPts(1999999) == 1999999 &&
            n.mapTimelineToLocalPts(2000000) == 0 &&
            NearlyEqual(n.blendWeightAt(1999999), 1.0) &&
            NearlyEqual(n.blendWeightAt(2000000), 1.0) &&
            NearlyEqual(n.blendWeightAt(4000000), 0.0);
        hardCutOk = aOk && bOk && overridesOk;
        if (!hardCutOk) fail("hard_cut_mismatch");
    }

    // ── Scenario 4: crossfade start / mid / end ─────────────────────────────
    bool crossfadeStartOk = false;
    bool crossfadeMidOk   = false;
    bool crossfadeEndOk   = false;
    {
        VGTimelineCompositorNode n("crossfade");
        n.setClips({MakeClip("A", 0, 2000000, 0, 1.0),
                    MakeClip("B", 1500000, 2000000, 0, 1.0)});
        n.setTransitions({MakeTransition("xfade", TransitionType::kCrossfade,
                                         "A", "B", 1500000, 500000)});

        const auto s0 = n.evaluate(1500000);
        crossfadeStartOk =
            s0.hasActiveClip && s0.transition.isTransitionActive &&
            s0.transition.type == TransitionType::kCrossfade &&
            s0.primaryClipId == "A" && s0.primaryLocalPtsUs == 1500000 &&
            s0.secondaryClipId == "B" && s0.secondaryLocalPtsUs == 0 &&
            NearlyEqual(s0.transition.progress, 0.0) &&
            NearlyEqual(s0.transition.blendWeightFrom, 1.0) &&
            NearlyEqual(s0.transition.blendWeightTo, 0.0) &&
            RectIsIdentity(s0.transition.fromViewport) &&
            RectIsIdentity(s0.transition.toViewport) &&
            RectIsIdentity(s0.transition.fromCrop) &&
            RectIsIdentity(s0.transition.toCrop);
        if (!crossfadeStartOk) fail("crossfade_start_mismatch");

        const auto sMid = n.evaluate(1750000);
        crossfadeMidOk =
            sMid.hasActiveClip && sMid.transition.isTransitionActive &&
            sMid.transition.type == TransitionType::kCrossfade &&
            sMid.primaryClipId == "A" && sMid.primaryLocalPtsUs == 1750000 &&
            sMid.secondaryClipId == "B" && sMid.secondaryLocalPtsUs == 250000 &&
            NearlyEqual(sMid.transition.progress, 0.5) &&
            NearlyEqual(sMid.transition.blendWeightFrom, 0.5) &&
            NearlyEqual(sMid.transition.blendWeightTo, 0.5) &&
            RectIsIdentity(sMid.transition.fromViewport) &&
            RectIsIdentity(sMid.transition.toViewport) &&
            RectIsIdentity(sMid.transition.fromCrop) &&
            RectIsIdentity(sMid.transition.toCrop) &&
            n.isActiveAt(1750000) &&
            n.mapTimelineToLocalPts(1750000) == 1750000 &&
            NearlyEqual(n.blendWeightAt(1750000), 0.5);
        if (!crossfadeMidOk) fail("crossfade_mid_mismatch");

        // Documented end behavior: window is end-exclusive, so at exactly
        // start + duration the transition is inactive and B plays solo.
        const auto sEnd = n.evaluate(2000000);
        crossfadeEndOk =
            sEnd.hasActiveClip && !sEnd.transition.isTransitionActive &&
            sEnd.primaryClipId == "B" && sEnd.primaryLocalPtsUs == 500000 &&
            sEnd.secondaryClipId.empty() &&
            GeometryIsIdentityInactive(sEnd) &&
            NearlyEqual(n.blendWeightAt(2000000), 1.0);
        if (!crossfadeEndOk) fail("crossfade_end_mismatch");
    }

    // ── Scenario 4b: fade (two-phase dip to black) quarter / mid / three-quarter ──
    // Single-sided weights over identity geometry: first half from = 1 - 2p,
    // to = 0; second half from = 0, to = 2p - 1; both zero at exactly 0.5.
    bool fadeQuarterOk      = false;
    bool fadeMidOk          = false;
    bool fadeThreeQuarterOk = false;
    {
        VGTimelineCompositorNode n("fade");
        n.setClips({MakeClip("A", 0, 2000000, 0, 1.0),
                    MakeClip("B", 1500000, 2000000, 0, 1.0)});
        n.setTransitions({MakeTransition("fade", TransitionType::kFade,
                                         "A", "B", 1500000, 500000)});

        const auto sQ = n.evaluate(1625000);
        fadeQuarterOk =
            sQ.hasActiveClip && sQ.transition.isTransitionActive &&
            sQ.transition.type == TransitionType::kFade &&
            sQ.primaryClipId == "A" && sQ.secondaryClipId == "B" &&
            NearlyEqual(sQ.transition.progress, 0.25) &&
            NearlyEqual(sQ.transition.blendWeightFrom, 0.5) &&
            NearlyEqual(sQ.transition.blendWeightTo, 0.0) &&
            RectIsIdentity(sQ.transition.fromViewport) &&
            RectIsIdentity(sQ.transition.toViewport) &&
            RectIsIdentity(sQ.transition.fromCrop) &&
            RectIsIdentity(sQ.transition.toCrop) &&
            NearlyEqual(n.blendWeightAt(1625000), 0.5);
        if (!fadeQuarterOk) fail("fade_quarter_mismatch");

        const auto sMid = n.evaluate(1750000);
        fadeMidOk =
            sMid.hasActiveClip && sMid.transition.isTransitionActive &&
            sMid.transition.type == TransitionType::kFade &&
            NearlyEqual(sMid.transition.progress, 0.5) &&
            NearlyEqual(sMid.transition.blendWeightFrom, 0.0) &&
            NearlyEqual(sMid.transition.blendWeightTo, 0.0) &&
            RectIsIdentity(sMid.transition.fromViewport) &&
            RectIsIdentity(sMid.transition.toViewport) &&
            NearlyEqual(n.blendWeightAt(1750000), 0.0);
        if (!fadeMidOk) fail("fade_mid_mismatch");

        const auto sTq = n.evaluate(1875000);
        fadeThreeQuarterOk =
            sTq.hasActiveClip && sTq.transition.isTransitionActive &&
            sTq.transition.type == TransitionType::kFade &&
            NearlyEqual(sTq.transition.progress, 0.75) &&
            NearlyEqual(sTq.transition.blendWeightFrom, 0.0) &&
            NearlyEqual(sTq.transition.blendWeightTo, 0.5) &&
            RectIsIdentity(sTq.transition.fromViewport) &&
            RectIsIdentity(sTq.transition.toViewport) &&
            GeometryIsFinite(sTq);
        if (!fadeThreeQuarterOk) fail("fade_three_quarter_mismatch");
    }

    // ── Scenario 5: slide-left mid ──────────────────────────────────────────
    bool slideLeftMidOk = false;
    {
        VGTimelineCompositorNode n("slide");
        n.setClips({MakeClip("A", 0, 2000000, 0, 1.0),
                    MakeClip("B", 1500000, 2000000, 0, 1.0)});
        n.setTransitions({MakeTransition("slide", TransitionType::kSlideLeft,
                                         "A", "B", 1500000, 500000)});
        const auto s = n.evaluate(1750000);
        slideLeftMidOk =
            s.hasActiveClip && s.transition.isTransitionActive &&
            s.transition.type == TransitionType::kSlideLeft &&
            NearlyEqual(s.transition.progress, 0.5) &&
            RectNearlyEquals(s.transition.fromViewport, -0.5, 0.0, 1.0, 1.0) &&
            RectNearlyEquals(s.transition.toViewport, 0.5, 0.0, 1.0, 1.0) &&
            RectIsIdentity(s.transition.fromCrop) &&
            RectIsIdentity(s.transition.toCrop) &&
            GeometryIsFinite(s);
        if (!slideLeftMidOk) fail("slide_left_mid_mismatch");
    }

    // ── Scenario 6: wipe-left mid ───────────────────────────────────────────
    bool wipeLeftMidOk = false;
    {
        VGTimelineCompositorNode n("wipe");
        n.setClips({MakeClip("A", 0, 2000000, 0, 1.0),
                    MakeClip("B", 1500000, 2000000, 0, 1.0)});
        n.setTransitions({MakeTransition("wipe", TransitionType::kWipeLeft,
                                         "A", "B", 1500000, 500000)});
        const auto s = n.evaluate(1750000);
        wipeLeftMidOk =
            s.hasActiveClip && s.transition.isTransitionActive &&
            s.transition.type == TransitionType::kWipeLeft &&
            NearlyEqual(s.transition.progress, 0.5) &&
            RectIsIdentity(s.transition.fromViewport) &&
            RectIsIdentity(s.transition.toViewport) &&
            RectNearlyEquals(s.transition.fromCrop, 0.0, 0.0, 0.5, 1.0) &&
            RectNearlyEquals(s.transition.toCrop, 0.5, 0.0, 0.5, 1.0) &&
            GeometryIsFinite(s);
        if (!wipeLeftMidOk) fail("wipe_left_mid_mismatch");
    }

    // ── Scenario 7: outside timeline ────────────────────────────────────────
    bool outsideTimelineOk = false;
    {
        VGTimelineCompositorNode n("outside");
        n.setClips({MakeClip("A", 1000000, 2000000, 0, 1.0)});
        n.setTransitions({MakeTransition("x", TransitionType::kCrossfade,
                                         "A", "A", 1000000, 1000)});
        const auto before = n.evaluate(0);
        const auto after  = n.evaluate(5000000);
        const auto atEnd  = n.evaluate(3000000); // end-exclusive
        outsideTimelineOk =
            !before.hasActiveClip && before.primaryClipId.empty() &&
            GeometryIsIdentityInactive(before) &&
            !after.hasActiveClip && after.primaryClipId.empty() &&
            GeometryIsIdentityInactive(after) &&
            !atEnd.hasActiveClip && GeometryIsIdentityInactive(atEnd) &&
            !n.isActiveAt(5000000) &&
            n.mapTimelineToLocalPts(5000000) == 5000000 &&
            NearlyEqual(n.blendWeightAt(5000000), 0.0);
        if (!outsideTimelineOk) fail("outside_timeline_mismatch");
    }

    // ── Scenario 8: invalid transition endpoints ignored ────────────────────
    bool invalidTransitionIgnoredOk = false;
    {
        VGTimelineCompositorNode n("invalid");
        n.setClips({MakeClip("A", 0, 2000000, 0, 1.0),
                    MakeClip("B", 1500000, 2000000, 0, 1.0)});
        n.setTransitions({
            MakeTransition("unknown_to", TransitionType::kCrossfade, "A", "Z", 1500000, 500000),
            MakeTransition("unknown_from", TransitionType::kWipeLeft, "Q", "B", 1500000, 500000),
            MakeTransition("same_endpoints", TransitionType::kSlideUp, "A", "A", 1500000, 500000),
            MakeTransition("none_type", TransitionType::kNone, "A", "B", 1500000, 500000),
            MakeTransition("empty_ids", TransitionType::kCrossfade, "", "", 1500000, 500000),
        });
        // Overlap without a valid transition: later-placed clip (B) wins.
        const auto s = n.evaluate(1750000);
        invalidTransitionIgnoredOk =
            s.hasActiveClip && !s.transition.isTransitionActive &&
            s.primaryClipId == "B" && s.primaryLocalPtsUs == 250000 &&
            s.secondaryClipId.empty() &&
            GeometryIsIdentityInactive(s);

        // No clips at all plus a transition: fail-safe inactive.
        VGTimelineCompositorNode empty("empty");
        empty.setTransitions({MakeTransition("orphan", TransitionType::kCrossfade, "A", "B", 0, 1000000)});
        const auto sEmpty = empty.evaluate(500000);
        invalidTransitionIgnoredOk = invalidTransitionIgnoredOk &&
            !sEmpty.hasActiveClip && GeometryIsIdentityInactive(sEmpty);
        if (!invalidTransitionIgnoredOk) fail("invalid_transition_not_ignored");
    }

    // ── Scenario 9: zero-duration transition / clip safety ──────────────────
    bool zeroDurationSafeOk = false;
    {
        VGTimelineCompositorNode n("zero");
        n.setClips({MakeClip("A", 0, 2000000, 0, 1.0),
                    MakeClip("B", 2000000, 2000000, 0, 1.0),
                    MakeClip("Z", 1000000, 0, 0, 1.0)}); // zero-duration clip never active
        n.setTransitions({MakeTransition("zero", TransitionType::kCrossfade, "A", "B", 2000000, 0)});
        const auto atStart = n.evaluate(2000000);
        const auto justBefore = n.evaluate(1999999);
        const auto atZ = n.evaluate(1000000);
        zeroDurationSafeOk =
            atStart.hasActiveClip && !atStart.transition.isTransitionActive &&
            atStart.primaryClipId == "B" && GeometryIsIdentityInactive(atStart) &&
            GeometryIsFinite(atStart) &&
            justBefore.hasActiveClip && !justBefore.transition.isTransitionActive &&
            justBefore.primaryClipId == "A" &&
            atZ.hasActiveClip && atZ.primaryClipId == "A" && // Z ignored
            GeometryIsFinite(atZ);

        // Direct pure-function check: zero-duration progress is 0, inactive.
        const auto zeroT = MakeTransition("zero", TransitionType::kCrossfade, "A", "B", 5, 0);
        zeroDurationSafeOk = zeroDurationSafeOk &&
            !vanguard::compositors::IsTransitionActiveAt(zeroT, 5) &&
            NearlyEqual(vanguard::compositors::TransitionProgressAt(zeroT, 5), 0.0);
        if (!zeroDurationSafeOk) fail("zero_duration_unsafe");
    }

    // ── Scenario 10: overflow-adjacent saturation ───────────────────────────
    bool overflowSafeOk = false;
    {
        const uint64_t start = kMaxPts - 10;
        VGTimelineCompositorNode n("overflow");
        n.setClips({MakeClip("A", start, 100, 0, 1.0)});
        const uint64_t end = vanguard::compositors::ClipEndPtsUs(n.clips()[0]);
        const bool endSaturated = end == kMaxPts && end >= start;
        // Active inside the saturated window, inactive before start; no wrap
        // means pts 0 is NOT active.
        const bool activeOk = n.isActiveAt(kMaxPts - 5) && !n.isActiveAt(start - 1) && !n.isActiveAt(0);

        // Local PTS saturates: trim near max plus scaled delta.
        n.setClips({MakeClip("A", start, 100, kMaxPts - 1, 2.0)});
        const bool localSaturated = n.mapTimelineToLocalPts(kMaxPts - 5) == kMaxPts;

        // Huge speed on a large delta saturates rather than wrapping.
        n.setClips({MakeClip("A", 0, kMaxPts, 0, 1e30)});
        const bool hugeSpeedSaturated = n.mapTimelineToLocalPts(kMaxPts / 2) == kMaxPts;

        // Transition window near max saturates and yields finite progress.
        VGTimelineCompositorNode t("overflow_t");
        t.setClips({MakeClip("A", start, 100, 0, 1.0), MakeClip("B", start, 100, 0, 1.0)});
        t.setTransitions({MakeTransition("x", TransitionType::kCrossfade, "A", "B", start, 100)});
        const auto s = t.evaluate(kMaxPts - 5);
        const bool transitionSaturated =
            s.hasActiveClip && s.transition.isTransitionActive &&
            NearlyEqual(s.transition.progress, 0.05) && GeometryIsFinite(s);

        // Direct saturating add checks.
        const bool addOk =
            vanguard::compositors::SaturatingAddPtsUs(kMaxPts, 1) == kMaxPts &&
            vanguard::compositors::SaturatingAddPtsUs(kMaxPts - 1, 1) == kMaxPts &&
            vanguard::compositors::SaturatingAddPtsUs(1, 2) == 3;

        overflowSafeOk = endSaturated && activeOk && localSaturated &&
                         hugeSpeedSaturated && transitionSaturated && addOk;
        if (!overflowSafeOk) fail("overflow_not_saturating");
    }

    const bool allNativeLanesPass =
        kindOk && typeOk && inputPortCountOk && outputPortCountOk && portIdsOk &&
        hardCutOk && crossfadeStartOk && crossfadeMidOk && crossfadeEndOk &&
        fadeQuarterOk && fadeMidOk && fadeThreeQuarterOk &&
        slideLeftMidOk && wipeLeftMidOk && speedMappingOk && outsideTimelineOk &&
        invalidTransitionIgnoredOk && zeroDurationSafeOk && overflowSafeOk;

    std::ostringstream oss;
    oss << "{"
        << "\"pass\":" << BoolStr(allNativeLanesPass) << ","
        << "\"status\":\"" << (allNativeLanesPass ? "PASS" : "FAIL") << "\","
        << "\"marker\":\"" << (allNativeLanesPass ? kPassMarker : kFailMarker) << "\","
        << "\"proofBoundary\":\"" << kProofBoundary << "\","
        << "\"failureReason\":\"" << JsonEscape(failureReason) << "\","
        << "\"kindOk\":" << BoolStr(kindOk) << ","
        << "\"typeOk\":" << BoolStr(typeOk) << ","
        << "\"inputPortCountOk\":" << BoolStr(inputPortCountOk) << ","
        << "\"outputPortCountOk\":" << BoolStr(outputPortCountOk) << ","
        << "\"portIdsOk\":" << BoolStr(portIdsOk) << ","
        << "\"hardCutOk\":" << BoolStr(hardCutOk) << ","
        << "\"crossfadeStartOk\":" << BoolStr(crossfadeStartOk) << ","
        << "\"crossfadeMidOk\":" << BoolStr(crossfadeMidOk) << ","
        << "\"crossfadeEndOk\":" << BoolStr(crossfadeEndOk) << ","
        << "\"fadeQuarterOk\":" << BoolStr(fadeQuarterOk) << ","
        << "\"fadeMidOk\":" << BoolStr(fadeMidOk) << ","
        << "\"fadeThreeQuarterOk\":" << BoolStr(fadeThreeQuarterOk) << ","
        << "\"slideLeftMidOk\":" << BoolStr(slideLeftMidOk) << ","
        << "\"wipeLeftMidOk\":" << BoolStr(wipeLeftMidOk) << ","
        << "\"speedMappingOk\":" << BoolStr(speedMappingOk) << ","
        << "\"outsideTimelineOk\":" << BoolStr(outsideTimelineOk) << ","
        << "\"invalidTransitionIgnoredOk\":" << BoolStr(invalidTransitionIgnoredOk) << ","
        << "\"zeroDurationSafeOk\":" << BoolStr(zeroDurationSafeOk) << ","
        << "\"overflowSafeOk\":" << BoolStr(overflowSafeOk) << ","
        << "\"allNativeLanesPass\":" << BoolStr(allNativeLanesPass) << ","
        << "\"details\":{"
        << "\"inputPortCount\":\"" << inputs.size() << "\","
        << "\"outputPortCount\":\"" << outputs.size() << "\","
        << "\"inputPort0\":\"" << (inputs.empty() ? "" : JsonEscape(inputs[0].id)) << "\","
        << "\"inputPort1\":\"" << (inputs.size() < 2 ? "" : JsonEscape(inputs[1].id)) << "\","
        << "\"outputPort0\":\"" << (outputs.empty() ? "" : JsonEscape(outputs[0].id)) << "\","
        << "\"crossfadeEndPolicy\":\"end_exclusive_window_to_clip_solo\","
        << "\"zeroDurationPolicy\":\"zero_duration_transition_never_active_hard_cut\","
        << "\"overlapWithoutTransitionPolicy\":\"later_start_clip_wins\""
        << "}"
        << "}";

    const std::string resultStr = oss.str();
    return env->NewStringUTF(resultStr.c_str());
}
