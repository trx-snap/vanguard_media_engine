// P5-IMAGE-OPTIMIZER-SINK-NODE-A: platform-neutral logical DAG
// image-optimizer-sink-node diagnostic proof.
//
// Diagnostic-only: proves vanguard::sinks::ImageOptimizerSinkNode's
// construction validation, identity/port shape, descriptor/target/quality/
// format/boolean accessors, and timeline-window semantics, plus a real
// GraphExecutionPlan source->sink pass wiring a real
// vanguard::sources::ImageTextureSourceNode into this node, and a
// missing-input fail-closed lane. ImageOptimizerSinkNode itself owns only
// primitive target/quality/format/timeline metadata and pure topology - no
// decoded pixels, Bitmap/ImageDecoder lifecycle, JPEG/PNG/HEIC encoder
// lifecycle, output file/path/file descriptor, GPU texture/sampler/
// lifecycle, Android lifecycle, MediaCodec, thread, or product/app/editor/
// ConnectsApp wiring, and includes no Android/NDK/EGL/GLES/Vulkan header.
//
// Non-claims: no decode/downscale/encode ownership, no file IO, no GPU
// lifecycle, no product/editor/app/ConnectsApp wiring.
//
// This translation unit is Android-only and must NOT be included in iOS or
// host builds. It is added via the Android-only target_sources block in
// src/CMakeLists.txt.
//
// JNI entry point:
//   runAndroidDagPhase5ImageOptimizerSinkNodeSmoke -> jstring

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
#include "vanguard/sinks/image_optimizer_sink_node.h"
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
using vanguard::sinks::ImageOptimizerOutputFormat;
using vanguard::sinks::ImageOptimizerSinkDescriptor;
using vanguard::sinks::ImageOptimizerSinkNode;
using vanguard::sources::ImageTextureSourceNode;

constexpr const char* kProofBoundary =
    "platform_neutral_image_optimizer_sink_node_logical_dag_sink_no_decode_no_downscale_"
    "no_encode_no_file_io_no_gpu_lifecycle_no_product_app_editor_wiring";

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

bool ExpectInvalidConstruction(const std::string& id,
                                const ImageOptimizerSinkDescriptor& descriptor,
                                const std::string& expectedReason) {
    try {
        ImageOptimizerSinkNode node(id, descriptor);
        (void)node;
        return false;
    } catch (const std::invalid_argument& e) {
        return std::string(e.what()) == expectedReason;
    } catch (...) {
        return false;
    }
}

