// P5-FILTER-NODE-A: platform-neutral logical DAG filter-node diagnostic
// proof.
//
// Diagnostic-only: proves vanguard::filters::FilterNode's construction
// validation, identity/port shape, descriptor/colorMatrix/beauty accessors,
// color-matrix application math, pass-through semantics, and
// timeline-window semantics, plus a real GraphExecutionPlan
// source->filter->sink pass wiring the real
// vanguard::sources::ImageTextureSourceNode into this node and this node
// into the real vanguard::sinks::PreviewSurfaceSinkNode. FilterNode itself
// owns only primitive color-matrix/Beauty-V2 parameter metadata and pure
// CPU sample math - no renderer, shader, texture, decoder, Android
// lifecycle, or GPU object, and includes no Android/NDK/EGL/GLES/Vulkan
// header.
//
// Non-claims: no shader ownership, no texture ownership, no GPU lifecycle,
// no product/editor/app/ConnectsApp wiring.
//
// This translation unit is Android-only and must NOT be included in iOS or
// host builds. It is added via the Android-only target_sources block in
// src/CMakeLists.txt.
//
// JNI entry point:
//   runAndroidDagPhase5FilterNodeSmoke -> jstring

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

#include "vanguard/filters/filter_node.h"
#include "vanguard/graph/frame_request.h"
#include "vanguard/graph/graph.h"
#include "vanguard/graph/graph_execution_plan.h"
#include "vanguard/graph/node.h"
#include "vanguard/sinks/preview_surface_sink_node.h"
#include "vanguard/sources/image_texture_source_node.h"

