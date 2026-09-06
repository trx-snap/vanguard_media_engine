// P3-CAMERA-FRAME-SOURCE-NODE-A: platform-neutral logical DAG
// camera-frame-source-node diagnostic proof.
//
// Diagnostic-only: proves vanguard::sources::CameraFrameSourceNode's
// construction validation, identity/port shape, cameraId/orientation/
// mirror/live accessors, dimension accessors, and timeline-window
// semantics (mirroring DecodedMediaFrameSourceNode's and
// StreamSourceNode's precedent), plus a real GraphExecutionPlan
// source->sink pass using this node against the real
// vanguard::sinks::PreviewSurfaceSinkNode (PreviewSurfaceSinkNode's header
// is already reachable from this translation unit, mirroring
// android_phase6_stream_source_node_jni.cpp's precedent).
// CameraFrameSourceNode itself owns no Camera2 session, HardwareBuffer,
// frame buffer, texture, memory, or other OS resource and includes no
// Android/NDK/Camera2 headers.
//
// Non-claims: no Camera2 capture session, no hardware buffer ownership, no
// Android lifecycle, no product/editor/app/ConnectsApp wiring.
//
// This translation unit is Android-only and must NOT be included in iOS or
// host builds. It is added via the Android-only target_sources block in
// src/CMakeLists.txt.
//
// JNI entry point:
//   runAndroidDagPhase3CameraFrameSourceNodeSmoke -> jstring

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
#include "vanguard/sources/camera_frame_source_node.h"

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
using vanguard::sources::CameraFrameSourceNode;

constexpr const char* kProofBoundary =
    "platform_neutral_camera_frame_source_node_logical_dag_source_no_camera_hardware_ownership_"
    "no_android_lifecycle_no_product_app_editor_wiring";

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