std::string RunImageOptimizerSinkNodeSmokeInternal() {
    bool emptyIdRejectedOk = false;
    bool zeroDurationRejectedOk = false;
    bool invalidDimensionsRejectedOk = false;
    bool invalidQualityRejectedOk = false;
    bool identityOk = false;
    bool portShapeOk = false;
    bool defaultDescriptorOk = false;
    bool explicitDescriptorOk = false;
    bool timelineActiveWindowOk = false;
    bool timelineMappingOk = false;
    bool blendWeightsOk = false;
    bool overflowClampOk = false;
    bool executionPlanOk = false;
    bool missingInputFailClosedOk = false;
    bool proofBoundaryLaneOk = false;
    std::string failureReason;

    // ---- Lane 1: empty id is rejected with empty_id ----
    {
        emptyIdRejectedOk =
            ExpectInvalidConstruction("", ImageOptimizerSinkDescriptor{}, "empty_id");
        if (!emptyIdRejectedOk && failureReason.empty()) failureReason = "empty_id_rejected_failed";
    }

    // ---- Lane 2: zero duration is rejected with invalid_duration_us ----
    {
        ImageOptimizerSinkDescriptor descriptor;
        descriptor.durationUs = 0;
        zeroDurationRejectedOk =
            ExpectInvalidConstruction("optimizer_zero_duration", descriptor, "invalid_duration_us");
        if (!zeroDurationRejectedOk && failureReason.empty()) {
            failureReason = "zero_duration_rejected_failed";
        }
    }

    // ---- Lane 3: zero or negative targetWidth or targetHeight is rejected
    //      with invalid_target_dimensions ----
    {
        ImageOptimizerSinkDescriptor zeroWidth;
        zeroWidth.targetWidth = 0;
        ImageOptimizerSinkDescriptor zeroHeight;
        zeroHeight.targetHeight = 0;
        ImageOptimizerSinkDescriptor negativeWidth;
        negativeWidth.targetWidth = -1;
        ImageOptimizerSinkDescriptor negativeHeight;
        negativeHeight.targetHeight = -1;

        const bool zeroWidthRejected =
            ExpectInvalidConstruction("optimizer_zero_width", zeroWidth, "invalid_target_dimensions");
        const bool zeroHeightRejected =
            ExpectInvalidConstruction("optimizer_zero_height", zeroHeight, "invalid_target_dimensions");
        const bool negativeWidthRejected = ExpectInvalidConstruction(
            "optimizer_negative_width", negativeWidth, "invalid_target_dimensions");
        const bool negativeHeightRejected = ExpectInvalidConstruction(
            "optimizer_negative_height", negativeHeight, "invalid_target_dimensions");

        invalidDimensionsRejectedOk =
            zeroWidthRejected && zeroHeightRejected && negativeWidthRejected && negativeHeightRejected;
        if (!invalidDimensionsRejectedOk && failureReason.empty()) {
            failureReason = "invalid_target_dimensions_rejected_failed";
        }
    }

    // ---- Lane 4: qualityPercent outside [1,100] is rejected with
    //      invalid_quality_percent; boundary values 1 and 100 accepted ----
    {
        ImageOptimizerSinkDescriptor zeroQuality;
        zeroQuality.qualityPercent = 0;
        ImageOptimizerSinkDescriptor overQuality;
        overQuality.qualityPercent = 101;

        const bool zeroRejected =
            ExpectInvalidConstruction("optimizer_zero_quality", zeroQuality, "invalid_quality_percent");
        const bool overRejected =
            ExpectInvalidConstruction("optimizer_over_quality", overQuality, "invalid_quality_percent");

        bool boundaryOneAccepted = false;
        bool boundaryHundredAccepted = false;
        try {
            ImageOptimizerSinkDescriptor descriptor;
            descriptor.qualityPercent = 1;
            ImageOptimizerSinkNode node("optimizer_quality_one", descriptor);
            boundaryOneAccepted = node.qualityPercent() == 1;
        } catch (...) {
        }
        try {
            ImageOptimizerSinkDescriptor descriptor;
            descriptor.qualityPercent = 100;
            ImageOptimizerSinkNode node("optimizer_quality_hundred", descriptor);
            boundaryHundredAccepted = node.qualityPercent() == 100;
        } catch (...) {
        }

        invalidQualityRejectedOk =
            zeroRejected && overRejected && boundaryOneAccepted && boundaryHundredAccepted;
        if (!invalidQualityRejectedOk && failureReason.empty()) {
            failureReason = "invalid_quality_percent_rejected_failed";
        }
    }

    // ---- Lane 5: identity: id/kind/type (kSink, kImageOptimizerSink) ----
    {
        ImageOptimizerSinkNode node("optimizer_identity", ImageOptimizerSinkDescriptor{});
        identityOk = node.id() == "optimizer_identity" && node.kind() == NodeKind::kSink &&
            node.type() == NodeType::kImageOptimizerSink;
        if (!identityOk && failureReason.empty()) failureReason = "identity_failed";
    }

    // ---- Lane 6: exact port shape: one video_in kVideoFrame input, zero
    //      outputs ----
    {
        ImageOptimizerSinkNode node("optimizer_ports", ImageOptimizerSinkDescriptor{});
        portShapeOk = node.inputPorts().size() == 1 && node.inputPorts()[0].id == "video_in" &&
            node.inputPorts()[0].dataType == PortDataType::kVideoFrame &&
            node.outputPorts().empty();
        if (!portShapeOk && failureReason.empty()) failureReason = "port_shape_failed";
    }

    // ---- Lane 7: default descriptor/accessors ----
    {
        ImageOptimizerSinkNode node("optimizer_default_descriptor", ImageOptimizerSinkDescriptor{});
        defaultDescriptorOk = node.timelineStartPtsUs() == 0 && node.durationUs() == 1 &&
            node.targetWidth() == 1 && node.targetHeight() == 1 && node.qualityPercent() == 90 &&
            node.outputFormat() == ImageOptimizerOutputFormat::kJpeg && node.generateThumbnail() &&
            node.preserveExifOrientation() && node.descriptor().durationUs == 1 &&
            node.descriptor().targetWidth == 1 && node.descriptor().targetHeight == 1 &&
            node.descriptor().qualityPercent == 90 &&
            node.descriptor().outputFormat == ImageOptimizerOutputFormat::kJpeg &&
            node.descriptor().generateThumbnail && node.descriptor().preserveExifOrientation;
        if (!defaultDescriptorOk && failureReason.empty()) failureReason = "default_descriptor_failed";
    }

    // ---- Lane 8: explicit descriptor/accessors for format PNG/HEIC and
    //      booleans ----
    {
        ImageOptimizerSinkDescriptor pngDescriptor;
        pngDescriptor.timelineStartPtsUs = 1000;
        pngDescriptor.durationUs = 5000;
        pngDescriptor.targetWidth = 1280;
        pngDescriptor.targetHeight = 720;
        pngDescriptor.qualityPercent = 75;
        pngDescriptor.outputFormat = ImageOptimizerOutputFormat::kPng;
        pngDescriptor.generateThumbnail = false;
        pngDescriptor.preserveExifOrientation = false;
        ImageOptimizerSinkNode pngNode("optimizer_explicit_png", pngDescriptor);

        const bool pngOk = pngNode.timelineStartPtsUs() == 1000 && pngNode.durationUs() == 5000 &&
            pngNode.targetWidth() == 1280 && pngNode.targetHeight() == 720 &&
            pngNode.qualityPercent() == 75 &&
            pngNode.outputFormat() == ImageOptimizerOutputFormat::kPng &&
            !pngNode.generateThumbnail() && !pngNode.preserveExifOrientation() &&
            pngNode.descriptor().targetWidth == 1280 &&
            pngNode.descriptor().outputFormat == ImageOptimizerOutputFormat::kPng;

        ImageOptimizerSinkDescriptor heicDescriptor;
        heicDescriptor.targetWidth = 640;
        heicDescriptor.targetHeight = 480;
        heicDescriptor.qualityPercent = 50;
        heicDescriptor.outputFormat = ImageOptimizerOutputFormat::kHeic;
        heicDescriptor.generateThumbnail = true;
        heicDescriptor.preserveExifOrientation = true;
        ImageOptimizerSinkNode heicNode("optimizer_explicit_heic", heicDescriptor);

        const bool heicOk = heicNode.targetWidth() == 640 && heicNode.targetHeight() == 480 &&
            heicNode.qualityPercent() == 50 &&
            heicNode.outputFormat() == ImageOptimizerOutputFormat::kHeic &&
            heicNode.generateThumbnail() && heicNode.preserveExifOrientation();

        explicitDescriptorOk = pngOk && heicOk;
        if (!explicitDescriptorOk && failureReason.empty()) failureReason = "explicit_descriptor_failed";
    }

    // ---- Lane 9: node active window [start, start+duration) ----
    {
        constexpr uint64_t kStart = 10000;
        constexpr uint64_t kDuration = 5000;
        constexpr uint64_t kEnd = kStart + kDuration;
        ImageOptimizerSinkDescriptor descriptor;
        descriptor.timelineStartPtsUs = kStart;
        descriptor.durationUs = kDuration;
        ImageOptimizerSinkNode node("optimizer_active_window", descriptor);

        timelineActiveWindowOk = node.timelineStartPtsUs() == kStart && node.durationUs() == kDuration &&
            node.timelineEndPtsUs() == kEnd && !node.isActiveAt(kStart - 1) && node.isActiveAt(kStart) &&
            node.isActiveAt(kStart + kDuration / 2) && node.isActiveAt(kEnd - 1) && !node.isActiveAt(kEnd);
        if (!timelineActiveWindowOk && failureReason.empty()) failureReason = "timeline_active_window_failed";
    }

    // ---- Lane 10: mapTimelineToLocalPts before/inside/after clamps ----
    {
        constexpr uint64_t kStart = 10000;
        constexpr uint64_t kDuration = 5000;
        ImageOptimizerSinkDescriptor descriptor;
        descriptor.timelineStartPtsUs = kStart;
        descriptor.durationUs = kDuration;
        ImageOptimizerSinkNode node("optimizer_mapping", descriptor);

        timelineMappingOk = node.mapTimelineToLocalPts(kStart - 1) == 0 &&
            node.mapTimelineToLocalPts(kStart) == 0 &&
            node.mapTimelineToLocalPts(kStart + 1234) == 1234 &&
            node.mapTimelineToLocalPts(kStart + kDuration) == kDuration &&
            node.mapTimelineToLocalPts(kStart + kDuration + 999) == kDuration;
        if (!timelineMappingOk && failureReason.empty()) failureReason = "timeline_mapping_failed";
    }

    // ---- Lane 11: blendWeightAt active/inactive semantics ----
    {
        constexpr uint64_t kStart = 2000;
        constexpr uint64_t kDuration = 3000;
        ImageOptimizerSinkDescriptor descriptor;
        descriptor.timelineStartPtsUs = kStart;
        descriptor.durationUs = kDuration;
        ImageOptimizerSinkNode node("optimizer_blend", descriptor);

        blendWeightsOk = node.blendWeightAt(kStart - 1) == 0.0f &&
            node.blendWeightAt(kStart + kDuration) == 0.0f && node.blendWeightAt(kStart) == 1.0f &&
            node.blendWeightAt(kStart + kDuration - 1) == 1.0f;
        if (!blendWeightsOk && failureReason.empty()) failureReason = "blend_weights_failed";
    }

    // ---- Lane 12: overflow-safe timelineEndPtsUs() saturation to
    //      UINT64_MAX plus clamp behavior at/after the saturated end ----
    {
        constexpr uint64_t kMaxU64 = std::numeric_limits<uint64_t>::max();
        constexpr uint64_t kStart = kMaxU64 - 10;
        constexpr uint64_t kDuration = 1000; // start + duration overflows uint64_t
        ImageOptimizerSinkDescriptor descriptor;
        descriptor.timelineStartPtsUs = kStart;
        descriptor.durationUs = kDuration;
        ImageOptimizerSinkNode node("optimizer_overflow", descriptor);

        overflowClampOk = node.timelineEndPtsUs() == kMaxU64 && node.isActiveAt(kStart) &&
            node.isActiveAt(kMaxU64 - 1) && !node.isActiveAt(kMaxU64) &&
            node.mapTimelineToLocalPts(kMaxU64) == kDuration;
        if (!overflowClampOk && failureReason.empty()) failureReason = "overflow_clamp_failed";
    }

    // ---- Lane 13: real BuildGraphExecutionPlan pass from a real
    //      ImageTextureSourceNode to a real ImageOptimizerSinkNode,
    //      verifying dependency order and the video_in<-kVideoFrame
    //      binding ----
    {
        Graph g;
        auto source = std::make_shared<ImageTextureSourceNode>(
            "optimizer_plan_source", "img_plan_source", 0, 5000, 1920, 1080, 0);
        auto sink = std::make_shared<ImageOptimizerSinkNode>(
            "optimizer_plan_sink", ImageOptimizerSinkDescriptor{});

        const bool added = g.addNode(source).ok() && g.addNode(sink).ok();
        const bool wired = added &&
            g.connect("optimizer_plan_source", "kVideoFrame", "optimizer_plan_sink", "video_in").ok();

        FrameRequest req;
        req.generationId = g.generationId();
        req.timelinePtsUs = 0;

        GraphExecutionPlan plan;
        const auto status = BuildGraphExecutionPlan(g, req, plan);

        const auto* sinkNode = PlanFind(plan, "optimizer_plan_sink");

        executionPlanOk = wired && status.ok() && plan.nodes.size() == 2 &&
            PlanIndexOf(plan, "optimizer_plan_source") < PlanIndexOf(plan, "optimizer_plan_sink") &&
            plan.sinkNodeIds.size() == 1 && plan.sinkNodeIds[0] == "optimizer_plan_sink" &&
            sinkNode != nullptr && sinkNode->inputs.size() == 1 &&
            sinkNode->inputs[0].inputPortId == "video_in" &&
            sinkNode->inputs[0].fromNodeId == "optimizer_plan_source" &&
            sinkNode->inputs[0].fromPortId == "kVideoFrame" &&
            sinkNode->inputs[0].dataType == PortDataType::kVideoFrame;

        if (!executionPlanOk && failureReason.empty()) failureReason = "execution_plan_failed";
    }

    // ---- Lane 14: an active ImageOptimizerSinkNode with its required
    //      "video_in" input left unwired fails BuildGraphExecutionPlan
    //      closed (fails required-input validation, not silently dropped) ----
    {
        Graph g;
        auto sink = std::make_shared<ImageOptimizerSinkNode>(
            "optimizer_missing_input_sink", ImageOptimizerSinkDescriptor{});
        const bool added = g.addNode(sink).ok();

        FrameRequest req;
        req.generationId = g.generationId();
        req.timelinePtsUs = 0;

        GraphExecutionPlan plan;
        const auto status = BuildGraphExecutionPlan(g, req, plan);

        missingInputFailClosedOk = added && !status.ok() && plan.nodes.empty() &&
            status.message().find("video_in") != std::string::npos;

        if (!missingInputFailClosedOk && failureReason.empty()) {
            failureReason = "missing_input_fail_closed_failed";
        }
    }

    // ---- Lane 15: proof boundary lane ----
    {
        const std::string boundary(kProofBoundary);
        proofBoundaryLaneOk = boundary.find("platform_neutral") != std::string::npos &&
            boundary.find("image_optimizer_sink_node") != std::string::npos &&
            boundary.find("logical_dag_sink") != std::string::npos &&
            boundary.find("no_decode") != std::string::npos &&
            boundary.find("no_downscale") != std::string::npos &&
            boundary.find("no_encode") != std::string::npos &&
            boundary.find("no_file_io") != std::string::npos &&
            boundary.find("no_gpu_lifecycle") != std::string::npos &&
            boundary.find("no_product_app_editor_wiring") != std::string::npos;

        if (!proofBoundaryLaneOk && failureReason.empty()) failureReason = "proof_boundary_lane_failed";
    }

    constexpr int kTotalLanes = 15;
    const int passedLanes = (emptyIdRejectedOk ? 1 : 0) + (zeroDurationRejectedOk ? 1 : 0) +
        (invalidDimensionsRejectedOk ? 1 : 0) + (invalidQualityRejectedOk ? 1 : 0) +
        (identityOk ? 1 : 0) + (portShapeOk ? 1 : 0) + (defaultDescriptorOk ? 1 : 0) +
        (explicitDescriptorOk ? 1 : 0) + (timelineActiveWindowOk ? 1 : 0) +
        (timelineMappingOk ? 1 : 0) + (blendWeightsOk ? 1 : 0) + (overflowClampOk ? 1 : 0) +
        (executionPlanOk ? 1 : 0) + (missingInputFailClosedOk ? 1 : 0) + (proofBoundaryLaneOk ? 1 : 0);
    const bool allPass = passedLanes == kTotalLanes;

    std::ostringstream oss;
    oss << "status=" << (allPass ? "PASS" : "FAIL") << ";"
        << "totalLanes=" << kTotalLanes << ";"
        << "passedLanes=" << passedLanes << ";"
        << "proofBoundary=" << kProofBoundary << ";"
        << "lanes=emptyIdRejected:" << (emptyIdRejectedOk ? "true" : "false")
        << ",zeroDurationRejected:" << (zeroDurationRejectedOk ? "true" : "false")
        << ",invalidDimensionsRejected:" << (invalidDimensionsRejectedOk ? "true" : "false")
        << ",invalidQualityRejected:" << (invalidQualityRejectedOk ? "true" : "false")
        << ",identity:" << (identityOk ? "true" : "false")
        << ",portShape:" << (portShapeOk ? "true" : "false")
        << ",defaultDescriptor:" << (defaultDescriptorOk ? "true" : "false")
        << ",explicitDescriptor:" << (explicitDescriptorOk ? "true" : "false")
        << ",timelineActiveWindow:" << (timelineActiveWindowOk ? "true" : "false")
        << ",timelineMapping:" << (timelineMappingOk ? "true" : "false")
        << ",blendWeights:" << (blendWeightsOk ? "true" : "false")
        << ",overflowClamp:" << (overflowClampOk ? "true" : "false")
        << ",executionPlan:" << (executionPlanOk ? "true" : "false")
        << ",missingInputFailClosed:" << (missingInputFailClosedOk ? "true" : "false")
        << ",proofBoundaryLane:" << (proofBoundaryLaneOk ? "true" : "false") << ";"
        << "reason=" << (allPass ? "none" : failureReason);
    return oss.str();
}

} // namespace

extern "C" JNIEXPORT jstring JNICALL
Java_com_connects_vanguard_1media_1engine_bridge_VanguardNativeBridge_runAndroidDagPhase5ImageOptimizerSinkNodeSmoke(
    JNIEnv* env,
    jobject /* this */) {
    try {
        const std::string resultStr = RunImageOptimizerSinkNodeSmokeInternal();
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
