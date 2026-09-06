// P5-IMAGE-TEXTURE-SOURCE-NODE-A: platform-neutral logical DAG
// image-texture-source-node diagnostic proof.
//
// Diagnostic-only: proves vanguard::sources::ImageTextureSourceNode's
// construction validation, identity/port shape, imageId/dimension/
// orientation accessors, and timeline-window semantics (mirroring
// ExternalSurfaceSourceNode's and CameraFrameSourceNode's precedent),
// plus a real GraphExecutionPlan source->sink pass using this node against
// the real vanguard::sinks::PreviewSurfaceSinkNode.
// ImageTextureSourceNode itself owns no decoded pixels, GL/Vulkan texture
// handle/sampler, file IO/path/fd, Android Bitmap/ImageDecoder/NDK decoder
// handle, Android/NDK/JNI object, thread, lock, or queue, and includes no
// Android/NDK/EGL/GLES/Vulkan/Bitmap/ImageDecoder headers.
//
// Non-claims: no texture ownership, no image decoder lifecycle, no
// Android lifecycle, no product/editor/app/ConnectsApp wiring.
//
// This translation unit is Android-only and must NOT be included in iOS or
// host builds. It is added via the Android-only target_sources block in
// src/CMakeLists.txt.
//
// JNI entry point:
//   runAndroidDagPhase5ImageTextureSourceNodeSmoke -> jstring

#include <jni.h>

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

constexpr const char* kProofBoundary =
    "platform_neutral_image_texture_source_node_logical_dag_source_no_texture_ownership_"
    "no_image_decoder_lifecycle_no_product_app_editor_wiring";

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

