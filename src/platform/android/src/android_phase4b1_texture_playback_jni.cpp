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
#include <memory>
#include <mutex>
#include <string>
#include <unordered_map>

#include "vanguard/core/logging.h"
#include "vanguard/graph/frame_request.h"
#include "vanguard/graph/graph.h"
#include "vanguard/render/vulkan_backend.h"

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
// Diagnostic DAG node types for Phase 4B1A
// ---------------------------------------------------------------------------

class Diag4B1HardwareBufferSourceNode final : public vanguard::graph::Node {
public:
    explicit Diag4B1HardwareBufferSourceNode(std::string id)
        : id_(std::move(id)) {
        outputPorts_ = {{ "kVideoFrame", vanguard::graph::PortDataType::kVideoFrame }};
    }

    const std::string&                  id()          const override { return id_; }
    vanguard::graph::NodeKind           kind()        const override { return vanguard::graph::NodeKind::kSource; }
    vanguard::graph::NodeType           type()        const override { return vanguard::graph::NodeType::kHardwareBufferSource; }
    const std::vector<vanguard::graph::PortDescriptor>& inputPorts()  const override { return inputPorts_; }
    const std::vector<vanguard::graph::PortDescriptor>& outputPorts() const override { return outputPorts_; }

    bool     isActiveAt(uint64_t) const override { return true; }
    uint64_t mapTimelineToLocalPts(uint64_t pts) const override { return pts; }
    float    blendWeightAt(uint64_t)  const override { return 1.0f; }

private:
    std::string id_;
    std::vector<vanguard::graph::PortDescriptor> inputPorts_;
    std::vector<vanguard::graph::PortDescriptor> outputPorts_;
};

class Diag4B1PreviewSurfaceSinkNode final : public vanguard::graph::Node {
public:
    explicit Diag4B1PreviewSurfaceSinkNode(std::string id)
        : id_(std::move(id)) {
        inputPorts_ = {{ "kVideoFrame", vanguard::graph::PortDataType::kVideoFrame }};
    }

    const std::string&                  id()          const override { return id_; }
    vanguard::graph::NodeKind           kind()        const override { return vanguard::graph::NodeKind::kSink; }
    vanguard::graph::NodeType           type()        const override { return vanguard::graph::NodeType::kPreviewSurfaceSink; }
    const std::vector<vanguard::graph::PortDescriptor>& inputPorts()  const override { return inputPorts_; }
    const std::vector<vanguard::graph::PortDescriptor>& outputPorts() const override { return outputPorts_; }

    bool     isActiveAt(uint64_t) const override { return true; }
    uint64_t mapTimelineToLocalPts(uint64_t pts) const override { return pts; }
    float    blendWeightAt(uint64_t)  const override { return 1.0f; }

private:
    std::string id_;
    std::vector<vanguard::graph::PortDescriptor> inputPorts_;
    std::vector<vanguard::graph::PortDescriptor> outputPorts_;
};

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

    auto srcNode  = std::make_shared<Diag4B1HardwareBufferSourceNode>("diag4b1_hw_src");
    auto sinkNode = std::make_shared<Diag4B1PreviewSurfaceSinkNode>("diag4b1_preview_sink");

    const auto addSrc  = session->graph.addNode(srcNode);
    const auto addSink = session->graph.addNode(sinkNode);
    const auto connect = session->graph.connect(
        "diag4b1_hw_src",       "kVideoFrame",
        "diag4b1_preview_sink", "kVideoFrame");

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

    vanguard::graph::FrameEvaluationResult evalResult;
    const auto evalStatus = session->graph.evaluatePlayhead(request, evalResult);

    if (!evalStatus.ok() || !evalResult.ok() ||
        !evalResult.hasVideo ||
        evalResult.activeNodes.empty()) {
        int relFd = -1;
        session->backend.releaseHardwareBuffer(handle, &relFd);
        if (relFd >= 0) { ::close(relFd); }
        std::snprintf(status, sizeof(status),
            "status=FAIL;frameIndex=%d;reason=evaluation_failed",
            static_cast<int>(frameIndex));
        return env->NewStringUTF(status);
    }

    const auto renderResult = session->backend.renderFrame(handle);
    const bool renderOk =
        renderResult == vanguard::render::RenderFrameResult::kSuccess ||
        renderResult == vanguard::render::RenderFrameResult::kSuboptimal;

    int releaseFenceFd = -1;
    const auto releaseResult =
        session->backend.releaseHardwareBuffer(handle, &releaseFenceFd);
    if (releaseFenceFd >= 0) {
        ::close(releaseFenceFd);
        releaseFenceFd = -1;
    }

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
        "renderResult=%s;releaseResult=%s",
        static_cast<int>(frameIndex),
        session->renderedFrames,
        RenderResultName(renderResult),
        HwBufResultName(releaseResult));
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
