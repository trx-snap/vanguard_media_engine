// Phase 4B1A: MediaCodec decode → ImageReader → HardwareBuffer → native DAG
// evaluation → Vulkan render to Flutter TextureRegistry Surface.
//
// This translation unit is Android-only and must NOT be included in iOS or
// host builds. It is added via the Android-only target_sources block in
// src/CMakeLists.txt.
//
// JNI entry points (matching VanguardNativeBridge.kt Phase 4B1A declarations):
//   createAndroidDagPhase4B1TexturePlaybackSession  -> jstring
//   renderAndroidDagPhase4B1TexturePlaybackFrame    -> jstring
//   destroyAndroidDagPhase4B1TexturePlaybackSession -> jstring

#include <jni.h>

#include <android/hardware_buffer.h>
#include <android/native_window_jni.h>
#include <dlfcn.h>
#include <unistd.h>

#include <atomic>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <functional>
#include <memory>
#include <mutex>
#include <string>
#include <unordered_map>

#include "vanguard/core/logging.h"
#include "vanguard/core/status.h"
#include "vanguard/graph/frame_request.h"
#include "vanguard/graph/graph.h"
#include "vanguard/graph/graph_execution_dispatcher.h"
#include "vanguard/graph/graph_execution_plan.h"
#include "vanguard/graph/gpu_frame_token.h"
#include "vanguard/render/vulkan_backend.h"
#include "vanguard/render/render_transform.h"
#include "vanguard/sinks/preview_surface_sink_node.h"
#include "vanguard/sources/hardware_buffer_source_node.h"

