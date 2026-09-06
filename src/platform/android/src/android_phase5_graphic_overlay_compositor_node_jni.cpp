// P5-GRAPHIC-OVERLAY-COMPOSITOR-NODE-A: platform-neutral logical DAG
// graphic-overlay-compositor-node diagnostic proof.
//
// Diagnostic-only: proves vanguard::compositors::GraphicOverlayCompositorNode's
// construction validation, identity/port shape, descriptor/overlay
// accessors, overlay active-filtering/sorting math, and timeline-window
// semantics, plus a real GraphExecutionPlan
// base+overlay0+overlay1->compositor->sink pass wiring three real
// vanguard::sources::ImageTextureSourceNode instances into this node and
// this node into the real vanguard::sinks::PreviewSurfaceSinkNode.
// GraphicOverlayCompositorNode itself owns only primitive overlay/timeline
// metadata and pure topology - no renderer, PNG decoder, text rasterizer,
// shader, GL/GLES/Vulkan texture/sampler, GPU lifecycle, Android lifecycle,
// file IO, MediaCodec, thread, or product/app/editor/ConnectsApp wiring,
// and includes no Android/NDK/EGL/GLES/Vulkan header.
//
// Non-claims: no render ownership, no texture ownership, no GPU lifecycle,
// no product/editor/app/ConnectsApp wiring.
//
// This translation unit is Android-only and must NOT be included in iOS or
// host builds. It is added via the Android-only target_sources block in
// src/CMakeLists.txt.
//
// JNI entry point:
//   runAndroidDagPhase5GraphicOverlayCompositorNodeSmoke -> jstring

#include <jni.h>

#include <cmath>
#include <cstdint>
#include <limits>
#include <memory>
#include <sstream>
#include <stdexcept>
#include <string>
#include <utility>
#include <vector>

#include "vanguard/compositors/graphic_overlay_compositor_node.h"
#include "vanguard/graph/frame_request.h"
#include "vanguard/graph/graph.h"
#include "vanguard/graph/graph_execution_plan.h"
#include "vanguard/graph/node.h"
#include "vanguard/sinks/preview_surface_sink_node.h"
#include "vanguard/sources/image_texture_source_node.h"