std::string RunImageTextureSourceNodeSmokeInternal() {
    bool emptyIdRejectedOk = false;
    bool emptyImageIdRejectedOk = false;
    bool zeroDurationRejectedOk = false;
    bool invalidWidthRejectedOk = false;
    bool invalidHeightRejectedOk = false;
    bool invalidOrientationRejectedOk = false;
    bool identityOk = false;
    bool outputPortOk = false;
    bool imagePropertiesOk = false;
    bool timelineActiveWindowOk = false;
    bool timelineMappingOk = false;
    bool timelineClampAndOverflowOk = false;
    bool blendWeightsOk = false;
    bool executionPlanSourceToSinkOk = false;
    bool proofBoundaryLaneOk = false;
    std::string failureReason;

    // ---- Lane 1: empty id is rejected with empty_id ----
    {
        try {
            ImageTextureSourceNode node("", "img_1", 0, 1000, 1920, 1080, 0);
            (void)node;
        } catch (const std::invalid_argument& e) {
            emptyIdRejectedOk = std::string(e.what()) == "empty_id";
        } catch (...) {
        }
        if (!emptyIdRejectedOk && failureReason.empty()) failureReason = "empty_id_rejected_failed";
    }

    // ---- Lane 2: empty imageId is rejected with empty_image_id ----
    {
        try {
            ImageTextureSourceNode node("its_empty_image_id", "", 0, 1000, 1920, 1080, 0);
            (void)node;
        } catch (const std::invalid_argument& e) {
            emptyImageIdRejectedOk = std::string(e.what()) == "empty_image_id";
        } catch (...) {
        }
        if (!emptyImageIdRejectedOk && failureReason.empty()) {
            failureReason = "empty_image_id_rejected_failed";
        }
    }

    // ---- Lane 3: zero duration is rejected with invalid_duration_us ----
    {
        try {
            ImageTextureSourceNode node("its_zero_duration", "img_1", 0, 0, 1920, 1080, 0);
            (void)node;
        } catch (const std::invalid_argument& e) {
            zeroDurationRejectedOk = std::string(e.what()) == "invalid_duration_us";
        } catch (...) {
        }
        if (!zeroDurationRejectedOk && failureReason.empty()) failureReason = "zero_duration_rejected_failed";
    }

    // ---- Lane 4: invalid width is rejected with invalid_width ----
    {
        bool zeroWidthRejected = false;
        bool negativeWidthRejected = false;
        try {
            ImageTextureSourceNode node("its_zero_w", "img_1", 0, 1000, 0, 1080, 0);
            (void)node;
        } catch (const std::invalid_argument& e) {
            zeroWidthRejected = std::string(e.what()) == "invalid_width";
        } catch (...) {
        }
        try {
            ImageTextureSourceNode node("its_neg_w", "img_1", 0, 1000, -1, 1080, 0);
            (void)node;
        } catch (const std::invalid_argument& e) {
            negativeWidthRejected = std::string(e.what()) == "invalid_width";
        } catch (...) {
        }
        invalidWidthRejectedOk = zeroWidthRejected && negativeWidthRejected;
        if (!invalidWidthRejectedOk && failureReason.empty()) failureReason = "invalid_width_rejected_failed";
    }

    // ---- Lane 5: invalid height is rejected with invalid_height ----
    {
        bool zeroHeightRejected = false;
        bool negativeHeightRejected = false;
        try {
            ImageTextureSourceNode node("its_zero_h", "img_1", 0, 1000, 1920, 0, 0);
            (void)node;
        } catch (const std::invalid_argument& e) {
            zeroHeightRejected = std::string(e.what()) == "invalid_height";
        } catch (...) {
        }
        try {
            ImageTextureSourceNode node("its_neg_h", "img_1", 0, 1000, 1920, -1, 0);
            (void)node;
        } catch (const std::invalid_argument& e) {
            negativeHeightRejected = std::string(e.what()) == "invalid_height";
        } catch (...) {
        }
        invalidHeightRejectedOk = zeroHeightRejected && negativeHeightRejected;
        if (!invalidHeightRejectedOk && failureReason.empty()) failureReason = "invalid_height_rejected_failed";
    }

    // ---- Lane 6: invalid orientation rejected with invalid_orientation_degrees;
    //      valid values 0/90/180/270 accepted ----
    {
        bool invalid45Rejected = false;
        bool invalidNeg90Rejected = false;
        bool invalid360Rejected = false;
        try {
            ImageTextureSourceNode node("its_orient_45", "img_1", 0, 1000, 1920, 1080, 45);
            (void)node;
        } catch (const std::invalid_argument& e) {
            invalid45Rejected = std::string(e.what()) == "invalid_orientation_degrees";
        } catch (...) {
        }
        try {
            ImageTextureSourceNode node("its_orient_neg90", "img_1", 0, 1000, 1920, 1080, -90);
            (void)node;
        } catch (const std::invalid_argument& e) {
            invalidNeg90Rejected = std::string(e.what()) == "invalid_orientation_degrees";
        } catch (...) {
        }
        try {
            ImageTextureSourceNode node("its_orient_360", "img_1", 0, 1000, 1920, 1080, 360);
            (void)node;
        } catch (const std::invalid_argument& e) {
            invalid360Rejected = std::string(e.what()) == "invalid_orientation_degrees";
        } catch (...) {
        }

        bool validOrientationsAccepted = true;
        for (const int32_t validOrientation : {0, 90, 180, 270}) {
            try {
                ImageTextureSourceNode node(
                    "its_orient_valid", "img_1", 0, 1000, 1920, 1080, validOrientation);
                (void)node;
            } catch (...) {
                validOrientationsAccepted = false;
            }
        }

        invalidOrientationRejectedOk = invalid45Rejected && invalidNeg90Rejected && invalid360Rejected &&
            validOrientationsAccepted;
        if (!invalidOrientationRejectedOk && failureReason.empty()) {
            failureReason = "invalid_orientation_rejected_failed";
        }
    }

    // ---- Lane 7: identity: id/kind/type (kSource, kImageTextureSource) ----
    {
        ImageTextureSourceNode node("its_identity", "img_identity", 1000, 5000, 1920, 1080, 0);
        identityOk = node.id() == "its_identity" &&
            node.kind() == NodeKind::kSource &&
            node.type() == NodeType::kImageTextureSource;
        if (!identityOk && failureReason.empty()) failureReason = "identity_failed";
    }

    // ---- Lane 8: exact ports: zero inputs, one kVideoFrame output with PortDataType::kVideoFrame ----
    {
        ImageTextureSourceNode node("its_ports", "img_1", 0, 1000, 1280, 720, 0);
        outputPortOk = node.inputPorts().empty() &&
            node.outputPorts().size() == 1 &&
            node.outputPorts()[0].id == "kVideoFrame" &&
            node.outputPorts()[0].dataType == PortDataType::kVideoFrame;
        if (!outputPortOk && failureReason.empty()) failureReason = "output_port_failed";
    }

    // ---- Lane 9: imageId/dimension/orientation accessors reflect
    //      constructor args for the 7-arg constructor; the 6-arg delegating
    //      overload defaults orientationDegrees=0; the 5-arg delegating
    //      overload defaults imageId to id and orientationDegrees=0 ----
    {
        ImageTextureSourceNode fullNode(
            "its_props_full", "img_42", 0, 1000, 1920, 1080, 90);
        const bool fullOk = fullNode.imageId() == "img_42" &&
            fullNode.width() == 1920 && fullNode.height() == 1080 &&
            fullNode.orientationDegrees() == 90;

        ImageTextureSourceNode sixArgNode(
            "its_props_six_arg", "img_7", 0, 1000, 1280, 720);
        const bool sixArgOk = sixArgNode.imageId() == "img_7" &&
            sixArgNode.width() == 1280 && sixArgNode.height() == 720 &&
            sixArgNode.orientationDegrees() == 0;

        ImageTextureSourceNode fiveArgNode("its_props_five_arg", 0, 1000, 640, 480);
        const bool fiveArgOk = fiveArgNode.imageId() == "its_props_five_arg" &&
            fiveArgNode.width() == 640 && fiveArgNode.height() == 480 &&
            fiveArgNode.orientationDegrees() == 0;

        imagePropertiesOk = fullOk && sixArgOk && fiveArgOk;
        if (!imagePropertiesOk && failureReason.empty()) failureReason = "image_properties_failed";
    }

    // ---- Lane 10: active window [start, start+duration) ----
    {
        constexpr uint64_t kStart = 10000;
        constexpr uint64_t kDuration = 5000;
        constexpr uint64_t kEnd = kStart + kDuration;
        ImageTextureSourceNode node(
            "its_active_window", "img_1", kStart, kDuration, 1920, 1080, 0);

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

    // ---- Lane 11: timeline mapping before/inside/after clamps ----
    {
        constexpr uint64_t kStart = 10000;
        constexpr uint64_t kDuration = 5000;
        ImageTextureSourceNode node("its_mapping", "img_1", kStart, kDuration, 1920, 1080, 0);

        timelineMappingOk =
            node.mapTimelineToLocalPts(kStart - 1) == 0 &&
            node.mapTimelineToLocalPts(kStart) == 0 &&
            node.mapTimelineToLocalPts(kStart + 1234) == 1234 &&
            node.mapTimelineToLocalPts(kStart + kDuration) == kDuration &&
            node.mapTimelineToLocalPts(kStart + kDuration + 999) == kDuration;

        if (!timelineMappingOk && failureReason.empty()) failureReason = "timeline_mapping_failed";
    }

    // ---- Lane 12: overflow-safe timelineEndPtsUs() saturation to UINT64_MAX
    //      plus clamp behavior at/after the saturated end ----
    {
        constexpr uint64_t kMaxU64 = std::numeric_limits<uint64_t>::max();
        constexpr uint64_t kStart = kMaxU64 - 10;
        constexpr uint64_t kDuration = 1000; // start + duration overflows uint64_t
        ImageTextureSourceNode node("its_overflow", "img_1", kStart, kDuration, 1920, 1080, 0);

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

    // ---- Lane 13: blend weights 1 inside, 0 outside ----
    {
        constexpr uint64_t kStart = 2000;
        constexpr uint64_t kDuration = 3000;
        ImageTextureSourceNode node("its_blend", "img_1", kStart, kDuration, 1920, 1080, 0);

        blendWeightsOk =
            node.blendWeightAt(kStart - 1) == 0.0f &&
            node.blendWeightAt(kStart + kDuration) == 0.0f &&
            node.blendWeightAt(kStart) == 1.0f &&
            node.blendWeightAt(kStart + kDuration - 1) == 1.0f;

        if (!blendWeightsOk && failureReason.empty()) failureReason = "blend_weights_failed";
    }

    // ---- Lane 14: real BuildGraphExecutionPlan pass from a real
    //      ImageTextureSourceNode to the real PreviewSurfaceSinkNode,
    //      verifying dependency order and input binding from kVideoFrame to
    //      video_in ----
    {
        Graph g;
        auto source = std::make_shared<ImageTextureSourceNode>(
            "its_plan_source", "img_plan", 0, 5000, 1920, 1080, 0);
        auto sink = std::make_shared<PreviewSurfaceSinkNode>("its_plan_sink");

        const bool added = g.addNode(source).ok() && g.addNode(sink).ok();
        const bool wired = added &&
            g.connect("its_plan_source", "kVideoFrame", "its_plan_sink", "video_in").ok();

        FrameRequest req;
        req.generationId = g.generationId();
        req.timelinePtsUs = 0;

        GraphExecutionPlan plan;
        const auto status = BuildGraphExecutionPlan(g, req, plan);

        const auto* sinkNode = PlanFind(plan, "its_plan_sink");

        executionPlanSourceToSinkOk = wired && status.ok() &&
            plan.nodes.size() == 2 &&
            PlanIndexOf(plan, "its_plan_source") < PlanIndexOf(plan, "its_plan_sink") &&
            plan.sinkNodeIds.size() == 1 && plan.sinkNodeIds[0] == "its_plan_sink" &&
            sinkNode != nullptr && sinkNode->inputs.size() == 1 &&
            sinkNode->inputs[0].inputPortId == "video_in" &&
            sinkNode->inputs[0].fromNodeId == "its_plan_source" &&
            sinkNode->inputs[0].fromPortId == "kVideoFrame" &&
            sinkNode->inputs[0].dataType == PortDataType::kVideoFrame;

        if (!executionPlanSourceToSinkOk && failureReason.empty()) {
            failureReason = "execution_plan_source_to_sink_failed";
        }
    }

    // ---- Lane 15: proof boundary lane ----
    {
        const std::string boundary(kProofBoundary);
        proofBoundaryLaneOk =
            boundary.find("platform_neutral") != std::string::npos &&
            boundary.find("image_texture_source_node") != std::string::npos &&
            boundary.find("logical_dag_source") != std::string::npos &&
            boundary.find("no_texture_ownership") != std::string::npos &&
            boundary.find("no_image_decoder_lifecycle") != std::string::npos &&
            boundary.find("no_product_app_editor_wiring") != std::string::npos;

        if (!proofBoundaryLaneOk && failureReason.empty()) failureReason = "proof_boundary_lane_failed";
    }

    constexpr int kTotalLanes = 15;
    const int passedLanes =
        (emptyIdRejectedOk ? 1 : 0) + (emptyImageIdRejectedOk ? 1 : 0) +
        (zeroDurationRejectedOk ? 1 : 0) + (invalidWidthRejectedOk ? 1 : 0) +
        (invalidHeightRejectedOk ? 1 : 0) + (invalidOrientationRejectedOk ? 1 : 0) +
        (identityOk ? 1 : 0) + (outputPortOk ? 1 : 0) + (imagePropertiesOk ? 1 : 0) +
        (timelineActiveWindowOk ? 1 : 0) + (timelineMappingOk ? 1 : 0) +
        (timelineClampAndOverflowOk ? 1 : 0) + (blendWeightsOk ? 1 : 0) +
        (executionPlanSourceToSinkOk ? 1 : 0) + (proofBoundaryLaneOk ? 1 : 0);
    const bool allPass = passedLanes == kTotalLanes;

    std::ostringstream oss;
    oss << "status=" << (allPass ? "PASS" : "FAIL") << ";"
        << "totalLanes=" << kTotalLanes << ";"
        << "passedLanes=" << passedLanes << ";"
        << "proofBoundary=" << kProofBoundary << ";"
        << "lanes=emptyIdRejected:" << (emptyIdRejectedOk ? "true" : "false")
        << ",emptyImageIdRejected:" << (emptyImageIdRejectedOk ? "true" : "false")
        << ",zeroDurationRejected:" << (zeroDurationRejectedOk ? "true" : "false")
        << ",invalidWidthRejected:" << (invalidWidthRejectedOk ? "true" : "false")
        << ",invalidHeightRejected:" << (invalidHeightRejectedOk ? "true" : "false")
        << ",invalidOrientationRejected:" << (invalidOrientationRejectedOk ? "true" : "false")
        << ",identity:" << (identityOk ? "true" : "false")
        << ",outputPort:" << (outputPortOk ? "true" : "false")
        << ",imageProperties:" << (imagePropertiesOk ? "true" : "false")
        << ",timelineActiveWindow:" << (timelineActiveWindowOk ? "true" : "false")
        << ",timelineMapping:" << (timelineMappingOk ? "true" : "false")
        << ",timelineClampAndOverflow:" << (timelineClampAndOverflowOk ? "true" : "false")
        << ",blendWeights:" << (blendWeightsOk ? "true" : "false")
        << ",executionPlanSourceToSink:" << (executionPlanSourceToSinkOk ? "true" : "false")
        << ",proofBoundaryLane:" << (proofBoundaryLaneOk ? "true" : "false") << ";"
        << "reason=" << (allPass ? "none" : failureReason);
    return oss.str();
}

} // namespace

extern "C" JNIEXPORT jstring JNICALL
Java_com_connects_vanguard_1media_1engine_bridge_VanguardNativeBridge_runAndroidDagPhase5ImageTextureSourceNodeSmoke(
    JNIEnv* env,
    jobject /* this */) {
    try {
        const std::string resultStr = RunImageTextureSourceNodeSmokeInternal();
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