// ---------------------------------------------------------------------------
// AHardwareBuffer_fromHardwareBuffer dynamic lookup
// ---------------------------------------------------------------------------
namespace {

using FnAHardwareBuffer_fromHardwareBuffer =
    AHardwareBuffer* (*)(JNIEnv*, jobject);

AHardwareBuffer* ResolveAHardwareBufferFromJObject(JNIEnv* env, jobject jHwBuf) {
    void* lib = dlopen("libandroid.so", RTLD_NOW | RTLD_LOCAL);
    if (!lib) return nullptr;
    auto fn = reinterpret_cast<FnAHardwareBuffer_fromHardwareBuffer>(
        dlsym(lib, "AHardwareBuffer_fromHardwareBuffer"));
    AHardwareBuffer* buf = nullptr;
    if (fn && jHwBuf) {
        buf = fn(env, jHwBuf);
    }
    dlclose(lib);
    return buf;
}

// ---------------------------------------------------------------------------
// Phase 4B1 dispatcher wiring: node ids/ports and shared callback plumbing
// ---------------------------------------------------------------------------

constexpr const char* kDiag4B1HwSrcNodeId      = "diag4b1_hw_src";
constexpr const char* kDiag4B1PreviewSinkNodeId = "diag4b1_preview_sink";
constexpr const char* kDiag4B1VideoOutputPort   = "kVideoFrame";

// Converts an imported HardwareBufferDescriptor into a GpuFrameDescriptor.
// The two structs mirror each other field-for-field by design (see
// vanguard/graph/gpu_frame_token.h); there is no shared conversion helper
// because gpu_frame_token.h must stay free of any backend-owning include.
vanguard::graph::GpuFrameDescriptor ToGpuFrameDescriptor(
    const vanguard::render::HardwareBufferDescriptor& hwDesc) {
    vanguard::graph::GpuFrameDescriptor desc;
    desc.width  = hwDesc.width;
    desc.height = hwDesc.height;
    desc.layers = hwDesc.layers;
    desc.format = hwDesc.format;
    desc.stride = hwDesc.stride;
    desc.usage  = hwDesc.usage;
    return desc;
}

// Builds the per-frame dispatcher callback for the two-node diagnostic
// graph: the source node publishes exactly one GpuFrameToken derived from
// the already-imported hardware buffer handle/descriptor; the sink node
// resolves that one token and invokes the caller-supplied render function.
// Any node id outside this fixed pair fails closed.
vanguard::graph::GraphExecutionNodeCallback MakePhase4B1DispatchCallback(
    vanguard::render::HardwareBufferHandle handle,
    const vanguard::render::HardwareBufferDescriptor& hwDescriptor,
    const vanguard::graph::GraphExecutionPlan& plan,
    std::function<vanguard::render::RenderFrameResult(
        vanguard::render::HardwareBufferHandle)> renderFn,
    vanguard::render::RenderFrameResult* outRenderResult) {
    return [handle, hwDescriptor, &plan, renderFn, outRenderResult](
               const vanguard::graph::ExecutionPlanNode& node,
               const std::vector<vanguard::graph::ResolvedGpuFrameInput>& resolvedInputs,
               std::vector<vanguard::graph::GpuFrameToken>& outOutputs)
               -> vanguard::core::Status {
        if (node.nodeId == kDiag4B1HwSrcNodeId) {
            vanguard::graph::GpuFrameToken token;
            token.handle              = handle;
            token.descriptor          = ToGpuFrameDescriptor(hwDescriptor);
            token.producingNodeId     = node.nodeId;
            token.outputPortId        = kDiag4B1VideoOutputPort;
            token.evaluatedPtsUs      = plan.evaluatedPtsUs;
            token.evaluatedGeneration = plan.evaluatedGeneration;
            token.hasAcquireFence     = false;
            token.hasReleaseFence     = false;
            outOutputs.push_back(token);
            return vanguard::core::Status::OK();
        }
        if (node.nodeId == kDiag4B1PreviewSinkNodeId) {
            if (resolvedInputs.size() != 1 ||
                resolvedInputs[0].binding.fromNodeId != kDiag4B1HwSrcNodeId) {
                return vanguard::core::Status(
                    vanguard::core::StatusCode::kError,
                    "diag4b1_preview_sink_unresolved_or_unexpected_input");
            }
            *outRenderResult = renderFn(resolvedInputs[0].token.handle);
            return vanguard::core::Status::OK();
        }
        return vanguard::core::Status(
            vanguard::core::StatusCode::kError,
            "unexpected_node_" + node.nodeId);
    };
}

// ---------------------------------------------------------------------------
// Phase 4B1 session structure
// ---------------------------------------------------------------------------

struct Phase4B1Session {
    ANativeWindow*                       nativeWindow{nullptr};
    vanguard::render::VulkanBackend      backend;
    vanguard::graph::Graph               graph;
    uint64_t                             graphGenerationId{0};
    bool                                 initialized{false};
    bool                                 surfaceAttached{false};
    bool                                 graphBuilt{false};
    int32_t                              width{0};
    int32_t                              height{0};
    int                                  renderedFrames{0};
    std::string                          lastRenderStatus;
    std::string                          sessionId;
};

// ---------------------------------------------------------------------------
// Session registry (guarded by mutex)
// ---------------------------------------------------------------------------

std::mutex                                        gPhase4B1SessionMutex;
std::unordered_map<std::string, Phase4B1Session*> gPhase4B1Sessions;
std::atomic<uint64_t>                             gNextPhase4B1SessionId{1};

const char* HwBufResultName(vanguard::render::HardwareBufferImportResult r) {
    using R = vanguard::render::HardwareBufferImportResult;
    switch (r) {
        case R::kSuccess:                     return "success";
        case R::kUnavailable:                 return "unavailable";
        case R::kBackendNotInitialized:       return "backend_not_initialized";
        case R::kInvalidArgument:             return "invalid_argument";
        case R::kDuplicateImport:             return "duplicate_import";
        case R::kIncompatibleBuffer:          return "incompatible_buffer";
        case R::kVulkanFunctionUnavailable:   return "vulkan_function_unavailable";
        case R::kVulkanFailure:               return "vulkan_failure";
        case R::kUnknownHandle:               return "unknown_handle";
    }
    return "unknown";
}

const char* RenderResultName(vanguard::render::RenderFrameResult r) {
    using R = vanguard::render::RenderFrameResult;
    switch (r) {
        case R::kSuccess:                return "success";
        case R::kSuboptimal:             return "suboptimal";
        case R::kBackendNotInitialized:  return "backend_not_initialized";
        case R::kNoSurface:              return "no_surface";
        case R::kInvalidBufferHandle:    return "invalid_buffer_handle";
        case R::kOutOfDate:              return "out_of_date";
        case R::kSurfaceLost:            return "surface_lost";
        case R::kDeviceLost:             return "device_lost";
        case R::kVulkanFailure:          return "vulkan_failure";
        case R::kUnavailable:            return "unavailable";
    }
    return "unknown";
}

} // namespace