namespace {

using vanguard::filters::FilterBeautyV2Parameters;
using vanguard::filters::FilterColorMatrix;
using vanguard::filters::FilterDescriptor;
using vanguard::filters::FilterNode;
using vanguard::filters::FilterRgba;
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
    "platform_neutral_filter_node_logical_dag_filter_no_shader_ownership_no_texture_"
    "ownership_no_gpu_lifecycle_no_product_app_editor_wiring";

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

bool NearlyEqual(double a, double b, double epsilon = 1e-9) {
    return std::fabs(a - b) < epsilon;
}

std::string RunFilterNodeSmokeInternal() {
    bool emptyIdRejectedOk = false;
    bool zeroDurationRejectedOk = false;
    bool nonFiniteMatrixRejectedOk = false;
    bool invalidBeautyRejectedOk = false;
    bool identityOk = false;
    bool portsOk = false;
    bool defaultDescriptorOk = false;
    bool explicitColorMatrixDescriptorOk = false;
    bool explicitBeautyDescriptorOk = false;
    bool colorMatrixApplicationOk = false;
    bool disabledMatrixPassthroughOk = false;
    bool timelineActiveWindowOk = false;
    bool timelineMappingOk = false;
    bool timelineClampAndOverflowOk = false;
    bool executionPlanSourceFilterSinkOk = false;
    bool proofBoundaryLaneOk = false;
    std::string failureReason;

    // ---- Lane 1: empty id is rejected with empty_id ----
    {
        try {
            FilterNode node("", FilterDescriptor{});
            (void)node;
        } catch (const std::invalid_argument& e) {
            emptyIdRejectedOk = std::string(e.what()) == "empty_id";
        } catch (...) {
        }
        if (!emptyIdRejectedOk && failureReason.empty()) failureReason = "empty_id_rejected_failed";
    }

    // ---- Lane 2: zero duration is rejected with invalid_duration_us ----
    {
        FilterDescriptor descriptor;
        descriptor.durationUs = 0;
        try {
            FilterNode node("fn_zero_duration", descriptor);
            (void)node;
        } catch (const std::invalid_argument& e) {
            zeroDurationRejectedOk = std::string(e.what()) == "invalid_duration_us";
        } catch (...) {
        }
        if (!zeroDurationRejectedOk && failureReason.empty()) {
            failureReason = "zero_duration_rejected_failed";
        }
    }

    // ---- Lane 3: non-finite color matrix value rejected with
    //      invalid_color_matrix ----
    {
        const double nan = std::numeric_limits<double>::quiet_NaN();
        const double inf = std::numeric_limits<double>::infinity();
        bool nanRejected = false;
        bool infRejected = false;
        {
            FilterDescriptor descriptor;
            descriptor.colorMatrix.m[4] = nan;
            try {
                FilterNode node("fn_nan_matrix", descriptor);
                (void)node;
            } catch (const std::invalid_argument& e) {
                nanRejected = std::string(e.what()) == "invalid_color_matrix";
            } catch (...) {
            }
        }
        {
            FilterDescriptor descriptor;
            descriptor.colorMatrix.m[0] = inf;
            try {
                FilterNode node("fn_inf_matrix", descriptor);
                (void)node;
            } catch (const std::invalid_argument& e) {
                infRejected = std::string(e.what()) == "invalid_color_matrix";
            } catch (...) {
            }
        }
        nonFiniteMatrixRejectedOk = nanRejected && infRejected;
        if (!nonFiniteMatrixRejectedOk && failureReason.empty()) {
            failureReason = "non_finite_matrix_rejected_failed";
        }
    }

    // ---- Lane 4: invalid Beauty V2 parameters rejected with
    //      invalid_beauty_parameters (non-finite, negative, > 1); boundary
    //      values 0.0 and 1.0 accepted ----
    {
        bool nanRejected = false;
        bool negativeRejected = false;
        bool overOneRejected = false;
        bool boundaryAccepted = false;
        {
            FilterDescriptor descriptor;
            descriptor.beauty.intensity = std::numeric_limits<double>::quiet_NaN();
            try {
                FilterNode node("fn_nan_beauty", descriptor);
                (void)node;
            } catch (const std::invalid_argument& e) {
                nanRejected = std::string(e.what()) == "invalid_beauty_parameters";
            } catch (...) {
            }
        }
        {
            FilterDescriptor descriptor;
            descriptor.beauty.smoothing = -0.1;
            try {
                FilterNode node("fn_negative_beauty", descriptor);
                (void)node;
            } catch (const std::invalid_argument& e) {
                negativeRejected = std::string(e.what()) == "invalid_beauty_parameters";
            } catch (...) {
            }
        }
        {
            FilterDescriptor descriptor;
            descriptor.beauty.whitening = 1.1;
            try {
                FilterNode node("fn_over_one_beauty", descriptor);
                (void)node;
            } catch (const std::invalid_argument& e) {
                overOneRejected = std::string(e.what()) == "invalid_beauty_parameters";
            } catch (...) {
            }
        }
        try {
            FilterDescriptor descriptor;
            descriptor.beauty = FilterBeautyV2Parameters{0.0, 1.0, 0.0, 1.0};
            FilterNode node("fn_boundary_beauty", descriptor);
            boundaryAccepted = node.beauty().intensity == 0.0 && node.beauty().smoothing == 1.0 &&
                node.beauty().whitening == 0.0 && node.beauty().skinTone == 1.0;
        } catch (...) {
        }

        invalidBeautyRejectedOk =
            nanRejected && negativeRejected && overOneRejected && boundaryAccepted;
        if (!invalidBeautyRejectedOk && failureReason.empty()) {
            failureReason = "invalid_beauty_rejected_failed";
        }
    }

    // ---- Lane 5: identity: id/kind/type (kProcessing, kFilter), default
    //      descriptor is pass-through with no effect enabled ----
    {
        FilterNode node("fn_identity", FilterDescriptor{});
        identityOk = node.id() == "fn_identity" && node.kind() == NodeKind::kProcessing &&
            node.type() == NodeType::kFilter && node.isPassThrough() &&
            !node.hasColorMatrix() && !node.hasBeautyV2();
        if (!identityOk && failureReason.empty()) failureReason = "identity_failed";
    }

    // ---- Lane 6: exact ports: one kVideoFrame input, one kVideoFrame
    //      output, both PortDataType::kVideoFrame ----
    {
        FilterNode node("fn_ports", FilterDescriptor{});
        portsOk = node.inputPorts().size() == 1 && node.inputPorts()[0].id == "kVideoFrame" &&
            node.inputPorts()[0].dataType == PortDataType::kVideoFrame &&
            node.outputPorts().size() == 1 && node.outputPorts()[0].id == "kVideoFrame" &&
            node.outputPorts()[0].dataType == PortDataType::kVideoFrame;
        if (!portsOk && failureReason.empty()) failureReason = "ports_failed";
    }

    // ---- Lane 7: default descriptor: identity color matrix, zeroed Beauty
    //      parameters, no effect enabled, start 0, duration UINT64_MAX ----
    {
        FilterNode node("fn_default_descriptor", FilterDescriptor{});
        const auto& cm = node.colorMatrix();
        constexpr double kIdentity[20] = {
            1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0,
            0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0,
        };
        bool matrixIdentity = true;
        for (int i = 0; i < 20; ++i) {
            if (cm.m[i] != kIdentity[i]) {
                matrixIdentity = false;
                break;
            }
        }
        const auto& b = node.beauty();
        defaultDescriptorOk = matrixIdentity && !node.hasColorMatrix() && !node.hasBeautyV2() &&
            b.intensity == 0.0 && b.smoothing == 0.0 && b.whitening == 0.0 &&
            b.skinTone == 0.0 && node.timelineStartPtsUs() == 0 &&
            node.durationUs() == std::numeric_limits<uint64_t>::max();
        if (!defaultDescriptorOk && failureReason.empty()) failureReason = "default_descriptor_failed";
    }

    // ---- Lane 8: explicit color matrix descriptor values are reflected
    //      exactly by descriptor()/colorMatrix(), hasColorMatrix() is true,
    //      isPassThrough() is false ----
    {
        FilterDescriptor descriptor;
        descriptor.timelineStartPtsUs = 1000;
        descriptor.durationUs = 5000;
        descriptor.colorMatrixEnabled = true;
        for (int i = 0; i < 20; ++i) {
            descriptor.colorMatrix.m[i] = static_cast<double>(i) * 0.1;
        }
        FilterNode node("fn_explicit_color_matrix", descriptor);

        const auto& cm = node.colorMatrix();
        bool matrixMatches = true;
        for (int i = 0; i < 20; ++i) {
            if (cm.m[i] != descriptor.colorMatrix.m[i]) {
                matrixMatches = false;
                break;
            }
        }
        explicitColorMatrixDescriptorOk = node.timelineStartPtsUs() == 1000 &&
            node.durationUs() == 5000 && node.hasColorMatrix() && matrixMatches &&
            !node.isPassThrough();
        if (!explicitColorMatrixDescriptorOk && failureReason.empty()) {
            failureReason = "explicit_color_matrix_descriptor_failed";
        }
    }

    // ---- Lane 9: explicit Beauty V2 descriptor values are reflected
    //      exactly by descriptor()/beauty(), hasBeautyV2() is true,
    //      isPassThrough() is false ----
    {
        FilterDescriptor descriptor;
        descriptor.beautyV2Enabled = true;
        descriptor.beauty = FilterBeautyV2Parameters{0.5, 0.6, 0.7, 0.8};
        FilterNode node("fn_explicit_beauty", descriptor);

        const auto& b = node.beauty();
        explicitBeautyDescriptorOk = node.hasBeautyV2() && !node.isPassThrough() &&
            b.intensity == 0.5 && b.smoothing == 0.6 && b.whitening == 0.7 && b.skinTone == 0.8 &&
            node.descriptor().beauty.intensity == 0.5;
        if (!explicitBeautyDescriptorOk && failureReason.empty()) {
            failureReason = "explicit_beauty_descriptor_failed";
        }
    }

    // ---- Lane 10: applyColorMatrix computes the 4x5 row-weighted sum plus
    //      offset for each channel when colorMatrixEnabled is true ----
    {
        FilterDescriptor descriptor;
        descriptor.colorMatrixEnabled = true;
        descriptor.colorMatrix.m[0] = 2.0;  // row0 R weight
        descriptor.colorMatrix.m[4] = 0.1;  // row0 offset
        descriptor.colorMatrix.m[6] = 0.5;  // row1 G weight
        descriptor.colorMatrix.m[14] = 0.2; // row2 offset
        FilterNode node("fn_color_matrix_math", descriptor);

        const FilterRgba result = node.applyColorMatrix(FilterRgba{0.3, 0.4, 0.5, 1.0});
        colorMatrixApplicationOk = NearlyEqual(result.r, 0.7) && NearlyEqual(result.g, 0.2) &&
            NearlyEqual(result.b, 0.7) && NearlyEqual(result.a, 1.0);
        if (!colorMatrixApplicationOk && failureReason.empty()) {
            failureReason = "color_matrix_application_failed";
        }
    }

    // ---- Lane 11: applyColorMatrix returns the input unchanged when
    //      colorMatrixEnabled is false, regardless of stored matrix values ----
    {
        FilterDescriptor descriptor;
        descriptor.colorMatrixEnabled = false;
        descriptor.colorMatrix.m[0] = 99.0;
        descriptor.colorMatrix.m[19] = 42.0;
        FilterNode node("fn_disabled_matrix_passthrough", descriptor);

        const FilterRgba input{0.11, 0.22, 0.33, 0.44};
        const FilterRgba result = node.applyColorMatrix(input);
        disabledMatrixPassthroughOk = result.r == input.r && result.g == input.g &&
            result.b == input.b && result.a == input.a && !node.hasColorMatrix();
        if (!disabledMatrixPassthroughOk && failureReason.empty()) {
            failureReason = "disabled_matrix_passthrough_failed";
        }
    }

    // ---- Lane 12: active window [start, start+duration) ----
    {
        constexpr uint64_t kStart = 10000;
        constexpr uint64_t kDuration = 5000;
        constexpr uint64_t kEnd = kStart + kDuration;
        FilterDescriptor descriptor;
        descriptor.timelineStartPtsUs = kStart;
        descriptor.durationUs = kDuration;
        FilterNode node("fn_active_window", descriptor);

        timelineActiveWindowOk = node.timelineStartPtsUs() == kStart &&
            node.durationUs() == kDuration && node.timelineEndPtsUs() == kEnd &&
            !node.isActiveAt(kStart - 1) && node.isActiveAt(kStart) &&
            node.isActiveAt(kStart + kDuration / 2) && node.isActiveAt(kEnd - 1) &&
            !node.isActiveAt(kEnd);

        if (!timelineActiveWindowOk && failureReason.empty()) {
            failureReason = "timeline_active_window_failed";
        }
    }

    // ---- Lane 13: timeline mapping before/inside/after clamps, blend
    //      weights 1 inside / 0 outside ----
    {
        constexpr uint64_t kStart = 10000;
        constexpr uint64_t kDuration = 5000;
        FilterDescriptor descriptor;
        descriptor.timelineStartPtsUs = kStart;
        descriptor.durationUs = kDuration;
        FilterNode node("fn_mapping", descriptor);

        timelineMappingOk = node.mapTimelineToLocalPts(kStart - 1) == 0 &&
            node.mapTimelineToLocalPts(kStart) == 0 &&
            node.mapTimelineToLocalPts(kStart + 1234) == 1234 &&
            node.mapTimelineToLocalPts(kStart + kDuration) == kDuration &&
            node.mapTimelineToLocalPts(kStart + kDuration + 999) == kDuration &&
            node.blendWeightAt(kStart) == 1.0f && node.blendWeightAt(kStart - 1) == 0.0f;

        if (!timelineMappingOk && failureReason.empty()) failureReason = "timeline_mapping_failed";
    }

    // ---- Lane 14: overflow-safe timelineEndPtsUs() saturation to
    //      UINT64_MAX plus clamp behavior at/after the saturated end ----
    {
        constexpr uint64_t kMaxU64 = std::numeric_limits<uint64_t>::max();
        constexpr uint64_t kStart = kMaxU64 - 10;
        constexpr uint64_t kDuration = 1000; // start + duration overflows uint64_t
        FilterDescriptor descriptor;
        descriptor.timelineStartPtsUs = kStart;
        descriptor.durationUs = kDuration;
        FilterNode node("fn_overflow", descriptor);

        timelineClampAndOverflowOk = node.timelineEndPtsUs() == kMaxU64 &&
            node.isActiveAt(kStart) && node.isActiveAt(kMaxU64 - 1) &&
            !node.isActiveAt(kMaxU64) && node.mapTimelineToLocalPts(kMaxU64) == kDuration;

        if (!timelineClampAndOverflowOk && failureReason.empty()) {
            failureReason = "timeline_clamp_and_overflow_failed";
        }
    }

    // ---- Lane 15: real BuildGraphExecutionPlan pass wiring a real
    //      ImageTextureSourceNode -> real FilterNode -> real
    //      PreviewSurfaceSinkNode, verifying dependency order and input
    //      bindings source.kVideoFrame->filter.kVideoFrame and
    //      filter.kVideoFrame->sink.video_in ----
    {
        Graph g;
        auto source = std::make_shared<ImageTextureSourceNode>(
            "fn_plan_source", "img_plan", 0, 5000, 1920, 1080, 0);
        auto filter = std::make_shared<FilterNode>("fn_plan_filter", FilterDescriptor{});
        auto sink = std::make_shared<PreviewSurfaceSinkNode>("fn_plan_sink");

        const bool added = g.addNode(source).ok() && g.addNode(filter).ok() && g.addNode(sink).ok();
        const bool wired = added &&
            g.connect("fn_plan_source", "kVideoFrame", "fn_plan_filter", "kVideoFrame").ok() &&
            g.connect("fn_plan_filter", "kVideoFrame", "fn_plan_sink", "video_in").ok();

        FrameRequest req;
        req.generationId = g.generationId();
        req.timelinePtsUs = 0;

        GraphExecutionPlan plan;
        const auto status = BuildGraphExecutionPlan(g, req, plan);

        const auto* filterNode = PlanFind(plan, "fn_plan_filter");
        const auto* sinkNode = PlanFind(plan, "fn_plan_sink");

        executionPlanSourceFilterSinkOk = wired && status.ok() && plan.nodes.size() == 3 &&
            PlanIndexOf(plan, "fn_plan_source") < PlanIndexOf(plan, "fn_plan_filter") &&
            PlanIndexOf(plan, "fn_plan_filter") < PlanIndexOf(plan, "fn_plan_sink") &&
            plan.sinkNodeIds.size() == 1 && plan.sinkNodeIds[0] == "fn_plan_sink" &&
            filterNode != nullptr && filterNode->inputs.size() == 1 &&
            filterNode->inputs[0].inputPortId == "kVideoFrame" &&
            filterNode->inputs[0].fromNodeId == "fn_plan_source" &&
            filterNode->inputs[0].fromPortId == "kVideoFrame" &&
            filterNode->inputs[0].dataType == PortDataType::kVideoFrame &&
            sinkNode != nullptr && sinkNode->inputs.size() == 1 &&
            sinkNode->inputs[0].inputPortId == "video_in" &&
            sinkNode->inputs[0].fromNodeId == "fn_plan_filter" &&
            sinkNode->inputs[0].fromPortId == "kVideoFrame" &&
            sinkNode->inputs[0].dataType == PortDataType::kVideoFrame;

        if (!executionPlanSourceFilterSinkOk && failureReason.empty()) {
            failureReason = "execution_plan_source_filter_sink_failed";
        }
    }

    // ---- Lane 16: proof boundary lane ----
    {
        const std::string boundary(kProofBoundary);
        proofBoundaryLaneOk = boundary.find("platform_neutral") != std::string::npos &&
            boundary.find("filter_node") != std::string::npos &&
            boundary.find("logical_dag_filter") != std::string::npos &&
            boundary.find("no_shader_ownership") != std::string::npos &&
            boundary.find("no_texture_ownership") != std::string::npos &&
            boundary.find("no_gpu_lifecycle") != std::string::npos &&
            boundary.find("no_product_app_editor_wiring") != std::string::npos;

        if (!proofBoundaryLaneOk && failureReason.empty()) failureReason = "proof_boundary_lane_failed";
    }

    constexpr int kTotalLanes = 16;
    const int passedLanes = (emptyIdRejectedOk ? 1 : 0) + (zeroDurationRejectedOk ? 1 : 0) +
        (nonFiniteMatrixRejectedOk ? 1 : 0) + (invalidBeautyRejectedOk ? 1 : 0) +
        (identityOk ? 1 : 0) + (portsOk ? 1 : 0) + (defaultDescriptorOk ? 1 : 0) +
        (explicitColorMatrixDescriptorOk ? 1 : 0) + (explicitBeautyDescriptorOk ? 1 : 0) +
        (colorMatrixApplicationOk ? 1 : 0) + (disabledMatrixPassthroughOk ? 1 : 0) +
        (timelineActiveWindowOk ? 1 : 0) + (timelineMappingOk ? 1 : 0) +
        (timelineClampAndOverflowOk ? 1 : 0) + (executionPlanSourceFilterSinkOk ? 1 : 0) +
        (proofBoundaryLaneOk ? 1 : 0);
    const bool allPass = passedLanes == kTotalLanes;

    std::ostringstream oss;
    oss << "status=" << (allPass ? "PASS" : "FAIL") << ";"
        << "totalLanes=" << kTotalLanes << ";"
        << "passedLanes=" << passedLanes << ";"
        << "proofBoundary=" << kProofBoundary << ";"
        << "lanes=emptyIdRejected:" << (emptyIdRejectedOk ? "true" : "false")
        << ",zeroDurationRejected:" << (zeroDurationRejectedOk ? "true" : "false")
        << ",nonFiniteMatrixRejected:" << (nonFiniteMatrixRejectedOk ? "true" : "false")
        << ",invalidBeautyRejected:" << (invalidBeautyRejectedOk ? "true" : "false")
        << ",identity:" << (identityOk ? "true" : "false")
        << ",ports:" << (portsOk ? "true" : "false")
        << ",defaultDescriptor:" << (defaultDescriptorOk ? "true" : "false")
        << ",explicitColorMatrixDescriptor:" << (explicitColorMatrixDescriptorOk ? "true" : "false")
        << ",explicitBeautyDescriptor:" << (explicitBeautyDescriptorOk ? "true" : "false")
        << ",colorMatrixApplication:" << (colorMatrixApplicationOk ? "true" : "false")
        << ",disabledMatrixPassthrough:" << (disabledMatrixPassthroughOk ? "true" : "false")
        << ",timelineActiveWindow:" << (timelineActiveWindowOk ? "true" : "false")
        << ",timelineMapping:" << (timelineMappingOk ? "true" : "false")
        << ",timelineClampAndOverflow:" << (timelineClampAndOverflowOk ? "true" : "false")
        << ",executionPlanSourceFilterSink:" << (executionPlanSourceFilterSinkOk ? "true" : "false")
        << ",proofBoundaryLane:" << (proofBoundaryLaneOk ? "true" : "false") << ";"
        << "reason=" << (allPass ? "none" : failureReason);
    return oss.str();
}

} // namespace

extern "C" JNIEXPORT jstring JNICALL
Java_com_connects_vanguard_1media_1engine_bridge_VanguardNativeBridge_runAndroidDagPhase5FilterNodeSmoke(
    JNIEnv* env,
    jobject /* this */) {
    try {
        const std::string resultStr = RunFilterNodeSmokeInternal();
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
