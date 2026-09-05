// P1-DAG-MULTINODE-GPU-FRAME-TOKEN-CONTRACT: platform-neutral, non-owning GPU
// frame token contract diagnostic proof.
//
// Diagnostic-only: proves vanguard::graph::GpuFrameToken/GpuFrameTokenSession
// can publish and resolve real GPU frame identity/binding tokens over a real
// multi-node topology built entirely from concrete, platform-neutral
// production node classes - two vanguard::sources::HardwareBufferSourceNode
// instances feeding a vanguard::compositors::MultiCamCompositorNode's
// "primary_video_in"/"secondary_video_in" ports, whose
// "composited_video_out" output feeds a
// vanguard::sinks::PreviewSurfaceSinkNode's "video_in" port, planned via
// vanguard::graph::BuildGraphExecutionPlan(). No TU-local Node subclasses are
// used anywhere in this file. GpuFrameToken/GpuFrameTokenSession own no OS/
// GPU resource - this slice only proves data-plane identity/binding, not
// rendering or GPU/pixel transport.
//
// Non-claims: no rendering, no GPU/pixel/handle transport, no OS resource
// ownership, no product/editor/app/ConnectsApp wiring.
//
// This translation unit is Android-only and must NOT be included in iOS or
// host builds. It is added via the Android-only target_sources block in
// src/CMakeLists.txt.
//
// Lane list (exactly 10):
//   1.  tokenValueContract        - GpuFrameToken/GpuFrameTokenSession value
//                                    round-trip (publish then resolve
//                                    preserves every field) plus
//                                    IsValidGpuFrameToken() true/false shape.
//   2.  descriptorValidation      - IsValidGpuFrameDescriptor() rejects
//                                    zero width/height/layers and accepts a
//                                    valid descriptor; publish() fails
//                                    closed on an invalid descriptor.
//   3.  fourNodePlanResolved      - BuildGraphExecutionPlan() passes over a
//                                    real four-node topology (2 sources ->
//                                    compositor -> sink).
//   4.  sourceTokensPublished     - both source output tokens publish
//                                    cleanly into a session scoped to the
//                                    plan's evaluatedPtsUs/evaluatedGeneration.
//   5.  compositorInputsResolved  - the compositor's primary/secondary plan
//                                    input bindings resolve to the correct
//                                    published source tokens.
//   6.  compositorOutputPublished - the compositor's own output token
//                                    publishes cleanly after its inputs
//                                    resolve.
//   7.  sinkInputResolved         - the sink's plan input binding resolves
//                                    to the published compositor output
//                                    token.
//   8.  duplicatePublishRejected  - re-publishing the same producing
//                                    node/output-port key fails closed and
//                                    does not change the published count.
//   9.  staleGenerationRejected   - publishing a token whose
//                                    evaluatedGeneration does not match the
//                                    session fails closed and does not
//                                    change the published count.
//   10. noOsResourceBoundary      - handle is a plain opaque integral value
//                                    (not a pointer), and a resolved token
//                                    copy remains valid/unchanged after the
//                                    publishing session is destroyed,
//                                    proving non-owning value semantics with
//                                    no explicit release/close/dup call.
//
// JNI entry point:
//   runAndroidDagPhase1DagMultinodeGpuFrameTokenSmoke -> jstring

#include <jni.h>

#include <cstdint>
#include <exception>
#include <memory>
#include <sstream>
#include <string>
#include <type_traits>
#include <vector>

#include "vanguard/compositors/multi_cam_compositor_node.h"
#include "vanguard/graph/frame_request.h"
#include "vanguard/graph/graph.h"
#include "vanguard/graph/graph_execution_plan.h"
#include "vanguard/graph/gpu_frame_token.h"
#include "vanguard/graph/node.h"
#include "vanguard/render/hardware_buffer_import.h"
#include "vanguard/sinks/preview_surface_sink_node.h"
#include "vanguard/sources/hardware_buffer_source_node.h"