// ---------------------------------------------------------------------------
// JNI: createAndroidDagPhase4B1TexturePlaybackSession
// ---------------------------------------------------------------------------
extern "C" JNIEXPORT jstring JNICALL
Java_com_connects_vanguard_1media_1engine_bridge_VanguardNativeBridge_createAndroidDagPhase4B1TexturePlaybackSession(
    JNIEnv*  env,
    jobject  /* this */,
    jobject  surface,
    jint     width,
    jint     height) {

    char status[512];

    if (!surface || width <= 0 || height <= 0) {
        std::snprintf(status, sizeof(status),
            "status=FAIL;reason=invalid_args;sessionId=none");
        return env->NewStringUTF(status);
    }

    ANativeWindow* nw = ANativeWindow_fromSurface(env, surface);
    if (!nw) {
        std::snprintf(status, sizeof(status),
            "status=FAIL;reason=native_window_failed;sessionId=none");
        return env->NewStringUTF(status);
    }

    auto* session = new Phase4B1Session();
    session->nativeWindow = nw;
    session->width        = width;
    session->height       = height;

    uint64_t sid = gNextPhase4B1SessionId.fetch_add(1, std::memory_order_relaxed);
    char sidBuf[32];
    std::snprintf(sidBuf, sizeof(sidBuf), "p4b1_%llu",
        static_cast<unsigned long long>(sid));
    session->sessionId = sidBuf;

    if (!session->backend.initialize()) {
        ANativeWindow_release(nw);
        delete session;
        std::snprintf(status, sizeof(status),
            "status=FAIL;reason=backend_init_failed;sessionId=none");
        return env->NewStringUTF(status);
    }
    session->initialized = true;

    if (!session->backend.attachSurface(
            nw,
            static_cast<uint32_t>(width),
            static_cast<uint32_t>(height))) {
        session->backend.shutdown();
        ANativeWindow_release(nw);
        delete session;
        std::snprintf(status, sizeof(status),
            "status=FAIL;reason=surface_attach_failed;sessionId=none");
        return env->NewStringUTF(status);
    }
    session->surfaceAttached = true;

    auto srcNode  = std::make_shared<vanguard::sources::HardwareBufferSourceNode>(
        kDiag4B1HwSrcNodeId, /*timelineStartPtsUs=*/0, /*durationUs=*/UINT64_MAX);
    auto sinkNode = std::make_shared<vanguard::sinks::PreviewSurfaceSinkNode>(
        kDiag4B1PreviewSinkNodeId);

    const auto addSrc  = session->graph.addNode(srcNode);
    const auto addSink = session->graph.addNode(sinkNode);
    const auto connect = session->graph.connect(
        kDiag4B1HwSrcNodeId,       kDiag4B1VideoOutputPort,
        kDiag4B1PreviewSinkNodeId, "video_in");

    if (!addSrc.ok() || !addSink.ok() || !connect.ok()) {
        session->backend.detachSurface();
        session->backend.shutdown();
        ANativeWindow_release(nw);
        delete session;
        std::snprintf(status, sizeof(status),
            "status=FAIL;reason=graph_build_failed;sessionId=none");
        return env->NewStringUTF(status);
    }
    session->graphGenerationId = session->graph.generationId();
    session->graphBuilt        = true;

    {
        std::lock_guard<std::mutex> lock(gPhase4B1SessionMutex);
        gPhase4B1Sessions[session->sessionId] = session;
    }

    std::snprintf(status, sizeof(status),
        "status=OK;sessionId=%s;width=%d;height=%d",
        session->sessionId.c_str(), width, height);
    return env->NewStringUTF(status);
}

