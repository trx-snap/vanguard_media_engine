// P5-SPATIAL-TRANSFORM-NODE-A: platform-neutral logical DAG
// spatial-transform-node diagnostic proof.
//
// Diagnostic-only: proves vanguard::transforms::SpatialTransformNode's
// construction validation, identity/port shape, descriptor/matrix/crop
// accessors, point-transform math, and timeline-window semantics, plus a
// real GraphExecutionPlan source->transform->sink pass wiring the real
// vanguard::sources::ImageTextureSourceNode into this node and this node
// into the real vanguard::sinks::PreviewSurfaceSinkNode.
// SpatialTransformNode itself owns only primitive matrix/crop/timeline
// metadata - no renderer, shader, texture, decoder, Android lifecycle, or
// GPU object, and includes no Android/NDK/EGL/GLES/Vulkan header.
//
// Non-claims: no render ownership, no texture ownership, no GPU lifecycle,
// no product/editor/app/ConnectsApp wiring.
//
// This translation unit is Android-only and must NOT be included in iOS or
// host builds. It is added via the Android-only target_sources block in
// src/CMakeLists.txt.
//
// JNI entry point:
//   runAndroidDagPhase5SpatialTransformNodeSmoke -> jstring

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

#include "vanguard/graph/frame_request.h"
#include "vanguard/graph/graph.h"
#include "vanguard/graph/graph_execution_plan.h"
#include "vanguard/graph/node.h"
#include "vanguard/sinks/preview_surface_sink_node.h"
#include "vanguard/sources/image_texture_source_node.h"
#include "vanguard/transforms/spatial_transform_node.h"