namespace {

using vanguard::core::Status;
using vanguard::core::StatusCode;
using vanguard::graph::BuildGraphExecutionPlan;
using vanguard::graph::ExecutionInputBinding;
using vanguard::graph::ExecutionPlanNode;
using vanguard::graph::FrameRequest;
using vanguard::graph::Graph;
using vanguard::graph::GraphExecutionPlan;
using vanguard::graph::GpuFrameDescriptor;
using vanguard::graph::GpuFrameToken;
using vanguard::graph::GpuFrameTokenSession;
using vanguard::graph::IsValidGpuFrameDescriptor;
using vanguard::graph::IsValidGpuFrameToken;
using vanguard::compositors::MultiCamCompositorNode;
using vanguard::sinks::PreviewSurfaceSinkNode;
using vanguard::sources::HardwareBufferSourceNode;

constexpr const char* kProofBoundary =
    "platform_neutral_gpu_frame_token_binding_contract_diagnostic_only_no_os_resource_"
    "ownership_no_render_no_gpu_transport_no_product_app_editor_wiring";

const ExecutionPlanNode* PlanFind(const GraphExecutionPlan& plan, const std::string& nodeId) {
    for (const auto& n : plan.nodes) {
        if (n.nodeId == nodeId) return &n;
    }
    return nullptr;
}

const ExecutionInputBinding* FindBinding(const ExecutionPlanNode& node,
                                         const std::string& inputPortId) {
    for (const auto& in : node.inputs) {
        if (in.inputPortId == inputPortId) return &in;
    }
    return nullptr;
}

std::string RunGpuFrameTokenSmokeInternal() {
    bool tokenValueContractOk = false;
    bool descriptorValidationOk = false;
    bool fourNodePlanResolvedOk = false;
    bool sourceTokensPublishedOk = false;
    bool compositorInputsResolvedOk = false;
    bool compositorOutputPublishedOk = false;
    bool sinkInputResolvedOk = false;
    bool duplicatePublishRejectedOk = false;
    bool staleGenerationRejectedOk = false;
    bool noOsResourceBoundaryOk = false;
    std::string failureReason;

    // ---- Lane 1: GpuFrameToken/GpuFrameTokenSession value round-trip ----
    {
        GpuFrameTokenSession session(1234, 5);

        GpuFrameToken token;
        token.handle = 77;
        token.descriptor = GpuFrameDescriptor{1920, 1080, 1, 1, 1920, 0};
        token.producingNodeId = "contract_producer";
        token.outputPortId = "contract_out";
        token.evaluatedPtsUs = 1234;
        token.evaluatedGeneration = 5;
        token.hasAcquireFence = true;
        token.hasReleaseFence = false;

        const bool validBefore = IsValidGpuFrameToken(token);
        const auto publishStatus = session.publish(token);

        ExecutionInputBinding binding;
        binding.inputPortId = "contract_in";
        binding.fromNodeId = "contract_producer";
        binding.fromPortId = "contract_out";

        GpuFrameToken resolved;
        const auto resolveStatus = session.resolve(binding, resolved);

        GpuFrameToken invalidToken;
        invalidToken.handle = vanguard::render::kInvalidHardwareBufferHandle;
        const bool invalidRejected = !IsValidGpuFrameToken(invalidToken);

        tokenValueContractOk = validBefore && publishStatus.ok() && resolveStatus.ok() &&
            invalidRejected &&
            resolved.handle == token.handle &&
            resolved.descriptor.width == token.descriptor.width &&
            resolved.descriptor.height == token.descriptor.height &&
            resolved.descriptor.layers == token.descriptor.layers &&
            resolved.descriptor.format == token.descriptor.format &&
            resolved.descriptor.stride == token.descriptor.stride &&
            resolved.descriptor.usage == token.descriptor.usage &&
            resolved.producingNodeId == token.producingNodeId &&
            resolved.outputPortId == token.outputPortId &&
            resolved.evaluatedPtsUs == token.evaluatedPtsUs &&
            resolved.evaluatedGeneration == token.evaluatedGeneration &&
            resolved.hasAcquireFence == token.hasAcquireFence &&
            resolved.hasReleaseFence == token.hasReleaseFence;

        if (!tokenValueContractOk && failureReason.empty()) failureReason = "token_value_contract_failed";
    }

    // ---- Lane 2: descriptor validation ----
    {
        const GpuFrameDescriptor zeroWidth{0, 1080, 1, 1, 0, 0};
        const GpuFrameDescriptor zeroHeight{1920, 0, 1, 1, 0, 0};
        const GpuFrameDescriptor zeroLayers{1920, 1080, 0, 1, 0, 0};
        const GpuFrameDescriptor valid{1920, 1080, 1, 1, 1920, 0};

        GpuFrameTokenSession session(10, 1);
        GpuFrameToken badToken;
        badToken.handle = 55;
        badToken.descriptor = zeroWidth;
        badToken.producingNodeId = "descriptor_producer";
        badToken.outputPortId = "descriptor_out";
        badToken.evaluatedPtsUs = 10;
        badToken.evaluatedGeneration = 1;
        const auto publishStatus = session.publish(badToken);

        descriptorValidationOk =
            !IsValidGpuFrameDescriptor(zeroWidth) &&
            !IsValidGpuFrameDescriptor(zeroHeight) &&
            !IsValidGpuFrameDescriptor(zeroLayers) &&
            IsValidGpuFrameDescriptor(valid) &&
            !publishStatus.ok() &&
            publishStatus.message().find("descriptor") != std::string::npos &&
            session.publishedCount() == 0;

        if (!descriptorValidationOk && failureReason.empty()) failureReason = "descriptor_validation_failed";
    }

    // ---- Lanes 3-9: shared real four-node topology (2 sources ->
    //      compositor -> sink) and one GpuFrameTokenSession scoped to its
    //      resolved plan ----
    GraphExecutionPlan plan;
    {
        Graph g;
        auto primary = std::make_shared<HardwareBufferSourceNode>("gft_primary_source", 0, 5000);
        auto secondary = std::make_shared<HardwareBufferSourceNode>("gft_secondary_source", 0, 5000);
        auto compositor = std::make_shared<MultiCamCompositorNode>("gft_compositor");
        auto sink = std::make_shared<PreviewSurfaceSinkNode>("gft_sink");

        const bool added =
            g.addNode(primary).ok() && g.addNode(secondary).ok() &&
            g.addNode(compositor).ok() && g.addNode(sink).ok();

        const bool wired = added &&
            g.connect("gft_primary_source", "kVideoFrame", "gft_compositor", "primary_video_in").ok() &&
            g.connect("gft_secondary_source", "kVideoFrame", "gft_compositor", "secondary_video_in").ok() &&
            g.connect("gft_compositor", "composited_video_out", "gft_sink", "video_in").ok();

        FrameRequest req;
        req.generationId = g.generationId();
        req.timelinePtsUs = 0;

        const auto status = BuildGraphExecutionPlan(g, req, plan);

        fourNodePlanResolvedOk = wired && status.ok() && plan.nodes.size() == 4;
        if (!fourNodePlanResolvedOk && failureReason.empty()) failureReason = "four_node_plan_resolved_failed";
    }

    GpuFrameTokenSession session(plan.evaluatedPtsUs, plan.evaluatedGeneration);

    // ---- Lane 4: both source tokens publish cleanly ----
    if (fourNodePlanResolvedOk) {
        GpuFrameToken primaryToken;
        primaryToken.handle = 101;
        primaryToken.descriptor = GpuFrameDescriptor{1920, 1080, 1, 1, 1920, 0};
        primaryToken.producingNodeId = "gft_primary_source";
        primaryToken.outputPortId = "kVideoFrame";
        primaryToken.evaluatedPtsUs = plan.evaluatedPtsUs;
        primaryToken.evaluatedGeneration = plan.evaluatedGeneration;
        primaryToken.hasAcquireFence = true;
        primaryToken.hasReleaseFence = false;

        GpuFrameToken secondaryToken;
        secondaryToken.handle = 102;
        secondaryToken.descriptor = GpuFrameDescriptor{1280, 720, 1, 1, 1280, 0};
        secondaryToken.producingNodeId = "gft_secondary_source";
        secondaryToken.outputPortId = "kVideoFrame";
        secondaryToken.evaluatedPtsUs = plan.evaluatedPtsUs;
        secondaryToken.evaluatedGeneration = plan.evaluatedGeneration;
        secondaryToken.hasAcquireFence = true;
        secondaryToken.hasReleaseFence = false;

        const auto primaryStatus = session.publish(primaryToken);
        const auto secondaryStatus = session.publish(secondaryToken);

        sourceTokensPublishedOk =
            primaryStatus.ok() && secondaryStatus.ok() && session.publishedCount() == 2;
        if (!sourceTokensPublishedOk && failureReason.empty()) failureReason = "source_tokens_published_failed";
    } else if (failureReason.empty()) {
        failureReason = "source_tokens_published_skipped_prereq";
    }

    // ---- Lane 5: compositor input bindings resolve to the correct
    //      published source tokens ----
    if (sourceTokensPublishedOk) {
        const auto* compositorPlanNode = PlanFind(plan, "gft_compositor");
        const auto* primaryBinding =
            compositorPlanNode ? FindBinding(*compositorPlanNode, "primary_video_in") : nullptr;
        const auto* secondaryBinding =
            compositorPlanNode ? FindBinding(*compositorPlanNode, "secondary_video_in") : nullptr;

        GpuFrameToken resolvedPrimary;
        GpuFrameToken resolvedSecondary;
        const auto primaryResolveStatus =
            primaryBinding ? session.resolve(*primaryBinding, resolvedPrimary)
                            : Status(StatusCode::kError, "primary_binding_missing");
        const auto secondaryResolveStatus =
            secondaryBinding ? session.resolve(*secondaryBinding, resolvedSecondary)
                              : Status(StatusCode::kError, "secondary_binding_missing");

        compositorInputsResolvedOk =
            primaryResolveStatus.ok() && secondaryResolveStatus.ok() &&
            resolvedPrimary.handle == 101 && resolvedPrimary.producingNodeId == "gft_primary_source" &&
            resolvedSecondary.handle == 102 && resolvedSecondary.producingNodeId == "gft_secondary_source";
        if (!compositorInputsResolvedOk && failureReason.empty()) {
            failureReason = "compositor_inputs_resolved_failed";
        }
    } else if (failureReason.empty()) {
        failureReason = "compositor_inputs_resolved_skipped_prereq";
    }

    // ---- Lane 6: compositor output token publishes cleanly ----
    if (compositorInputsResolvedOk) {
        GpuFrameToken compositedToken;
        compositedToken.handle = 201;
        compositedToken.descriptor = GpuFrameDescriptor{1920, 1080, 1, 1, 1920, 0};
        compositedToken.producingNodeId = "gft_compositor";
        compositedToken.outputPortId = "composited_video_out";
        compositedToken.evaluatedPtsUs = plan.evaluatedPtsUs;
        compositedToken.evaluatedGeneration = plan.evaluatedGeneration;
        compositedToken.hasAcquireFence = true;
        compositedToken.hasReleaseFence = true;

        const auto publishStatus = session.publish(compositedToken);
        compositorOutputPublishedOk = publishStatus.ok() && session.publishedCount() == 3;
        if (!compositorOutputPublishedOk && failureReason.empty()) {
            failureReason = "compositor_output_published_failed";
        }
    } else if (failureReason.empty()) {
        failureReason = "compositor_output_published_skipped_prereq";
    }

    // ---- Lane 7: sink input binding resolves to the published compositor
    //      output token ----
    if (compositorOutputPublishedOk) {
        const auto* sinkPlanNode = PlanFind(plan, "gft_sink");
        const auto* sinkBinding = sinkPlanNode ? FindBinding(*sinkPlanNode, "video_in") : nullptr;

        GpuFrameToken resolvedSinkInput;
        const auto resolveStatus =
            sinkBinding ? session.resolve(*sinkBinding, resolvedSinkInput)
                        : Status(StatusCode::kError, "sink_binding_missing");

        sinkInputResolvedOk = resolveStatus.ok() && resolvedSinkInput.handle == 201 &&
            resolvedSinkInput.producingNodeId == "gft_compositor" &&
            resolvedSinkInput.outputPortId == "composited_video_out";
        if (!sinkInputResolvedOk && failureReason.empty()) failureReason = "sink_input_resolved_failed";
    } else if (failureReason.empty()) {
        failureReason = "sink_input_resolved_skipped_prereq";
    }

    // ---- Lane 8: duplicate publish for an already-published key fails
    //      closed and does not change the published count ----
    if (sinkInputResolvedOk) {
        const size_t countBefore = session.publishedCount();

        GpuFrameToken duplicatePrimaryToken;
        duplicatePrimaryToken.handle = 999;
        duplicatePrimaryToken.descriptor = GpuFrameDescriptor{1920, 1080, 1, 1, 1920, 0};
        duplicatePrimaryToken.producingNodeId = "gft_primary_source";
        duplicatePrimaryToken.outputPortId = "kVideoFrame";
        duplicatePrimaryToken.evaluatedPtsUs = plan.evaluatedPtsUs;
        duplicatePrimaryToken.evaluatedGeneration = plan.evaluatedGeneration;

        const auto duplicateStatus = session.publish(duplicatePrimaryToken);

        duplicatePublishRejectedOk = !duplicateStatus.ok() &&
            duplicateStatus.message().find("duplicate") != std::string::npos &&
            session.publishedCount() == countBefore;
        if (!duplicatePublishRejectedOk && failureReason.empty()) {
            failureReason = "duplicate_publish_rejected_failed";
        }
    } else if (failureReason.empty()) {
        failureReason = "duplicate_publish_rejected_skipped_prereq";
    }

    // ---- Lane 9: a token whose evaluatedGeneration does not match this
    //      session fails closed and does not change the published count ----
    if (duplicatePublishRejectedOk) {
        const size_t countBefore = session.publishedCount();

        GpuFrameToken staleToken;
        staleToken.handle = 555;
        staleToken.descriptor = GpuFrameDescriptor{1920, 1080, 1, 1, 1920, 0};
        staleToken.producingNodeId = "gft_compositor";
        staleToken.outputPortId = "stale_test_out";
        staleToken.evaluatedPtsUs = plan.evaluatedPtsUs;
        staleToken.evaluatedGeneration = plan.evaluatedGeneration + 1; // deliberately stale

        const auto staleStatus = session.publish(staleToken);

        staleGenerationRejectedOk = !staleStatus.ok() &&
            staleStatus.message().find("stale") != std::string::npos &&
            session.publishedCount() == countBefore;
        if (!staleGenerationRejectedOk && failureReason.empty()) {
            failureReason = "stale_generation_rejected_failed";
        }
    } else if (failureReason.empty()) {
        failureReason = "stale_generation_rejected_skipped_prereq";
    }

    // ---- Lane 10: handle is a plain opaque integral value (not a
    //      pointer), and a resolved token copy remains valid after the
    //      publishing session is destroyed - proving non-owning value
    //      semantics with no explicit release/close/dup call anywhere in
    //      this API ----
    {
        static_assert(std::is_integral<vanguard::render::HardwareBufferHandle>::value,
                      "GpuFrameToken::handle must be a plain opaque backend-owned integral "
                      "value, never a pointer");

        GpuFrameToken copiedToken;
        bool innerPublishOk = false;
        bool innerResolveOk = false;
        {
            GpuFrameTokenSession scoped(4242, 7);
            GpuFrameToken scopedToken;
            scopedToken.handle = 99;
            scopedToken.descriptor = GpuFrameDescriptor{640, 480, 1, 1, 640, 0};
            scopedToken.producingNodeId = "scoped_node";
            scopedToken.outputPortId = "scoped_port";
            scopedToken.evaluatedPtsUs = 4242;
            scopedToken.evaluatedGeneration = 7;
            scopedToken.hasAcquireFence = true;
            scopedToken.hasReleaseFence = false;

            innerPublishOk = scoped.publish(scopedToken).ok();

            ExecutionInputBinding binding;
            binding.inputPortId = "scoped_consumer_in";
            binding.fromNodeId = "scoped_node";
            binding.fromPortId = "scoped_port";
            innerResolveOk = scoped.resolve(binding, copiedToken).ok();
        } // `scoped` is destroyed here; this API exposes no release/close/dup call.

        noOsResourceBoundaryOk = innerPublishOk && innerResolveOk &&
            copiedToken.handle == 99 &&
            copiedToken.producingNodeId == "scoped_node" &&
            copiedToken.outputPortId == "scoped_port" &&
            copiedToken.evaluatedPtsUs == 4242 &&
            copiedToken.evaluatedGeneration == 7 &&
            copiedToken.hasAcquireFence == true &&
            copiedToken.hasReleaseFence == false;

        if (!noOsResourceBoundaryOk && failureReason.empty()) failureReason = "no_os_resource_boundary_failed";
    }

    constexpr int kTotalLanes = 10;
    const int passedLanes =
        (tokenValueContractOk ? 1 : 0) + (descriptorValidationOk ? 1 : 0) +
        (fourNodePlanResolvedOk ? 1 : 0) + (sourceTokensPublishedOk ? 1 : 0) +
        (compositorInputsResolvedOk ? 1 : 0) + (compositorOutputPublishedOk ? 1 : 0) +
        (sinkInputResolvedOk ? 1 : 0) + (duplicatePublishRejectedOk ? 1 : 0) +
        (staleGenerationRejectedOk ? 1 : 0) + (noOsResourceBoundaryOk ? 1 : 0);
    const bool allPass = passedLanes == kTotalLanes;

    std::ostringstream oss;
    oss << "status=" << (allPass ? "PASS" : "FAIL") << ";"
        << "totalLanes=" << kTotalLanes << ";"
        << "passedLanes=" << passedLanes << ";"
        << "proofBoundary=" << kProofBoundary << ";"
        << "lanes=tokenValueContract:" << (tokenValueContractOk ? "true" : "false")
        << ",descriptorValidation:" << (descriptorValidationOk ? "true" : "false")
        << ",fourNodePlanResolved:" << (fourNodePlanResolvedOk ? "true" : "false")
        << ",sourceTokensPublished:" << (sourceTokensPublishedOk ? "true" : "false")
        << ",compositorInputsResolved:" << (compositorInputsResolvedOk ? "true" : "false")
        << ",compositorOutputPublished:" << (compositorOutputPublishedOk ? "true" : "false")
        << ",sinkInputResolved:" << (sinkInputResolvedOk ? "true" : "false")
        << ",duplicatePublishRejected:" << (duplicatePublishRejectedOk ? "true" : "false")
        << ",staleGenerationRejected:" << (staleGenerationRejectedOk ? "true" : "false")
        << ",noOsResourceBoundary:" << (noOsResourceBoundaryOk ? "true" : "false") << ";"
        << "reason=" << (allPass ? "none" : failureReason);
    return oss.str();
}

} // namespace

extern "C" JNIEXPORT jstring JNICALL
Java_com_connects_vanguard_1media_1engine_bridge_VanguardNativeBridge_runAndroidDagPhase1DagMultinodeGpuFrameTokenSmoke(
    JNIEnv* env,
    jobject /* this */) {
    try {
        const std::string resultStr = RunGpuFrameTokenSmokeInternal();
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