// ---------------------------------------------------------------------------
// JNI: renderAndroidDagPhase4B1TexturePlaybackFrame
// ---------------------------------------------------------------------------
extern "C" JNIEXPORT jstring JNICALL
Java_com_connects_vanguard_1media_1engine_bridge_VanguardNativeBridge_renderAndroidDagPhase4B1TexturePlaybackFrame(
    JNIEnv*  env,
    jobject  /* this */,
    jstring  sessionIdJ,
    jobject  hardwareBufferJ,
    jint     width,
    jint     height,
    jlong    timelinePtsUs,
    jint     frameIndex) {

    char status[512];

    if (!sessionIdJ || !hardwareBufferJ || width <= 0 || height <= 0) {
        std::snprintf(status, sizeof(status),
            "status=FAIL;frameIndex=%d;reason=invalid_args",
            static_cast<int>(frameIndex));
        return env->NewStringUTF(status);
    }

    const char* sidCStr = env->GetStringUTFChars(sessionIdJ, nullptr);
    std::string sid(sidCStr ? sidCStr : "");
    if (sidCStr) env->ReleaseStringUTFChars(sessionIdJ, sidCStr);

    Phase4B1Session* session = nullptr;
    {
        std::lock_guard<std::mutex> lock(gPhase4B1SessionMutex);
        auto it = gPhase4B1Sessions.find(sid);
        if (it != gPhase4B1Sessions.end()) session = it->second;
    }

    if (!session) {
        std::snprintf(status, sizeof(status),
            "status=FAIL;frameIndex=%d;reason=session_not_found;sessionId=%s",
            static_cast<int>(frameIndex), sid.c_str());
        return env->NewStringUTF(status);
    }

    if (!session->initialized || !session->surfaceAttached || !session->graphBuilt) {
        std::snprintf(status, sizeof(status),
            "status=FAIL;frameIndex=%d;reason=session_not_ready",
            static_cast<int>(frameIndex));
        return env->NewStringUTF(status);
    }

    AHardwareBuffer* ahwb = ResolveAHardwareBufferFromJObject(env, hardwareBufferJ);
    if (!ahwb) {
        std::snprintf(status, sizeof(status),
            "status=FAIL;frameIndex=%d;reason=ahardwarebuffer_resolve_failed",
            static_cast<int>(frameIndex));
        return env->NewStringUTF(status);
    }

    vanguard::render::HardwareBufferHandle handle =
        vanguard::render::kInvalidHardwareBufferHandle;
    vanguard::render::HardwareBufferDescriptor descriptor{};
    const auto importResult = session->backend.importHardwareBuffer(
        ahwb, -1, &handle, &descriptor);

    if (importResult != vanguard::render::HardwareBufferImportResult::kSuccess) {
        std::snprintf(status, sizeof(status),
            "status=FAIL;frameIndex=%d;reason=import_failed;importResult=%s",
            static_cast<int>(frameIndex),
            HwBufResultName(importResult));
        return env->NewStringUTF(status);
    }

    vanguard::graph::FrameRequest request;
    request.timelinePtsUs = static_cast<uint64_t>(timelinePtsUs < 0 ? 0 : timelinePtsUs);
    request.generationId  = session->graphGenerationId;
    request.canvasWidth   = static_cast<uint32_t>(width);
    request.canvasHeight  = static_cast<uint32_t>(height);

    vanguard::graph::GraphExecutionPlan plan;
    const auto planStatus =
        vanguard::graph::BuildGraphExecutionPlan(session->graph, request, plan);

    if (!planStatus.ok() || plan.nodes.empty() || plan.sinkNodeIds.empty()) {
        int relFd = -1;
        session->backend.releaseHardwareBuffer(handle, &relFd);
        if (relFd >= 0) { ::close(relFd); }
        std::snprintf(status, sizeof(status),
            "status=FAIL;frameIndex=%d;reason=execution_plan_failed;planStatus=%s",
            static_cast<int>(frameIndex),
            planStatus.message().c_str());
        return env->NewStringUTF(status);
    }

    vanguard::graph::GpuFrameTokenSession tokenSession(
        plan.evaluatedPtsUs, plan.evaluatedGeneration);
    vanguard::render::RenderFrameResult renderResult =
        vanguard::render::RenderFrameResult::kUnavailable;
    const auto callback = MakePhase4B1DispatchCallback(
        handle, descriptor, plan,
        [session](vanguard::render::HardwareBufferHandle h) {
            return session->backend.renderFrame(h);
        },
        &renderResult);

    vanguard::graph::GraphExecutionDispatcher dispatcher;
    vanguard::graph::GraphExecutionDispatchResult dispatchResult;
    const auto dispatchStatus =
        dispatcher.dispatch(plan, tokenSession, callback, dispatchResult);

    int releaseFenceFd = -1;
    const auto releaseResult =
        session->backend.releaseHardwareBuffer(handle, &releaseFenceFd);
    if (releaseFenceFd >= 0) {
        ::close(releaseFenceFd);
        releaseFenceFd = -1;
    }

    if (!dispatchStatus.ok()) {
        std::snprintf(status, sizeof(status),
            "status=FAIL;frameIndex=%d;reason=dispatcher_failed;dispatcherStatus=%s",
            static_cast<int>(frameIndex),
            dispatchStatus.message().c_str());
        return env->NewStringUTF(status);
    }

    const bool renderOk =
        renderResult == vanguard::render::RenderFrameResult::kSuccess ||
        renderResult == vanguard::render::RenderFrameResult::kSuboptimal;

    if (!renderOk) {
        std::snprintf(status, sizeof(status),
            "status=FAIL;frameIndex=%d;reason=render_failed;renderResult=%s",
            static_cast<int>(frameIndex),
            RenderResultName(renderResult));
        return env->NewStringUTF(status);
    }

    const bool releaseOk =
        releaseResult == vanguard::render::HardwareBufferImportResult::kSuccess;

    if (!releaseOk) {
        std::snprintf(status, sizeof(status),
            "status=FAIL;frameIndex=%d;reason=release_failed;releaseResult=%s",
            static_cast<int>(frameIndex),
            HwBufResultName(releaseResult));
        return env->NewStringUTF(status);
    }

    session->renderedFrames++;
    session->lastRenderStatus = "success";

    std::snprintf(status, sizeof(status),
        "status=PASS;frameIndex=%d;renderedFrames=%d;"
        "renderResult=%s;releaseResult=%s;planNodeCount=%zu;planSinkCount=%zu;"
        "dispatcherNodeCount=%u;dispatcherOutputCount=%u;dispatcherTokenCount=%zu",
        static_cast<int>(frameIndex),
        session->renderedFrames,
        RenderResultName(renderResult),
        HwBufResultName(releaseResult),
        plan.nodes.size(),
        plan.sinkNodeIds.size(),
        dispatchResult.nodesDispatched,
        dispatchResult.outputsPublished,
        tokenSession.publishedCount());
    return env->NewStringUTF(status);
}