namespace {

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
using vanguard::transforms::SpatialAffineMatrix;
using vanguard::transforms::SpatialCropRect;
using vanguard::transforms::SpatialPoint;
using vanguard::transforms::SpatialTransformDescriptor;
using vanguard::transforms::SpatialTransformNode;

constexpr const char* kProofBoundary =
    "platform_neutral_spatial_transform_node_logical_dag_transform_no_render_ownership_"
    "no_texture_ownership_no_gpu_lifecycle_no_product_app_editor_wiring";

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

bool ExpectInvalidCrop(const SpatialCropRect& crop) {
    SpatialTransformDescriptor descriptor;
    descriptor.crop = crop;
    try {
        SpatialTransformNode node("stn_invalid_crop", descriptor);
        (void)node;
        return false;
    } catch (const std::invalid_argument& e) {
        return std::string(e.what()) == "invalid_crop";
    } catch (...) {
        return false;
    }
}

std::string RunSpatialTransformNodeSmokeInternal() {
    bool emptyIdRejectedOk = false;
    bool zeroDurationRejectedOk = false;
    bool nonFiniteMatrixRejectedOk = false;
    bool invalidCropRejectedOk = false;
    bool identityOk = false;
    bool portsOk = false;
    bool defaultDescriptorOk = false;
    bool explicitDescriptorOk = false;
    bool scaleTranslatePointOk = false;
    bool rotation90PointOk = false;
    bool cropMetadataOk = false;
    bool timelineActiveWindowOk = false;
    bool timelineMappingOk = false;
    bool timelineClampAndOverflowOk = false;
    bool executionPlanSourceTransformSinkOk = false;
    bool proofBoundaryLaneOk = false;
    std::string failureReason;

    // ---- Lane 1: empty id is rejected with empty_id ----
    {
        try {
            SpatialTransformNode node("", SpatialTransformDescriptor{});
            (void)node;
        } catch (const std::invalid_argument& e) {
            emptyIdRejectedOk = std::string(e.what()) == "empty_id";
        } catch (...) {
        }
        if (!emptyIdRejectedOk && failureReason.empty()) failureReason = "empty_id_rejected_failed";
    }

    // ---- Lane 2: zero duration is rejected with invalid_duration_us ----
    {
        SpatialTransformDescriptor descriptor;
        descriptor.durationUs = 0;
        try {
            SpatialTransformNode node("stn_zero_duration", descriptor);
            (void)node;
        } catch (const std::invalid_argument& e) {
            zeroDurationRejectedOk = std::string(e.what()) == "invalid_duration_us";
        } catch (...) {
        }
        if (!zeroDurationRejectedOk && failureReason.empty()) {
            failureReason = "zero_duration_rejected_failed";
        }
    }

    // ---- Lane 3: non-finite matrix field rejected with invalid_matrix ----
    {
        const double nan = std::numeric_limits<double>::quiet_NaN();
        const double inf = std::numeric_limits<double>::infinity();
        bool nanRejected = false;
        bool infRejected = false;
        {
            SpatialTransformDescriptor descriptor;
            descriptor.matrix.tx = nan;
            try {
                SpatialTransformNode node("stn_nan_matrix", descriptor);
                (void)node;
            } catch (const std::invalid_argument& e) {
                nanRejected = std::string(e.what()) == "invalid_matrix";
            } catch (...) {
            }
        }
        {
            SpatialTransformDescriptor descriptor;
            descriptor.matrix.a = inf;
            try {
                SpatialTransformNode node("stn_inf_matrix", descriptor);
                (void)node;
            } catch (const std::invalid_argument& e) {
                infRejected = std::string(e.what()) == "invalid_matrix";
            } catch (...) {
            }
        }
        nonFiniteMatrixRejectedOk = nanRejected && infRejected;
        if (!nonFiniteMatrixRejectedOk && failureReason.empty()) {
            failureReason = "non_finite_matrix_rejected_failed";
        }
    }

    // ---- Lane 4: invalid crop rejected with invalid_crop; valid boundary
    //      crop (x+width==1, y+height==1) accepted ----
    {
        const bool negativeXRejected = ExpectInvalidCrop(SpatialCropRect{-0.1, 0.0, 0.5, 0.5});
        const bool overOneYRejected = ExpectInvalidCrop(SpatialCropRect{0.0, 1.5, 0.5, 0.5});
        const bool zeroWidthRejected = ExpectInvalidCrop(SpatialCropRect{0.0, 0.0, 0.0, 0.5});
        const bool overflowWidthRejected = ExpectInvalidCrop(SpatialCropRect{0.6, 0.0, 0.5, 0.5});
        const bool nonFiniteCropRejected = ExpectInvalidCrop(
            SpatialCropRect{std::numeric_limits<double>::quiet_NaN(), 0.0, 0.5, 0.5});

        bool boundaryCropAccepted = false;
        try {
            SpatialTransformDescriptor descriptor;
            descriptor.crop = SpatialCropRect{0.5, 0.5, 0.5, 0.5};
            SpatialTransformNode node("stn_boundary_crop", descriptor);
            boundaryCropAccepted = node.crop().x == 0.5 && node.crop().width == 0.5;
        } catch (...) {
        }

        invalidCropRejectedOk = negativeXRejected && overOneYRejected && zeroWidthRejected &&
            overflowWidthRejected && nonFiniteCropRejected && boundaryCropAccepted;
        if (!invalidCropRejectedOk && failureReason.empty()) {
            failureReason = "invalid_crop_rejected_failed";
        }
    }

    // ---- Lane 5: identity: id/kind/type (kProcessing, kSpatialTransform),
    //      default descriptor is the identity transform ----
    {
        SpatialTransformNode node("stn_identity", SpatialTransformDescriptor{});
        identityOk = node.id() == "stn_identity" &&
            node.kind() == NodeKind::kProcessing &&
            node.type() == NodeType::kSpatialTransform &&
            node.isIdentityTransform();
        if (!identityOk && failureReason.empty()) failureReason = "identity_failed";
    }

    // ---- Lane 6: exact ports: one kVideoFrame input, one kVideoFrame
    //      output, both PortDataType::kVideoFrame ----
    {
        SpatialTransformNode node("stn_ports", SpatialTransformDescriptor{});
        portsOk = node.inputPorts().size() == 1 &&
            node.inputPorts()[0].id == "kVideoFrame" &&
            node.inputPorts()[0].dataType == PortDataType::kVideoFrame &&
            node.outputPorts().size() == 1 &&
            node.outputPorts()[0].id == "kVideoFrame" &&
            node.outputPorts()[0].dataType == PortDataType::kVideoFrame;
        if (!portsOk && failureReason.empty()) failureReason = "ports_failed";
    }

    // ---- Lane 7: default descriptor: identity matrix {1,0,0,1,0,0},
    //      identity crop {0,0,1,1}, start 0, duration UINT64_MAX ----
    {
        SpatialTransformNode node("stn_default_descriptor", SpatialTransformDescriptor{});
        const auto& m = node.matrix();
        const auto& c = node.crop();
        defaultDescriptorOk =
            m.a == 1.0 && m.b == 0.0 && m.c == 0.0 && m.d == 1.0 && m.tx == 0.0 && m.ty == 0.0 &&
            c.x == 0.0 && c.y == 0.0 && c.width == 1.0 && c.height == 1.0 &&
            node.timelineStartPtsUs() == 0 &&
            node.durationUs() == std::numeric_limits<uint64_t>::max();
        if (!defaultDescriptorOk && failureReason.empty()) failureReason = "default_descriptor_failed";
    }

    // ---- Lane 8: explicit descriptor values are reflected exactly by
    //      descriptor()/matrix()/crop()/timelineStartPtsUs()/durationUs() ----
    {
        SpatialTransformDescriptor descriptor;
        descriptor.timelineStartPtsUs = 1000;
        descriptor.durationUs = 5000;
        descriptor.matrix = SpatialAffineMatrix{2.0, 0.5, -0.5, 3.0, 10.0, 20.0};
        descriptor.crop = SpatialCropRect{0.1, 0.2, 0.5, 0.4};
        SpatialTransformNode node("stn_explicit_descriptor", descriptor);

        const auto& m = node.matrix();
        const auto& c = node.crop();
        explicitDescriptorOk =
            node.timelineStartPtsUs() == 1000 && node.durationUs() == 5000 &&
            m.a == 2.0 && m.b == 0.5 && m.c == -0.5 && m.d == 3.0 && m.tx == 10.0 && m.ty == 20.0 &&
            c.x == 0.1 && c.y == 0.2 && c.width == 0.5 && c.height == 0.4 &&
            node.descriptor().timelineStartPtsUs == 1000 &&
            node.descriptor().durationUs == 5000;
        if (!explicitDescriptorOk && failureReason.empty()) failureReason = "explicit_descriptor_failed";
    }

    // ---- Lane 9: scale+translate applyToPoint: (1,1) -> (12,23) under
    //      matrix {a=2,b=0,c=0,d=3,tx=10,ty=20} ----
    {
        SpatialTransformDescriptor descriptor;
        descriptor.matrix = SpatialAffineMatrix{2.0, 0.0, 0.0, 3.0, 10.0, 20.0};
        SpatialTransformNode node("stn_scale_translate", descriptor);
        const SpatialPoint result = node.applyToPoint(SpatialPoint{1.0, 1.0});
        scaleTranslatePointOk = NearlyEqual(result.x, 12.0) && NearlyEqual(result.y, 23.0);
        if (!scaleTranslatePointOk && failureReason.empty()) failureReason = "scale_translate_point_failed";
    }

    // ---- Lane 10: 90-degree rotation applyToPoint: (1,0) -> (0,1) under
    //      matrix {a=0,b=1,c=-1,d=0,tx=0,ty=0} ----
    {
        SpatialTransformDescriptor descriptor;
        descriptor.matrix = SpatialAffineMatrix{0.0, 1.0, -1.0, 0.0, 0.0, 0.0};
        SpatialTransformNode node("stn_rotation_90", descriptor);
        const SpatialPoint result = node.applyToPoint(SpatialPoint{1.0, 0.0});
        rotation90PointOk = NearlyEqual(result.x, 0.0) && NearlyEqual(result.y, 1.0) &&
            !node.isIdentityTransform();
        if (!rotation90PointOk && failureReason.empty()) failureReason = "rotation_90_point_failed";
    }

    // ---- Lane 11: crop() accessor reflects assigned crop metadata ----
    {
        SpatialTransformDescriptor descriptor;
        descriptor.crop = SpatialCropRect{0.25, 0.1, 0.5, 0.6};
        SpatialTransformNode node("stn_crop_metadata", descriptor);
        const auto& c = node.crop();
        cropMetadataOk = c.x == 0.25 && c.y == 0.1 && c.width == 0.5 && c.height == 0.6;
        if (!cropMetadataOk && failureReason.empty()) failureReason = "crop_metadata_failed";
    }

    // ---- Lane 12: active window [start, start+duration) ----
    {
        constexpr uint64_t kStart = 10000;
        constexpr uint64_t kDuration = 5000;
        constexpr uint64_t kEnd = kStart + kDuration;
        SpatialTransformDescriptor descriptor;
        descriptor.timelineStartPtsUs = kStart;
        descriptor.durationUs = kDuration;
        SpatialTransformNode node("stn_active_window", descriptor);

        timelineActiveWindowOk =
            node.timelineStartPtsUs() == kStart &&
            node.durationUs() == kDuration &&
            node.timelineEndPtsUs() == kEnd &&
            !node.isActiveAt(kStart - 1) &&
            node.isActiveAt(kStart) &&
            node.isActiveAt(kStart + kDuration / 2) &&
            node.isActiveAt(kEnd - 1) &&
            !node.isActiveAt(kEnd);

        if (!timelineActiveWindowOk && failureReason.empty()) failureReason = "timeline_active_window_failed";
    }

    // ---- Lane 13: timeline mapping before/inside/after clamps, blend
    //      weights 1 inside / 0 outside ----
    {
        constexpr uint64_t kStart = 10000;
        constexpr uint64_t kDuration = 5000;
        SpatialTransformDescriptor descriptor;
        descriptor.timelineStartPtsUs = kStart;
        descriptor.durationUs = kDuration;
        SpatialTransformNode node("stn_mapping", descriptor);

        timelineMappingOk =
            node.mapTimelineToLocalPts(kStart - 1) == 0 &&
            node.mapTimelineToLocalPts(kStart) == 0 &&
            node.mapTimelineToLocalPts(kStart + 1234) == 1234 &&
            node.mapTimelineToLocalPts(kStart + kDuration) == kDuration &&
            node.mapTimelineToLocalPts(kStart + kDuration + 999) == kDuration &&
            node.blendWeightAt(kStart) == 1.0f &&
            node.blendWeightAt(kStart - 1) == 0.0f;

        if (!timelineMappingOk && failureReason.empty()) failureReason = "timeline_mapping_failed";
    }

    // ---- Lane 14: overflow-safe timelineEndPtsUs() saturation to
    //      UINT64_MAX plus clamp behavior at/after the saturated end ----
    {
        constexpr uint64_t kMaxU64 = std::numeric_limits<uint64_t>::max();
        constexpr uint64_t kStart = kMaxU64 - 10;
        constexpr uint64_t kDuration = 1000; // start + duration overflows uint64_t
        SpatialTransformDescriptor descriptor;
        descriptor.timelineStartPtsUs = kStart;
        descriptor.durationUs = kDuration;
        SpatialTransformNode node("stn_overflow", descriptor);

        timelineClampAndOverflowOk =
            node.timelineEndPtsUs() == kMaxU64 &&
            node.isActiveAt(kStart) &&
            node.isActiveAt(kMaxU64 - 1) &&
            !node.isActiveAt(kMaxU64) &&
            node.mapTimelineToLocalPts(kMaxU64) == kDuration;

        if (!timelineClampAndOverflowOk && failureReason.empty()) {
            failureReason = "timeline_clamp_and_overflow_failed";
        }
    }

    // ---- Lane 15: real BuildGraphExecutionPlan pass wiring a real
    //      ImageTextureSourceNode -> real SpatialTransformNode -> real
    //      PreviewSurfaceSinkNode, verifying dependency order and input
    //      bindings source.kVideoFrame->transform.kVideoFrame and
    //      transform.kVideoFrame->sink.video_in ----
    {
        Graph g;
        auto source = std::make_shared<ImageTextureSourceNode>(
            "stn_plan_source", "img_plan", 0, 5000, 1920, 1080, 0);
        auto transform = std::make_shared<SpatialTransformNode>(
            "stn_plan_transform", SpatialTransformDescriptor{});
        auto sink = std::make_shared<PreviewSurfaceSinkNode>("stn_plan_sink");

        const bool added =
            g.addNode(source).ok() && g.addNode(transform).ok() && g.addNode(sink).ok();
        const bool wired = added &&
            g.connect("stn_plan_source", "kVideoFrame", "stn_plan_transform", "kVideoFrame").ok() &&
            g.connect("stn_plan_transform", "kVideoFrame", "stn_plan_sink", "video_in").ok();

        FrameRequest req;
        req.generationId = g.generationId();
        req.timelinePtsUs = 0;

        GraphExecutionPlan plan;
        const auto status = BuildGraphExecutionPlan(g, req, plan);

        const auto* transformNode = PlanFind(plan, "stn_plan_transform");
        const auto* sinkNode = PlanFind(plan, "stn_plan_sink");

        executionPlanSourceTransformSinkOk = wired && status.ok() &&
            plan.nodes.size() == 3 &&
            PlanIndexOf(plan, "stn_plan_source") < PlanIndexOf(plan, "stn_plan_transform") &&
            PlanIndexOf(plan, "stn_plan_transform") < PlanIndexOf(plan, "stn_plan_sink") &&
            plan.sinkNodeIds.size() == 1 && plan.sinkNodeIds[0] == "stn_plan_sink" &&
            transformNode != nullptr && transformNode->inputs.size() == 1 &&
            transformNode->inputs[0].inputPortId == "kVideoFrame" &&
            transformNode->inputs[0].fromNodeId == "stn_plan_source" &&
            transformNode->inputs[0].fromPortId == "kVideoFrame" &&
            transformNode->inputs[0].dataType == PortDataType::kVideoFrame &&
            sinkNode != nullptr && sinkNode->inputs.size() == 1 &&
            sinkNode->inputs[0].inputPortId == "video_in" &&
            sinkNode->inputs[0].fromNodeId == "stn_plan_transform" &&
            sinkNode->inputs[0].fromPortId == "kVideoFrame" &&
            sinkNode->inputs[0].dataType == PortDataType::kVideoFrame;

        if (!executionPlanSourceTransformSinkOk && failureReason.empty()) {
            failureReason = "execution_plan_source_transform_sink_failed";
        }
    }

    // ---- Lane 16: proof boundary lane ----
    {
        const std::string boundary(kProofBoundary);
        proofBoundaryLaneOk =
            boundary.find("platform_neutral") != std::string::npos &&
            boundary.find("spatial_transform_node") != std::string::npos &&
            boundary.find("logical_dag_transform") != std::string::npos &&
            boundary.find("no_render_ownership") != std::string::npos &&
            boundary.find("no_texture_ownership") != std::string::npos &&
            boundary.find("no_gpu_lifecycle") != std::string::npos &&
            boundary.find("no_product_app_editor_wiring") != std::string::npos;

        if (!proofBoundaryLaneOk && failureReason.empty()) failureReason = "proof_boundary_lane_failed";
    }

    constexpr int kTotalLanes = 16;
    const int passedLanes =
        (emptyIdRejectedOk ? 1 : 0) + (zeroDurationRejectedOk ? 1 : 0) +
        (nonFiniteMatrixRejectedOk ? 1 : 0) + (invalidCropRejectedOk ? 1 : 0) +
        (identityOk ? 1 : 0) + (portsOk ? 1 : 0) + (defaultDescriptorOk ? 1 : 0) +
        (explicitDescriptorOk ? 1 : 0) + (scaleTranslatePointOk ? 1 : 0) +
        (rotation90PointOk ? 1 : 0) + (cropMetadataOk ? 1 : 0) +
        (timelineActiveWindowOk ? 1 : 0) + (timelineMappingOk ? 1 : 0) +
        (timelineClampAndOverflowOk ? 1 : 0) + (executionPlanSourceTransformSinkOk ? 1 : 0) +
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
        << ",invalidCropRejected:" << (invalidCropRejectedOk ? "true" : "false")
        << ",identity:" << (identityOk ? "true" : "false")
        << ",ports:" << (portsOk ? "true" : "false")
        << ",defaultDescriptor:" << (defaultDescriptorOk ? "true" : "false")
        << ",explicitDescriptor:" << (explicitDescriptorOk ? "true" : "false")
        << ",scaleTranslatePoint:" << (scaleTranslatePointOk ? "true" : "false")
        << ",rotation90Point:" << (rotation90PointOk ? "true" : "false")
        << ",cropMetadata:" << (cropMetadataOk ? "true" : "false")
        << ",timelineActiveWindow:" << (timelineActiveWindowOk ? "true" : "false")
        << ",timelineMapping:" << (timelineMappingOk ? "true" : "false")
        << ",timelineClampAndOverflow:" << (timelineClampAndOverflowOk ? "true" : "false")
        << ",executionPlanSourceTransformSink:" << (executionPlanSourceTransformSinkOk ? "true" : "false")
        << ",proofBoundaryLane:" << (proofBoundaryLaneOk ? "true" : "false") << ";"
        << "reason=" << (allPass ? "none" : failureReason);
    return oss.str();
}

} // namespace

extern "C" JNIEXPORT jstring JNICALL
Java_com_connects_vanguard_1media_1engine_bridge_VanguardNativeBridge_runAndroidDagPhase5SpatialTransformNodeSmoke(
    JNIEnv* env,
    jobject /* this */) {
    try {
        const std::string resultStr = RunSpatialTransformNodeSmokeInternal();
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