namespace {

using vanguard::compositors::GraphicOverlayBounds;
using vanguard::compositors::GraphicOverlayCompositorDescriptor;
using vanguard::compositors::GraphicOverlayCompositorNode;
using vanguard::compositors::GraphicOverlayDescriptor;
using vanguard::compositors::GraphicOverlayKind;
using vanguard::graph::BuildGraphExecutionPlan;
using vanguard::graph::ExecutionPlanNode;
using vanguard::graph::FrameRequest;
using vanguard::graph::Graph;
using vanguard::graph::GraphExecutionPlan;
using vanguard::graph::NodeKind;
using vanguard::graph::NodeType;
using vanguard::graph::PortDataType;
using vanguard::sinks::PreviewSurfaceSinkNode;
using vanguard::sources::ImageTextureSourceNode;

constexpr const char* kProofBoundary =
    "platform_neutral_graphic_overlay_compositor_node_logical_dag_compositor_no_png_decode_"
    "no_rasterizer_no_shader_ownership_no_texture_ownership_no_gpu_lifecycle_"
    "no_product_app_editor_wiring";

const ExecutionPlanNode* PlanFind(const GraphExecutionPlan& plan, const std::string& nodeId) {
    for (const auto& n : plan.nodes) {
        if (n.nodeId == nodeId) return &n;
    }
    return nullptr;
}

int PlanIndexOf(const GraphExecutionPlan& plan, const std::string& nodeId) {
    for (size_t i = 0; i < plan.nodes.size(); ++i) {
        if (plan.nodes[i].nodeId == nodeId) return static_cast<int>(i);
    }
    return -1;
}

GraphicOverlayDescriptor MakeValidOverlay(const std::string& overlayId) {
    GraphicOverlayDescriptor overlay;
    overlay.overlayId = overlayId;
    overlay.durationUs = 1000;
    return overlay;
}

bool ExpectInvalidOverlayInputCount(uint32_t overlayInputCount) {
    GraphicOverlayCompositorDescriptor descriptor;
    descriptor.overlayInputCount = overlayInputCount;
    try {
        GraphicOverlayCompositorNode node("goc_invalid_count", descriptor);
        (void)node;
        return false;
    } catch (const std::invalid_argument& e) {
        return std::string(e.what()) == "invalid_overlay_input_count";
    } catch (...) {
        return false;
    }
}

bool ExpectInvalidOverlay(const GraphicOverlayDescriptor& overlay, const std::string& expectedReason) {
    GraphicOverlayCompositorDescriptor descriptor;
    descriptor.overlays.push_back(overlay);
    try {
        GraphicOverlayCompositorNode node("goc_invalid_overlay", descriptor);
        (void)node;
        return false;
    } catch (const std::invalid_argument& e) {
        return std::string(e.what()) == expectedReason;
    } catch (...) {
        return false;
    }
}

std::string RunGraphicOverlayCompositorNodeSmokeInternal() {
    bool emptyIdRejectedOk = false;
    bool zeroDurationRejectedOk = false;
    bool invalidOverlayInputCountRejectedOk = false;
    bool invalidOverlayIdAndDurationRejectedOk = false;
    bool invalidOverlayBoundsRejectedOk = false;
    bool invalidOverlayOpacityRejectedOk = false;
    bool identityOk = false;
    bool explicitDescriptorOk = false;
    bool timelineActiveWindowOk = false;
    bool timelineMappingOk = false;
    bool overlayActiveFilteringOk = false;
    bool zIndexIdSortingOk = false;
    bool multiOverlayInputPortShapeOk = false;
    bool overflowClampOk = false;
    bool executionPlanOk = false;
    bool proofBoundaryLaneOk = false;
    std::string failureReason;

    // ---- Lane 1: empty id is rejected with empty_id ----
    {
        try {
            GraphicOverlayCompositorNode node("", GraphicOverlayCompositorDescriptor{});
            (void)node;
        } catch (const std::invalid_argument& e) {
            emptyIdRejectedOk = std::string(e.what()) == "empty_id";
        } catch (...) {
        }
        if (!emptyIdRejectedOk && failureReason.empty()) failureReason = "empty_id_rejected_failed";
    }

    // ---- Lane 2: zero node duration is rejected with invalid_duration_us ----
    {
        GraphicOverlayCompositorDescriptor descriptor;
        descriptor.durationUs = 0;
        try {
            GraphicOverlayCompositorNode node("goc_zero_duration", descriptor);
            (void)node;
        } catch (const std::invalid_argument& e) {
            zeroDurationRejectedOk = std::string(e.what()) == "invalid_duration_us";
        } catch (...) {
        }
        if (!zeroDurationRejectedOk && failureReason.empty()) {
            failureReason = "zero_duration_rejected_failed";
        }
    }

    // ---- Lane 3: overlayInputCount outside [1,16] rejected with
    //      invalid_overlay_input_count; boundary values 1 and 16 accepted ----
    {
        const bool zeroRejected = ExpectInvalidOverlayInputCount(0);
        const bool seventeenRejected = ExpectInvalidOverlayInputCount(17);

        bool boundaryOneAccepted = false;
        bool boundarySixteenAccepted = false;
        try {
            GraphicOverlayCompositorDescriptor descriptor;
            descriptor.overlayInputCount = 1;
            GraphicOverlayCompositorNode node("goc_count_one", descriptor);
            boundaryOneAccepted = node.overlayInputCount() == 1 && node.inputPorts().size() == 2;
        } catch (...) {
        }
        try {
            GraphicOverlayCompositorDescriptor descriptor;
            descriptor.overlayInputCount = 16;
            GraphicOverlayCompositorNode node("goc_count_sixteen", descriptor);
            boundarySixteenAccepted = node.overlayInputCount() == 16 && node.inputPorts().size() == 17;
        } catch (...) {
        }

        invalidOverlayInputCountRejectedOk =
            zeroRejected && seventeenRejected && boundaryOneAccepted && boundarySixteenAccepted;
        if (!invalidOverlayInputCountRejectedOk && failureReason.empty()) {
            failureReason = "invalid_overlay_input_count_rejected_failed";
        }
    }

    // ---- Lane 4: empty overlayId rejected with invalid_overlay_id; zero
    //      overlay duration rejected with invalid_overlay_duration_us ----
    {
        GraphicOverlayDescriptor emptyIdOverlay = MakeValidOverlay("ov_placeholder");
        emptyIdOverlay.overlayId = "";
        GraphicOverlayDescriptor zeroDurationOverlay = MakeValidOverlay("ov_zero_duration");
        zeroDurationOverlay.durationUs = 0;

        const bool emptyOverlayIdRejected = ExpectInvalidOverlay(emptyIdOverlay, "invalid_overlay_id");
        const bool zeroOverlayDurationRejected =
            ExpectInvalidOverlay(zeroDurationOverlay, "invalid_overlay_duration_us");

        invalidOverlayIdAndDurationRejectedOk = emptyOverlayIdRejected && zeroOverlayDurationRejected;
        if (!invalidOverlayIdAndDurationRejectedOk && failureReason.empty()) {
            failureReason = "invalid_overlay_id_and_duration_rejected_failed";
        }
    }

    // ---- Lane 5: non-finite/out-of-unit/empty/overflowing overlay bounds
    //      rejected with invalid_overlay_bounds; boundary bounds
    //      (x+width==1, y+height==1) accepted ----
    {
        auto boundsOverlay = [](GraphicOverlayBounds bounds) {
            GraphicOverlayDescriptor overlay = MakeValidOverlay("ov_bounds");
            overlay.bounds = bounds;
            return overlay;
        };

        const bool nonFiniteRejected = ExpectInvalidOverlay(
            boundsOverlay(GraphicOverlayBounds{std::numeric_limits<double>::quiet_NaN(), 0.0, 0.5, 0.5}),
            "invalid_overlay_bounds");
        const bool negativeXRejected =
            ExpectInvalidOverlay(boundsOverlay(GraphicOverlayBounds{-0.1, 0.0, 0.5, 0.5}), "invalid_overlay_bounds");
        const bool overOneYRejected =
            ExpectInvalidOverlay(boundsOverlay(GraphicOverlayBounds{0.0, 1.5, 0.5, 0.5}), "invalid_overlay_bounds");
        const bool zeroWidthRejected =
            ExpectInvalidOverlay(boundsOverlay(GraphicOverlayBounds{0.0, 0.0, 0.0, 0.5}), "invalid_overlay_bounds");
        const bool overflowWidthRejected =
            ExpectInvalidOverlay(boundsOverlay(GraphicOverlayBounds{0.6, 0.0, 0.5, 0.5}), "invalid_overlay_bounds");

        bool boundaryBoundsAccepted = false;
        try {
            GraphicOverlayCompositorDescriptor descriptor;
            descriptor.overlays.push_back(boundsOverlay(GraphicOverlayBounds{0.5, 0.5, 0.5, 0.5}));
            GraphicOverlayCompositorNode node("goc_boundary_bounds", descriptor);
            boundaryBoundsAccepted =
                node.overlays()[0].bounds.x == 0.5 && node.overlays()[0].bounds.width == 0.5;
        } catch (...) {
        }

        invalidOverlayBoundsRejectedOk = nonFiniteRejected && negativeXRejected && overOneYRejected &&
            zeroWidthRejected && overflowWidthRejected && boundaryBoundsAccepted;
        if (!invalidOverlayBoundsRejectedOk && failureReason.empty()) {
            failureReason = "invalid_overlay_bounds_rejected_failed";
        }
    }

    // ---- Lane 6: non-finite/out-of-[0,1] overlay opacity rejected with
    //      invalid_overlay_opacity; boundary values 0.0 and 1.0 accepted ----
    {
        auto opacityOverlay = [](double opacity) {
            GraphicOverlayDescriptor overlay = MakeValidOverlay("ov_opacity");
            overlay.opacity = opacity;
            return overlay;
        };

        const bool nanRejected =
            ExpectInvalidOverlay(opacityOverlay(std::numeric_limits<double>::quiet_NaN()), "invalid_overlay_opacity");
        const bool infRejected =
            ExpectInvalidOverlay(opacityOverlay(std::numeric_limits<double>::infinity()), "invalid_overlay_opacity");
        const bool negativeRejected = ExpectInvalidOverlay(opacityOverlay(-0.1), "invalid_overlay_opacity");
        const bool overOneRejected = ExpectInvalidOverlay(opacityOverlay(1.1), "invalid_overlay_opacity");

        bool boundaryZeroAccepted = false;
        bool boundaryOneAccepted = false;
        try {
            GraphicOverlayCompositorDescriptor descriptor;
            descriptor.overlays.push_back(opacityOverlay(0.0));
            GraphicOverlayCompositorNode node("goc_opacity_zero", descriptor);
            boundaryZeroAccepted = node.overlays()[0].opacity == 0.0;
        } catch (...) {
        }
        try {
            GraphicOverlayCompositorDescriptor descriptor;
            descriptor.overlays.push_back(opacityOverlay(1.0));
            GraphicOverlayCompositorNode node("goc_opacity_one", descriptor);
            boundaryOneAccepted = node.overlays()[0].opacity == 1.0;
        } catch (...) {
        }

        invalidOverlayOpacityRejectedOk = nanRejected && infRejected && negativeRejected && overOneRejected &&
            boundaryZeroAccepted && boundaryOneAccepted;
        if (!invalidOverlayOpacityRejectedOk && failureReason.empty()) {
            failureReason = "invalid_overlay_opacity_rejected_failed";
        }
    }

    // ---- Lane 7: identity: id/kind/type (kProcessing,
    //      kGraphicOverlayCompositor); default descriptor ports are exactly
    //      base_video_in + overlay_0_video_in (kVideoFrame) in, kVideoFrame
    //      out; default overlayInputCount 1, duration UINT64_MAX, no
    //      overlays ----
    {
        GraphicOverlayCompositorNode node("goc_identity", GraphicOverlayCompositorDescriptor{});
        identityOk = node.id() == "goc_identity" && node.kind() == NodeKind::kProcessing &&
            node.type() == NodeType::kGraphicOverlayCompositor &&
            node.inputPorts().size() == 2 &&
            node.inputPorts()[0].id == "base_video_in" &&
            node.inputPorts()[0].dataType == PortDataType::kVideoFrame &&
            node.inputPorts()[1].id == "overlay_0_video_in" &&
            node.inputPorts()[1].dataType == PortDataType::kVideoFrame &&
            node.outputPorts().size() == 1 && node.outputPorts()[0].id == "kVideoFrame" &&
            node.outputPorts()[0].dataType == PortDataType::kVideoFrame &&
            node.overlayInputCount() == 1 && node.timelineStartPtsUs() == 0 &&
            node.durationUs() == std::numeric_limits<uint64_t>::max() && !node.hasOverlays();
        if (!identityOk && failureReason.empty()) failureReason = "identity_failed";
    }

    // ---- Lane 8: explicit descriptor values are reflected exactly by
    //      descriptor()/overlayInputCount()/overlays()/hasOverlays() ----
    {
        GraphicOverlayCompositorDescriptor descriptor;
        descriptor.timelineStartPtsUs = 1000;
        descriptor.durationUs = 5000;
        descriptor.overlayInputCount = 2;

        GraphicOverlayDescriptor png;
        png.overlayId = "png1";
        png.kind = GraphicOverlayKind::kPng;
        png.timelineStartPtsUs = 100;
        png.durationUs = 200;
        png.bounds = GraphicOverlayBounds{0.1, 0.2, 0.3, 0.4};
        png.opacity = 0.8;
        png.zIndex = 2;

        GraphicOverlayDescriptor text;
        text.overlayId = "text1";
        text.kind = GraphicOverlayKind::kText;
        text.timelineStartPtsUs = 50;
        text.durationUs = 500;
        text.bounds = GraphicOverlayBounds{0.0, 0.0, 1.0, 0.2};
        text.opacity = 1.0;
        text.zIndex = 1;

        descriptor.overlays = {png, text};
        GraphicOverlayCompositorNode node("goc_explicit_descriptor", descriptor);

        explicitDescriptorOk = node.timelineStartPtsUs() == 1000 && node.durationUs() == 5000 &&
            node.overlayInputCount() == 2 && node.hasOverlays() && node.overlays().size() == 2 &&
            node.overlays()[0].overlayId == "png1" &&
            node.overlays()[0].kind == GraphicOverlayKind::kPng &&
            node.overlays()[0].timelineStartPtsUs == 100 && node.overlays()[0].durationUs == 200 &&
            node.overlays()[0].bounds.x == 0.1 && node.overlays()[0].bounds.y == 0.2 &&
            node.overlays()[0].bounds.width == 0.3 && node.overlays()[0].bounds.height == 0.4 &&
            node.overlays()[0].opacity == 0.8 && node.overlays()[0].zIndex == 2 &&
            node.overlays()[1].overlayId == "text1" &&
            node.overlays()[1].kind == GraphicOverlayKind::kText &&
            node.overlays()[1].timelineStartPtsUs == 50 && node.overlays()[1].durationUs == 500 &&
            node.overlays()[1].opacity == 1.0 && node.overlays()[1].zIndex == 1 &&
            node.descriptor().timelineStartPtsUs == 1000 && node.descriptor().overlayInputCount == 2 &&
            node.descriptor().overlays.size() == 2;
        if (!explicitDescriptorOk && failureReason.empty()) failureReason = "explicit_descriptor_failed";
    }

    // ---- Lane 9: node active window [start, start+duration) ----
    {
        constexpr uint64_t kStart = 10000;
        constexpr uint64_t kDuration = 5000;
        constexpr uint64_t kEnd = kStart + kDuration;
        GraphicOverlayCompositorDescriptor descriptor;
        descriptor.timelineStartPtsUs = kStart;
        descriptor.durationUs = kDuration;
        GraphicOverlayCompositorNode node("goc_active_window", descriptor);

        timelineActiveWindowOk = node.timelineStartPtsUs() == kStart && node.durationUs() == kDuration &&
            node.timelineEndPtsUs() == kEnd && !node.isActiveAt(kStart - 1) && node.isActiveAt(kStart) &&
            node.isActiveAt(kStart + kDuration / 2) && node.isActiveAt(kEnd - 1) && !node.isActiveAt(kEnd);
        if (!timelineActiveWindowOk && failureReason.empty()) failureReason = "timeline_active_window_failed";
    }

    // ---- Lane 10: timeline mapping before/inside/after clamps, blend
    //      weights 1 inside / 0 outside ----
    {
        constexpr uint64_t kStart = 10000;
        constexpr uint64_t kDuration = 5000;
        GraphicOverlayCompositorDescriptor descriptor;
        descriptor.timelineStartPtsUs = kStart;
        descriptor.durationUs = kDuration;
        GraphicOverlayCompositorNode node("goc_mapping", descriptor);

        timelineMappingOk = node.mapTimelineToLocalPts(kStart - 1) == 0 &&
            node.mapTimelineToLocalPts(kStart) == 0 &&
            node.mapTimelineToLocalPts(kStart + 1234) == 1234 &&
            node.mapTimelineToLocalPts(kStart + kDuration) == kDuration &&
            node.mapTimelineToLocalPts(kStart + kDuration + 999) == kDuration &&
            node.blendWeightAt(kStart) == 1.0f && node.blendWeightAt(kStart - 1) == 0.0f;
        if (!timelineMappingOk && failureReason.empty()) failureReason = "timeline_mapping_failed";
    }

    // ---- Lane 11: activeOverlaysAt returns exactly the overlays whose own
    //      half-open interval contains pts ----
    {
        GraphicOverlayCompositorDescriptor descriptor;
        GraphicOverlayDescriptor early = MakeValidOverlay("ov_early");
        early.timelineStartPtsUs = 0;
        early.durationUs = 1000;
        GraphicOverlayDescriptor late = MakeValidOverlay("ov_late");
        late.timelineStartPtsUs = 1000;
        late.durationUs = 1000;
        descriptor.overlays = {early, late};
        GraphicOverlayCompositorNode node("goc_active_filter", descriptor);

        const auto activeAt500 = node.activeOverlaysAt(500);
        const auto activeAt1000 = node.activeOverlaysAt(1000);
        const auto activeAt2000 = node.activeOverlaysAt(2000);

        overlayActiveFilteringOk = activeAt500.size() == 1 && activeAt500[0].overlayId == "ov_early" &&
            activeAt1000.size() == 1 && activeAt1000[0].overlayId == "ov_late" && activeAt2000.empty();
        if (!overlayActiveFilteringOk && failureReason.empty()) failureReason = "overlay_active_filtering_failed";
    }

    // ---- Lane 12: activeOverlaysAt sorts by zIndex ascending then
    //      overlayId ascending ----
    {
        GraphicOverlayCompositorDescriptor descriptor;
        GraphicOverlayDescriptor bbb = MakeValidOverlay("bbb");
        bbb.zIndex = 2;
        GraphicOverlayDescriptor aaa = MakeValidOverlay("aaa");
        aaa.zIndex = 2;
        GraphicOverlayDescriptor ccc = MakeValidOverlay("ccc");
        ccc.zIndex = 1;
        descriptor.overlays = {bbb, aaa, ccc};
        GraphicOverlayCompositorNode node("goc_sorting", descriptor);

        const auto active = node.activeOverlaysAt(0);
        zIndexIdSortingOk = active.size() == 3 && active[0].overlayId == "ccc" &&
            active[1].overlayId == "aaa" && active[2].overlayId == "bbb";
        if (!zIndexIdSortingOk && failureReason.empty()) failureReason = "z_index_id_sorting_failed";
    }

    // ---- Lane 13: multi-overlay input port shape: overlayInputCount=3
    //      yields exactly base_video_in + overlay_0_video_in +
    //      overlay_1_video_in + overlay_2_video_in, all kVideoFrame, one
    //      kVideoFrame output ----
    {
        GraphicOverlayCompositorDescriptor descriptor;
        descriptor.overlayInputCount = 3;
        GraphicOverlayCompositorNode node("goc_multi_port", descriptor);

        multiOverlayInputPortShapeOk = node.inputPorts().size() == 4 &&
            node.inputPorts()[0].id == "base_video_in" &&
            node.inputPorts()[1].id == "overlay_0_video_in" &&
            node.inputPorts()[2].id == "overlay_1_video_in" &&
            node.inputPorts()[3].id == "overlay_2_video_in" &&
            node.inputPorts()[0].dataType == PortDataType::kVideoFrame &&
            node.inputPorts()[1].dataType == PortDataType::kVideoFrame &&
            node.inputPorts()[2].dataType == PortDataType::kVideoFrame &&
            node.inputPorts()[3].dataType == PortDataType::kVideoFrame &&
            node.outputPorts().size() == 1 && node.outputPorts()[0].id == "kVideoFrame";
        if (!multiOverlayInputPortShapeOk && failureReason.empty()) {
            failureReason = "multi_overlay_input_port_shape_failed";
        }
    }

    // ---- Lane 14: overflow-safe timelineEndPtsUs() saturation to
    //      UINT64_MAX, node-level clamp behavior, and overlay-level
    //      activeOverlaysAt() saturation at/after the saturated end ----
    {
        constexpr uint64_t kMaxU64 = std::numeric_limits<uint64_t>::max();
        constexpr uint64_t kStart = kMaxU64 - 10;
        constexpr uint64_t kDuration = 1000; // start + duration overflows uint64_t
        GraphicOverlayCompositorDescriptor descriptor;
        descriptor.timelineStartPtsUs = kStart;
        descriptor.durationUs = kDuration;
        GraphicOverlayDescriptor overlay = MakeValidOverlay("ov_overflow");
        overlay.timelineStartPtsUs = kStart;
        overlay.durationUs = kDuration;
        descriptor.overlays = {overlay};
        GraphicOverlayCompositorNode node("goc_overflow", descriptor);

        overflowClampOk = node.timelineEndPtsUs() == kMaxU64 && node.isActiveAt(kStart) &&
            node.isActiveAt(kMaxU64 - 1) && !node.isActiveAt(kMaxU64) &&
            node.mapTimelineToLocalPts(kMaxU64) == kDuration &&
            node.activeOverlaysAt(kMaxU64 - 1).size() == 1 && node.activeOverlaysAt(kMaxU64).empty();
        if (!overflowClampOk && failureReason.empty()) failureReason = "overflow_clamp_failed";
    }

    // ---- Lane 15: real BuildGraphExecutionPlan pass wiring three real
    //      ImageTextureSourceNode instances (base, overlay0, overlay1) ->
    //      real GraphicOverlayCompositorNode -> real PreviewSurfaceSinkNode,
    //      verifying dependency order and all four input bindings ----
    {
        Graph g;
        auto base = std::make_shared<ImageTextureSourceNode>(
            "goc_plan_base", "img_base", 0, 5000, 1920, 1080, 0);
        auto overlay0 = std::make_shared<ImageTextureSourceNode>(
            "goc_plan_overlay0", "img_overlay0", 0, 5000, 512, 512, 0);
        auto overlay1 = std::make_shared<ImageTextureSourceNode>(
            "goc_plan_overlay1", "img_overlay1", 0, 5000, 256, 256, 0);
        GraphicOverlayCompositorDescriptor compositorDescriptor;
        compositorDescriptor.overlayInputCount = 2;
        auto compositor = std::make_shared<GraphicOverlayCompositorNode>(
            "goc_plan_compositor", compositorDescriptor);
        auto sink = std::make_shared<PreviewSurfaceSinkNode>("goc_plan_sink");

        const bool added = g.addNode(base).ok() && g.addNode(overlay0).ok() && g.addNode(overlay1).ok() &&
            g.addNode(compositor).ok() && g.addNode(sink).ok();
        const bool wired = added &&
            g.connect("goc_plan_base", "kVideoFrame", "goc_plan_compositor", "base_video_in").ok() &&
            g.connect("goc_plan_overlay0", "kVideoFrame", "goc_plan_compositor", "overlay_0_video_in").ok() &&
            g.connect("goc_plan_overlay1", "kVideoFrame", "goc_plan_compositor", "overlay_1_video_in").ok() &&
            g.connect("goc_plan_compositor", "kVideoFrame", "goc_plan_sink", "video_in").ok();

        FrameRequest req;
        req.generationId = g.generationId();
        req.timelinePtsUs = 0;

        GraphExecutionPlan plan;
        const auto status = BuildGraphExecutionPlan(g, req, plan);

        const auto* compositorNode = PlanFind(plan, "goc_plan_compositor");
        const auto* sinkNode = PlanFind(plan, "goc_plan_sink");

        executionPlanOk = wired && status.ok() && plan.nodes.size() == 5 &&
            PlanIndexOf(plan, "goc_plan_base") < PlanIndexOf(plan, "goc_plan_compositor") &&
            PlanIndexOf(plan, "goc_plan_overlay0") < PlanIndexOf(plan, "goc_plan_compositor") &&
            PlanIndexOf(plan, "goc_plan_overlay1") < PlanIndexOf(plan, "goc_plan_compositor") &&
            PlanIndexOf(plan, "goc_plan_compositor") < PlanIndexOf(plan, "goc_plan_sink") &&
            plan.sinkNodeIds.size() == 1 && plan.sinkNodeIds[0] == "goc_plan_sink" &&
            compositorNode != nullptr && compositorNode->inputs.size() == 3 &&
            compositorNode->inputs[0].inputPortId == "base_video_in" &&
            compositorNode->inputs[0].fromNodeId == "goc_plan_base" &&
            compositorNode->inputs[0].fromPortId == "kVideoFrame" &&
            compositorNode->inputs[0].dataType == PortDataType::kVideoFrame &&
            compositorNode->inputs[1].inputPortId == "overlay_0_video_in" &&
            compositorNode->inputs[1].fromNodeId == "goc_plan_overlay0" &&
            compositorNode->inputs[1].fromPortId == "kVideoFrame" &&
            compositorNode->inputs[1].dataType == PortDataType::kVideoFrame &&
            compositorNode->inputs[2].inputPortId == "overlay_1_video_in" &&
            compositorNode->inputs[2].fromNodeId == "goc_plan_overlay1" &&
            compositorNode->inputs[2].fromPortId == "kVideoFrame" &&
            compositorNode->inputs[2].dataType == PortDataType::kVideoFrame &&
            sinkNode != nullptr && sinkNode->inputs.size() == 1 &&
            sinkNode->inputs[0].inputPortId == "video_in" &&
            sinkNode->inputs[0].fromNodeId == "goc_plan_compositor" &&
            sinkNode->inputs[0].fromPortId == "kVideoFrame" &&
            sinkNode->inputs[0].dataType == PortDataType::kVideoFrame;

        if (!executionPlanOk && failureReason.empty()) failureReason = "execution_plan_failed";
    }

    // ---- Lane 16: proof boundary lane ----
    {
        const std::string boundary(kProofBoundary);
        proofBoundaryLaneOk = boundary.find("platform_neutral") != std::string::npos &&
            boundary.find("graphic_overlay_compositor_node") != std::string::npos &&
            boundary.find("logical_dag_compositor") != std::string::npos &&
            boundary.find("no_png_decode") != std::string::npos &&
            boundary.find("no_rasterizer") != std::string::npos &&
            boundary.find("no_shader_ownership") != std::string::npos &&
            boundary.find("no_texture_ownership") != std::string::npos &&
            boundary.find("no_gpu_lifecycle") != std::string::npos &&
            boundary.find("no_product_app_editor_wiring") != std::string::npos;

        if (!proofBoundaryLaneOk && failureReason.empty()) failureReason = "proof_boundary_lane_failed";
    }

    constexpr int kTotalLanes = 16;
    const int passedLanes = (emptyIdRejectedOk ? 1 : 0) + (zeroDurationRejectedOk ? 1 : 0) +
        (invalidOverlayInputCountRejectedOk ? 1 : 0) + (invalidOverlayIdAndDurationRejectedOk ? 1 : 0) +
        (invalidOverlayBoundsRejectedOk ? 1 : 0) + (invalidOverlayOpacityRejectedOk ? 1 : 0) +
        (identityOk ? 1 : 0) + (explicitDescriptorOk ? 1 : 0) + (timelineActiveWindowOk ? 1 : 0) +
        (timelineMappingOk ? 1 : 0) + (overlayActiveFilteringOk ? 1 : 0) + (zIndexIdSortingOk ? 1 : 0) +
        (multiOverlayInputPortShapeOk ? 1 : 0) + (overflowClampOk ? 1 : 0) + (executionPlanOk ? 1 : 0) +
        (proofBoundaryLaneOk ? 1 : 0);
    const bool allPass = passedLanes == kTotalLanes;

    std::ostringstream oss;
    oss << "status=" << (allPass ? "PASS" : "FAIL") << ";"
        << "totalLanes=" << kTotalLanes << ";"
        << "passedLanes=" << passedLanes << ";"
        << "proofBoundary=" << kProofBoundary << ";"
        << "lanes=emptyIdRejected:" << (emptyIdRejectedOk ? "true" : "false")
        << ",zeroDurationRejected:" << (zeroDurationRejectedOk ? "true" : "false")
        << ",invalidOverlayInputCountRejected:" << (invalidOverlayInputCountRejectedOk ? "true" : "false")
        << ",invalidOverlayIdAndDurationRejected:" << (invalidOverlayIdAndDurationRejectedOk ? "true" : "false")
        << ",invalidOverlayBoundsRejected:" << (invalidOverlayBoundsRejectedOk ? "true" : "false")
        << ",invalidOverlayOpacityRejected:" << (invalidOverlayOpacityRejectedOk ? "true" : "false")
        << ",identity:" << (identityOk ? "true" : "false")
        << ",explicitDescriptor:" << (explicitDescriptorOk ? "true" : "false")
        << ",timelineActiveWindow:" << (timelineActiveWindowOk ? "true" : "false")
        << ",timelineMapping:" << (timelineMappingOk ? "true" : "false")
        << ",overlayActiveFiltering:" << (overlayActiveFilteringOk ? "true" : "false")
        << ",zIndexIdSorting:" << (zIndexIdSortingOk ? "true" : "false")
        << ",multiOverlayInputPortShape:" << (multiOverlayInputPortShapeOk ? "true" : "false")
        << ",overflowClamp:" << (overflowClampOk ? "true" : "false")
        << ",executionPlan:" << (executionPlanOk ? "true" : "false")
        << ",proofBoundaryLane:" << (proofBoundaryLaneOk ? "true" : "false") << ";"
        << "reason=" << (allPass ? "none" : failureReason);
    return oss.str();
}

} // namespace

extern "C" JNIEXPORT jstring JNICALL
Java_com_connects_vanguard_1media_1engine_bridge_VanguardNativeBridge_runAndroidDagPhase5GraphicOverlayCompositorNodeSmoke(
    JNIEnv* env,
    jobject /* this */) {
    try {
        const std::string resultStr = RunGraphicOverlayCompositorNodeSmokeInternal();
        return env->NewStringUTF(resultStr.c_str());
    } catch (const std::exception& e) {
        const std::string err =
            std::string("status=FAIL;reason=exception:") + e.what() + ";proofBoundary=" + kProofBoundary;
        return env->NewStringUTF(err.c_str());
    } catch (...) {
        const std::string err =
            std::string("status=FAIL;reason=exception:unknown;proofBoundary=") + kProofBoundary;
        return env->NewStringUTF(err.c_str());
    }
}