// ---------------------------------------------------------------------------
// JNI: destroyAndroidDagPhase4B1TexturePlaybackSession
// ---------------------------------------------------------------------------
extern "C" JNIEXPORT jstring JNICALL
Java_com_connects_vanguard_1media_1engine_bridge_VanguardNativeBridge_destroyAndroidDagPhase4B1TexturePlaybackSession(
    JNIEnv*  env,
    jobject  /* this */,
    jstring  sessionIdJ) {

    char status[256];

    if (!sessionIdJ) {
        std::snprintf(status, sizeof(status),
            "status=FAIL;reason=null_session_id");
        return env->NewStringUTF(status);
    }

    const char* sidCStr = env->GetStringUTFChars(sessionIdJ, nullptr);
    std::string sid(sidCStr ? sidCStr : "");
    if (sidCStr) env->ReleaseStringUTFChars(sessionIdJ, sidCStr);

    Phase4B1Session* session = nullptr;
    {
        std::lock_guard<std::mutex> lock(gPhase4B1SessionMutex);
        auto it = gPhase4B1Sessions.find(sid);
        if (it != gPhase4B1Sessions.end()) {
            session = it->second;
            gPhase4B1Sessions.erase(it);
        }
    }

    if (!session) {
        std::snprintf(status, sizeof(status),
            "status=FAIL;reason=session_not_found;sessionId=%s", sid.c_str());
        return env->NewStringUTF(status);
    }

    const int renderedFrames = session->renderedFrames;

    try {
        if (session->surfaceAttached) {
            session->backend.detachSurface();
        }
        if (session->initialized) {
            session->backend.shutdown();
        }
    } catch (...) {}

    if (session->nativeWindow) {
        ANativeWindow_release(session->nativeWindow);
        session->nativeWindow = nullptr;
    }

    delete session;

    std::snprintf(status, sizeof(status),
        "status=OK;sessionId=%s;renderedFrames=%d",
        sid.c_str(), renderedFrames);
    return env->NewStringUTF(status);
}