std::string RunCameraFrameSourceNodeSmokeInternal() {
    bool emptyIdRejectedOk = false;
    bool emptyCameraIdRejectedOk = false;
    bool zeroDurationRejectedOk = false;
    bool invalidWidthRejectedOk = false;
    bool invalidHeightRejectedOk = false;
    bool invalidOrientationRejectedOk = false;
    bool identityOk = false;
    bool portShapeOk = false;
    bool accessorsOk = false;
    bool timelineActiveWindowOk = false;
    bool timelineMappingOk = false;
    bool saturatingEndOk = false;
    bool blendWeightsOk = false;
    bool executionPlanSourceToSinkOk = false;
    bool proofBoundaryLaneOk = false;
    std::string failureReason;

    // ---- Lane 1: empty id is rejected with empty_id ----
    {
        try {
            CameraFrameSourceNode node("", "cam_1", 0, 1000, 1920, 1080, 0, false, true);
            (void)node;
        } catch (const std::invalid_argument& e) {
            emptyIdRejectedOk = std::string(e.what()) == "empty_id";
        } catch (...) {
        }
        if (!emptyIdRejectedOk && failureReason.empty()) failureReason = "empty_id_rejected_failed";
    }

    // ---- Lane 2: empty cameraId is rejected with empty_camera_id ----
    {
        try {
            CameraFrameSourceNode node("cfs_empty_camera_id", "", 0, 1000, 1920, 1080, 0, false, true);
            (void)node;
        } catch (const std::invalid_argument& e) {
            emptyCameraIdRejectedOk = std::string(e.what()) == "empty_camera_id";
        } catch (...) {
        }
        if (!emptyCameraIdRejectedOk && failureReason.empty()) {
            failureReason = "empty_camera_id_rejected_failed";
        }
    }

    // ---- Lane 3: zero duration is rejected with invalid_duration_us ----
    {
        try {
            CameraFrameSourceNode node("cfs_zero_duration", "cam_1", 0, 0, 1920, 1080, 0, false, true);
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
            CameraFrameSourceNode node("cfs_zero_w", "cam_1", 0, 1000, 0, 1080, 0, false, true);
            (void)node;
        } catch (const std::invalid_argument& e) {
            zeroWidthRejected = std::string(e.what()) == "invalid_width";
        } catch (...) {
        }
        try {
            CameraFrameSourceNode node("cfs_neg_w", "cam_1", 0, 1000, -1, 1080, 0, false, true);
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
            CameraFrameSourceNode node("cfs_zero_h", "cam_1", 0, 1000, 1920, 0, 0, false, true);
            (void)node;
        } catch (const std::invalid_argument& e) {
            zeroHeightRejected = std::string(e.what()) == "invalid_height";
        } catch (...) {
        }
        try {
            CameraFrameSourceNode node("cfs_neg_h", "cam_1", 0, 1000, 1920, -1, 0, false, true);
            (void)node;
        } catch (const std::invalid_argument& e) {
            negativeHeightRejected = std::string(e.what()) == "invalid_height";
        } catch (...) {
        }
        invalidHeightRejectedOk = zeroHeightRejected && negativeHeightRejected;
        if (!invalidHeightRejectedOk && failureReason.empty()) failureReason = "invalid_height_rejected_failed";
    }

    // ---- Lane 6: invalid orientation rejected with invalid_sensor_orientation_degrees;
    //      valid values 0/90/180/270 accepted ----
    {
        bool invalid45Rejected = false;
        bool invalidNeg90Rejected = false;
        bool invalid360Rejected = false;
        try {
            CameraFrameSourceNode node("cfs_orient_45", "cam_1", 0, 1000, 1920, 1080, 45, false, true);
            (void)node;
        } catch (const std::invalid_argument& e) {
            invalid45Rejected = std::string(e.what()) == "invalid_sensor_orientation_degrees";
        } catch (...) {
        }
        try {
            CameraFrameSourceNode node("cfs_orient_neg90", "cam_1", 0, 1000, 1920, 1080, -90, false, true);
            (void)node;
        } catch (const std::invalid_argument& e) {
            invalidNeg90Rejected = std::string(e.what()) == "invalid_sensor_orientation_degrees";
        } catch (...) {
        }
        try {
            CameraFrameSourceNode node("cfs_orient_360", "cam_1", 0, 1000, 1920, 1080, 360, false, true);
            (void)node;
        } catch (const std::invalid_argument& e) {
            invalid360Rejected = std::string(e.what()) == "invalid_sensor_orientation_degrees";
        } catch (...) {
        }

        bool validOrientationsAccepted = true;
        for (const int32_t validOrientation : {0, 90, 180, 270}) {
            try {
                CameraFrameSourceNode node(
                    "cfs_orient_valid", "cam_1", 0, 1000, 1920, 1080, validOrientation, false, true);
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

    // ---- Lane 7: identity: id/kind/type (kSource, kCameraFrameSource) ----
    {
        CameraFrameSourceNode node("cfs_identity", "cam_identity", 1000, 5000, 1920, 1080, 0, false, true);
        identityOk = node.id() == "cfs_identity" &&
            node.kind() == NodeKind::kSource &&
            node.type() == NodeType::kCameraFrameSource;
        if (!identityOk && failureReason.empty()) failureReason = "identity_failed";
    }

    // ---- Lane 8: exact ports: zero inputs, one kVideoFrame output with PortDataType::kVideoFrame ----
    {
        CameraFrameSourceNode node("cfs_ports", "cam_1", 0, 1000, 1280, 720, 0, false, true);
        portShapeOk = node.inputPorts().empty() &&
            node.outputPorts().size() == 1 &&
            node.outputPorts()[0].id == "kVideoFrame" &&
            node.outputPorts()[0].dataType == PortDataType::kVideoFrame;
        if (!portShapeOk && failureReason.empty()) failureReason = "port_shape_failed";
    }

    // ---- Lane 9: cameraId/dimension/orientation/mirror/live accessors reflect
    //      constructor args for the 9-arg constructor, and the 6-arg delegating
    //      overload defaults sensorOrientationDegrees=0, mirrorHorizontal=false,
    //      live=true ----
    {
        CameraFrameSourceNode fullNode(
            "cfs_accessors_full", "cam_42", 0, 1000, 1920, 1080, 90, true, false);
        const bool fullOk = fullNode.cameraId() == "cam_42" &&
            fullNode.width() == 1920 && fullNode.height() == 1080 &&
            fullNode.sensorOrientationDegrees() == 90 &&
            fullNode.mirrorHorizontal() &&
            !fullNode.live();

        CameraFrameSourceNode defaultedNode("cfs_accessors_defaulted", "cam_7", 0, 1000, 1280, 720);
        const bool defaultedOk = defaultedNode.cameraId() == "cam_7" &&
            defaultedNode.width() == 1280 && defaultedNode.height() == 720 &&
            defaultedNode.sensorOrientationDegrees() == 0 &&
            !defaultedNode.mirrorHorizontal() &&
            defaultedNode.live();

        accessorsOk = fullOk && defaultedOk;
        if (!accessorsOk && failureReason.empty()) failureReason = "accessors_failed";
    }

    // ---- Lane 10: active window [start, start+duration) ----
    {
        constexpr uint64_t kStart = 10000;
        constexpr uint64_t kDuration = 5000;
        constexpr uint64_t kEnd = kStart + kDuration;
        CameraFrameSourceNode node(
            "cfs_active_window", "cam_1", kStart, kDuration, 1920, 1080, 0, false, true);

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
        CameraFrameSourceNode node("cfs_mapping", "cam_1", kStart, kDuration, 1920, 1080, 0, false, true);

        timelineMappingOk =
            node.mapTimelineToLocalPts(kStart - 1) == 0 &&
            node.mapTimelineToLocalPts(kStart) == 0 &&
            node.mapTimelineToLocalPts(kStart + 1234) == 1234 &&
            node.mapTimelineToLocalPts(kStart + kDuration) == kDuration &&
            node.mapTimelineToLocalPts(kStart + kDuration + 999) == kDuration;

        if (!timelineMappingOk && failureReason.empty()) failureReason = "timeline_mapping_failed";
    }

    // ---- Lane 12: overflow-safe timelineEndPtsUs() saturation to UINT64_MAX ----
    {
        constexpr uint64_t kMaxU64 = std::numeric_limits<uint64_t>::max();
        constexpr uint64_t kStart = kMaxU64 - 10;
        constexpr uint64_t kDuration = 1000; // start + duration overflows uint64_t
        CameraFrameSourceNode node("cfs_overflow", "cam_1", kStart, kDuration, 1920, 1080, 0, false, true);

        saturatingEndOk =
            node.timelineEndPtsUs() == kMaxU64 &&
            node.isActiveAt(kStart) &&
            node.isActiveAt(kMaxU64 - 1) &&
            !node.isActiveAt(kMaxU64) &&
            node.mapTimelineToLocalPts(kMaxU64) == kDuration;

        if (!saturatingEndOk && failureReason.empty()) failureReason = "saturating_end_failed";
    }

    // ---- Lane 13: blend weights 1 inside, 0 outside ----
    {
        constexpr uint64_t kStart = 2000;
        constexpr uint64_t kDuration = 3000;
        CameraFrameSourceNode node("cfs_blend", "cam_1", kStart, kDuration, 1920, 1080, 0, false, true);

        blendWeightsOk =
            node.blendWeightAt(kStart - 1) == 0.0f &&
            node.blendWeightAt(kStart + kDuration) == 0.0f &&
            node.blendWeightAt(kStart) == 1.0f &&
            node.blendWeightAt(kStart + kDuration - 1) == 1.0f;

        if (!blendWeightsOk && failureReason.empty()) failureReason = "blend_weights_failed";
    }

    // ---- Lane 14: real BuildGraphExecutionPlan pass from a real
    //      CameraFrameSourceNode to the real PreviewSurfaceSinkNode, verifying
    //      dependency order and input binding from kVideoFrame to video_in ----
    {
        Graph g;
        auto source = std::make_shared<CameraFrameSourceNode>(
            "cfs_plan_source", "cam_plan", 0, 5000, 1920, 1080, 0, false, true);
        auto sink = std::make_shared<PreviewSurfaceSinkNode>("cfs_plan_sink");

        const bool added = g.addNode(source).ok() && g.addNode(sink).ok();
        const bool wired = added &&
            g.connect("cfs_plan_source", "kVideoFrame", "cfs_plan_sink", "video_in").ok();

        FrameRequest req;
        req.generationId = g.generationId();
        req.timelinePtsUs = 0;

        GraphExecutionPlan plan;
        const auto status = BuildGraphExecutionPlan(g, req, plan);

        const auto* sinkNode = PlanFind(plan, "cfs_plan_sink");

        executionPlanSourceToSinkOk = wired && status.ok() &&
            plan.nodes.size() == 2 &&
            PlanIndexOf(plan, "cfs_plan_source") < PlanIndexOf(plan, "cfs_plan_sink") &&
            plan.sinkNodeIds.size() == 1 && plan.sinkNodeIds[0] == "cfs_plan_sink" &&
            sinkNode != nullptr && sinkNode->inputs.size() == 1 &&
            sinkNode->inputs[0].inputPortId == "video_in" &&
            sinkNode->inputs[0].fromNodeId == "cfs_plan_source" &&
            sinkNode->inputs[0].fromPortId == "kVideoFrame" &&
            sinkNode->inputs[0].dataType == PortDataType::kVideoFrame;

        if (!executionPlanSourceToSinkOk && failureReason.empty()) failureReason = "execution_plan_source_to_sink_failed";
    }

    // ---- Lane 15: proof boundary lane ----
    {
        const std::string boundary(kProofBoundary);
        proofBoundaryLaneOk =
            boundary.find("platform_neutral") != std::string::npos &&
            boundary.find("camera_frame_source_node") != std::string::npos &&
            boundary.find("logical_dag_source") != std::string::npos &&
            boundary.find("no_camera_hardware_ownership") != std::string::npos &&
            boundary.find("no_android_lifecycle") != std::string::npos &&
            boundary.find("no_product_app_editor_wiring") != std::string::npos;

        if (!proofBoundaryLaneOk && failureReason.empty()) failureReason = "proof_boundary_lane_failed";
    }

    constexpr int kTotalLanes = 15;
    const int passedLanes =
        (emptyIdRejectedOk ? 1 : 0) + (emptyCameraIdRejectedOk ? 1 : 0) +
        (zeroDurationRejectedOk ? 1 : 0) + (invalidWidthRejectedOk ? 1 : 0) +
        (invalidHeightRejectedOk ? 1 : 0) + (invalidOrientationRejectedOk ? 1 : 0) +
        (identityOk ? 1 : 0) + (portShapeOk ? 1 : 0) + (accessorsOk ? 1 : 0) +
        (timelineActiveWindowOk ? 1 : 0) + (timelineMappingOk ? 1 : 0) +
        (saturatingEndOk ? 1 : 0) + (blendWeightsOk ? 1 : 0) +
        (executionPlanSourceToSinkOk ? 1 : 0) + (proofBoundaryLaneOk ? 1 : 0);
    const bool allPass = passedLanes == kTotalLanes;

    std::ostringstream oss;
    oss << "status=" << (allPass ? "PASS" : "FAIL") << ";"
        << "totalLanes=" << kTotalLanes << ";"
        << "passedLanes=" << passedLanes << ";"
        << "proofBoundary=" << kProofBoundary << ";"
        << "lanes=emptyIdRejected:" << (emptyIdRejectedOk ? "true" : "false")
        << ",emptyCameraIdRejected:" << (emptyCameraIdRejectedOk ? "true" : "false")
        << ",zeroDurationRejected:" << (zeroDurationRejectedOk ? "true" : "false")
        << ",invalidWidthRejected:" << (invalidWidthRejectedOk ? "true" : "false")
        << ",invalidHeightRejected:" << (invalidHeightRejectedOk ? "true" : "false")
        << ",invalidOrientationRejected:" << (invalidOrientationRejectedOk ? "true" : "false")
        << ",identity:" << (identityOk ? "true" : "false")
        << ",portShape:" << (portShapeOk ? "true" : "false")
        << ",accessors:" << (accessorsOk ? "true" : "false")
        << ",timelineActiveWindow:" << (timelineActiveWindowOk ? "true" : "false")
        << ",timelineMapping:" << (timelineMappingOk ? "true" : "false")
        << ",saturatingEnd:" << (saturatingEndOk ? "true" : "false")
        << ",blendWeights:" << (blendWeightsOk ? "true" : "false")
        << ",executionPlanSourceToSink:" << (executionPlanSourceToSinkOk ? "true" : "false")
        << ",proofBoundaryLane:" << (proofBoundaryLaneOk ? "true" : "false") << ";"
        << "reason=" << (allPass ? "none" : failureReason);
    return oss.str();
}

} // namespace

extern "C" JNIEXPORT jstring JNICALL
Java_com_connects_vanguard_1media_1engine_bridge_VanguardNativeBridge_runAndroidDagPhase3CameraFrameSourceNodeSmoke(
    JNIEnv* env,
    jobject /* this */) {
    try {
        const std::string resultStr = RunCameraFrameSourceNodeSmokeInternal();
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