// ---------------------------------------------------------------------------
// JNI: bumpAndroidDagPhase4B1TexturePlaybackGeneration
// ---------------------------------------------------------------------------
extern "C" JNIEXPORT jstring JNICALL
Java_com_connects_vanguard_1media_1engine_bridge_VanguardNativeBridge_bumpAndroidDagPhase4B1TexturePlaybackGeneration(
    JNIEnv*  env,
    jobject  /* this */,
    jstring  sessionIdJ) {

    char status[256];

    if (!sessionIdJ) {
        std::snprintf(status, sizeof(status),
            "status=FAIL;reason=null_session_id");
        return env->NewStringUTF(status);
    }

    const char* sidCStr = env->GetStringUTFChars(sessionIdJ, nullptr);
    std::string sid(sidCStr ? sidCStr : "");
    if (sidCStr) env->ReleaseStringUTFChars(sessionIdJ, sidCStr);

    Phase4B1Session* session = nullptr;
    {
        std::lock_guard<std::mutex> lock(gPhase4B1SessionMutex);
        auto it = gPhase4B1Sessions.find(sid);
        if (it != gPhase4B1Sessions.end()) session = it->second;
    }

    if (!session) {
        std::snprintf(status, sizeof(status),
            "status=FAIL;reason=session_not_found;sessionId=%s", sid.c_str());
        return env->NewStringUTF(status);
    }

    const uint64_t newGen = session->graph.bumpGeneration();
    session->graphGenerationId = newGen;

    std::snprintf(status, sizeof(status),
        "status=OK;sessionId=%s;generationId=%llu",
        sid.c_str(), static_cast<unsigned long long>(newGen));
    return env->NewStringUTF(status);
}

// ---------------------------------------------------------------------------
// JNI: renderAndroidDagPhase4B1TexturePlaybackFrameForGeneration
// Phase 4B2C: added jint rotationDegrees parameter for UV-space transform.
// Phase 3-Unit Q: added jboolean mirrorHorizontal parameter for horizontal mirror.
// ---------------------------------------------------------------------------
extern "C" JNIEXPORT jstring JNICALL
Java_com_connects_vanguard_1media_1engine_bridge_VanguardNativeBridge_renderAndroidDagPhase4B1TexturePlaybackFrameForGeneration(
    JNIEnv*  env,
    jobject  /* this */,
    jstring  sessionIdJ,
    jobject  hardwareBufferJ,
    jint     width,
    jint     height,
    jlong    timelinePtsUs,
    jint     frameIndex,
    jlong    generationIdJ,
    jint     rotationDegrees,
    jboolean mirrorHorizontal) {

    char status[512];

    if (!sessionIdJ || !hardwareBufferJ || width <= 0 || height <= 0) {
        std::snprintf(status, sizeof(status),
            "status=FAIL;frameIndex=%d;reason=invalid_args",
            static_cast<int>(frameIndex));
        return env->NewStringUTF(status);
    }

    const char* sidCStr = env->GetStringUTFChars(sessionIdJ, nullptr);
    std::string sid(sidCStr ? sidCStr : "");
    if (sidCStr) env->ReleaseStringUTFChars(sessionIdJ, sidCStr);

    Phase4B1Session* session = nullptr;
    {
        std::lock_guard<std::mutex> lock(gPhase4B1SessionMutex);
        auto it = gPhase4B1Sessions.find(sid);
        if (it != gPhase4B1Sessions.end()) session = it->second;
    }

    if (!session) {
        std::snprintf(status, sizeof(status),
            "status=FAIL;frameIndex=%d;reason=session_not_found;sessionId=%s",
            static_cast<int>(frameIndex), sid.c_str());
        return env->NewStringUTF(status);
    }

    if (!session->initialized || !session->surfaceAttached || !session->graphBuilt) {
        std::snprintf(status, sizeof(status),
            "status=FAIL;frameIndex=%d;reason=session_not_ready",
            static_cast<int>(frameIndex));
        return env->NewStringUTF(status);
    }

    AHardwareBuffer* ahwb = ResolveAHardwareBufferFromJObject(env, hardwareBufferJ);
    if (!ahwb) {
        std::snprintf(status, sizeof(status),
            "status=FAIL;frameIndex=%d;reason=ahardwarebuffer_resolve_failed",
            static_cast<int>(frameIndex));
        return env->NewStringUTF(status);
    }

    vanguard::render::HardwareBufferHandle handle =
        vanguard::render::kInvalidHardwareBufferHandle;
    vanguard::render::HardwareBufferDescriptor descriptor{};
    const auto importResult = session->backend.importHardwareBuffer(
        ahwb, -1, &handle, &descriptor);

    if (importResult != vanguard::render::HardwareBufferImportResult::kSuccess) {
        std::snprintf(status, sizeof(status),
            "status=FAIL;frameIndex=%d;reason=import_failed;importResult=%s",
            static_cast<int>(frameIndex),
            HwBufResultName(importResult));
        return env->NewStringUTF(status);
    }

    vanguard::graph::FrameRequest request;
    request.timelinePtsUs = static_cast<uint64_t>(timelinePtsUs < 0 ? 0 : timelinePtsUs);
    request.generationId  = static_cast<uint64_t>(generationIdJ);
    request.canvasWidth   = static_cast<uint32_t>(width);
    request.canvasHeight  = static_cast<uint32_t>(height);

    vanguard::graph::GraphExecutionPlan plan;
    const auto planStatus =
        vanguard::graph::BuildGraphExecutionPlan(session->graph, request, plan);

    if (!planStatus.ok() || plan.nodes.empty() || plan.sinkNodeIds.empty()) {
        int relFd = -1;
        session->backend.releaseHardwareBuffer(handle, &relFd);
        if (relFd >= 0) { ::close(relFd); }

        const bool isStaleGeneration =
            planStatus.message().find("stale generation") != std::string::npos;
        if (isStaleGeneration) {
            std::snprintf(status, sizeof(status),
                "status=FAIL;frameIndex=%d;reason=stale_generation/evaluation_failed;generationId=%llu;currentGeneration=%llu",
                static_cast<int>(frameIndex),
                static_cast<unsigned long long>(generationIdJ),
                static_cast<unsigned long long>(session->graph.generationId()));
        } else {
            std::snprintf(status, sizeof(status),
                "status=FAIL;frameIndex=%d;reason=execution_plan_failed;planStatus=%s",
                static_cast<int>(frameIndex),
                planStatus.message().c_str());
        }
        return env->NewStringUTF(status);
    }

    // Phase 4B2C: build VideoFrameTransform from jint rotationDegrees and call
    // the transform-aware renderFrame overload for UV-space rotation.
    // Phase 3-Unit Q: set mirrorHorizontal from jboolean mirrorHorizontal.
    vanguard::render::VideoFrameTransform transform;
    transform.rotationDegrees = static_cast<uint32_t>(rotationDegrees);
    transform.mirrorHorizontal = (mirrorHorizontal == JNI_TRUE);

    vanguard::graph::GpuFrameTokenSession tokenSession(
        plan.evaluatedPtsUs, plan.evaluatedGeneration);
    vanguard::render::RenderFrameResult renderResult =
        vanguard::render::RenderFrameResult::kUnavailable;
    const auto callback = MakePhase4B1DispatchCallback(
        handle, descriptor, plan,
        [session, transform](vanguard::render::HardwareBufferHandle h) {
            return session->backend.renderFrame(h, transform);
        },
        &renderResult);

    vanguard::graph::GraphExecutionDispatcher dispatcher;
    vanguard::graph::GraphExecutionDispatchResult dispatchResult;
    const auto dispatchStatus =
        dispatcher.dispatch(plan, tokenSession, callback, dispatchResult);

    int releaseFenceFd = -1;
    const auto releaseResult =
        session->backend.releaseHardwareBuffer(handle, &releaseFenceFd);
    if (releaseFenceFd >= 0) {
        ::close(releaseFenceFd);
        releaseFenceFd = -1;
    }

    if (!dispatchStatus.ok()) {
        std::snprintf(status, sizeof(status),
            "status=FAIL;frameIndex=%d;reason=dispatcher_failed;dispatcherStatus=%s",
            static_cast<int>(frameIndex),
            dispatchStatus.message().c_str());
        return env->NewStringUTF(status);
    }

    const bool renderOk =
        renderResult == vanguard::render::RenderFrameResult::kSuccess ||
        renderResult == vanguard::render::RenderFrameResult::kSuboptimal;

    if (!renderOk) {
        std::snprintf(status, sizeof(status),
            "status=FAIL;frameIndex=%d;reason=render_failed;renderResult=%s",
            static_cast<int>(frameIndex),
            RenderResultName(renderResult));
        return env->NewStringUTF(status);
    }

    const bool releaseOk =
        releaseResult == vanguard::render::HardwareBufferImportResult::kSuccess;

    if (!releaseOk) {
        std::snprintf(status, sizeof(status),
            "status=FAIL;frameIndex=%d;reason=release_failed;releaseResult=%s",
            static_cast<int>(frameIndex),
            HwBufResultName(releaseResult));
        return env->NewStringUTF(status);
    }

    session->renderedFrames++;
    session->lastRenderStatus = "success";

    std::snprintf(status, sizeof(status),
        "status=PASS;frameIndex=%d;renderedFrames=%d;generationId=%llu;"
        "renderResult=%s;releaseResult=%s;rotationDegrees=%d;mirrorHorizontal=%s;"
        "planNodeCount=%zu;planSinkCount=%zu;"
        "dispatcherNodeCount=%u;dispatcherOutputCount=%u;dispatcherTokenCount=%zu",
        static_cast<int>(frameIndex),
        session->renderedFrames,
        static_cast<unsigned long long>(generationIdJ),
        RenderResultName(renderResult),
        HwBufResultName(releaseResult),
        static_cast<int>(rotationDegrees),
        (mirrorHorizontal == JNI_TRUE) ? "true" : "false",
        plan.nodes.size(),
        plan.sinkNodeIds.size(),
        dispatchResult.nodesDispatched,
        dispatchResult.outputsPublished,
        tokenSession.publishedCount());
    return env->NewStringUTF(status);
}
