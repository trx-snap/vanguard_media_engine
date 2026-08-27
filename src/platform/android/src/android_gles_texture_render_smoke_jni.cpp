// Phase 1 Unit AX: Android GLES SurfaceProducer Flutter Texture DAG render
// smoke JNI bridge.
//
// Android-only translation unit added via CMake target_sources block.
//
// Proves that the platform-neutral Graph::evaluatePlayhead can gate a
// multi-frame GlesBackend::renderFrame(handle) render loop against an
// ANativeWindow obtained from a Flutter TextureRegistry.SurfaceProducer
// Surface, mirroring the Unit AV proof (see
// android_gles_eval_render_smoke_jni.cpp) but against a texture-producer
// surface instead of an offscreen SurfaceTexture.
//
// Non-claim: diagnostic-only foundation; no MediaCodec decoded input, no
// ImageReader.PRIVATE, no product UI, no ConnectsApp wiring, no Phase 1
// closure.
//
// JNI entry point:
//   runAndroidDagPhase1AXGlesTextureRenderSmoke -> jstring

#include <jni.h>

#include <android/hardware_buffer.h>
#include <android/native_window_jni.h>
#include <dlfcn.h>
#include <unistd.h>

#include <cstdint>
#include <cstdio>
#include <memory>
#include <string>

#include "vanguard/graph/frame_request.h"
#include "vanguard/graph/graph.h"
#include "vanguard/render/gles_backend.h"

namespace {

using FnAHardwareBuffer_fromHardwareBuffer =
    AHardwareBuffer* (*)(JNIEnv*, jobject);

const char* HardwareBufferResultName(
    vanguard::render::HardwareBufferImportResult result) {
    using Result = vanguard::render::HardwareBufferImportResult;
    switch (result) {
        case Result::kSuccess: return "success";
        case Result::kUnavailable: return "unavailable";
        case Result::kBackendNotInitialized: return "backend_not_initialized";
        case Result::kInvalidArgument: return "invalid_argument";
        case Result::kDuplicateImport: return "duplicate_import";
        case Result::kIncompatibleBuffer: return "incompatible_buffer";
        case Result::kVulkanFunctionUnavailable: return "vulkan_function_unavailable";
        case Result::kVulkanFailure: return "vulkan_failure";
        case Result::kUnknownHandle: return "unknown_handle";
    }
    return "unknown";
}

const char* RenderFrameResultName(vanguard::render::RenderFrameResult result) {
    using Result = vanguard::render::RenderFrameResult;
    switch (result) {
        case Result::kSuccess: return "success";
        case Result::kSuboptimal: return "suboptimal";
        case Result::kBackendNotInitialized: return "backend_not_initialized";
        case Result::kNoSurface: return "no_surface";
        case Result::kInvalidBufferHandle: return "invalid_buffer_handle";
        case Result::kOutOfDate: return "out_of_date";
        case Result::kSurfaceLost: return "surface_lost";
        case Result::kDeviceLost: return "device_lost";
        // Shared RenderFrameResult enum with the Vulkan backend; this string
        // is retained verbatim even though this translation unit is GLES-only.
        case Result::kVulkanFailure: return "vulkan_failure";
        case Result::kUnavailable: return "unavailable";
    }
    return "unknown";
}

std::string SanitizeString(const char* input) {
    if (!input) {
        return "";
    }
    std::string s(input);
    for (char& c : s) {
        if (c == ';' || c == '\n' || c == '\r') {
            c = '_';
        }
    }
    return s;
}

// ── Phase 1 Unit AX: private diagnostic DAG nodes ─────────────────────────
// These node classes are local to this translation unit (anonymous
// namespace) and are used only by this diagnostic smoke; they are not part
// of any product graph session.

class DiagAXGlesHardwareBufferSourceNode final : public vanguard::graph::Node {
public:
    explicit DiagAXGlesHardwareBufferSourceNode(std::string id)
        : id_(std::move(id)) {
        outputPorts_ = {{ "kVideoFrame", vanguard::graph::PortDataType::kVideoFrame }};
    }

    const std::string&                  id()          const override { return id_; }
    vanguard::graph::NodeKind           kind()        const override { return vanguard::graph::NodeKind::kSource; }
    vanguard::graph::NodeType           type()        const override { return vanguard::graph::NodeType::kHardwareBufferSource; }
    const std::vector<vanguard::graph::PortDescriptor>& inputPorts()  const override { return inputPorts_; }
    const std::vector<vanguard::graph::PortDescriptor>& outputPorts() const override { return outputPorts_; }

    bool     isActiveAt(uint64_t /*timelinePtsUs*/) const override { return true; }
    uint64_t mapTimelineToLocalPts(uint64_t pts)    const override { return pts; }
    float    blendWeightAt(uint64_t /*pts*/)        const override { return 1.0f; }

private:
    std::string id_;
    std::vector<vanguard::graph::PortDescriptor> inputPorts_;
    std::vector<vanguard::graph::PortDescriptor> outputPorts_;
};

class DiagAXGlesTextureSurfaceSinkNode final : public vanguard::graph::Node {
public:
    explicit DiagAXGlesTextureSurfaceSinkNode(std::string id)
        : id_(std::move(id)) {
        inputPorts_ = {{ "kVideoFrame", vanguard::graph::PortDataType::kVideoFrame }};
    }

    const std::string&                  id()          const override { return id_; }
    vanguard::graph::NodeKind           kind()        const override { return vanguard::graph::NodeKind::kSink; }
    vanguard::graph::NodeType           type()        const override { return vanguard::graph::NodeType::kPreviewSurfaceSink; }
    const std::vector<vanguard::graph::PortDescriptor>& inputPorts()  const override { return inputPorts_; }
    const std::vector<vanguard::graph::PortDescriptor>& outputPorts() const override { return outputPorts_; }

    bool     isActiveAt(uint64_t /*timelinePtsUs*/) const override { return true; }
    uint64_t mapTimelineToLocalPts(uint64_t pts)    const override { return pts; }
    float    blendWeightAt(uint64_t /*pts*/)        const override { return 1.0f; }

private:
    std::string id_;
    std::vector<vanguard::graph::PortDescriptor> inputPorts_;
    std::vector<vanguard::graph::PortDescriptor> outputPorts_;
};

constexpr size_t kTextureDagRenderSmokeStatusCapacity = 960;

jstring NewTextureDagRenderSmokeStatus(
    JNIEnv*     env,
    bool        pass,
    const char* initialize,
    const char* attach,
    const char* graphBuild,
    const char* import_,
    const char* evaluation,
    jint        renderedFrames,
    jint        frameCount,
    jlong       evaluatedPtsUs,
    const char* renderFrame,
    jint        failingFrame,
    const char* release,
    jint        width,
    jint        height,
    jint        releaseFenceFd,
    bool        releaseFenceExported,
    const char* lastError) {
    char status[kTextureDagRenderSmokeStatusCapacity];
    std::snprintf(
        status,
        sizeof(status),
        "status=%s;initialize=%s;attach=%s;graphBuild=%s;import=%s;"
        "evaluation=%s;renderedFrames=%d;frameCount=%d;evaluatedPtsUs=%lld;"
        "renderFrame=%s;failingFrame=%d;release=%s;"
        "width=%d;height=%d;textureSurface=true;releaseFenceFd=%d;"
        "releaseFenceExported=%s;"
        "proofBoundary=gles_surfaceproducer_texture_dag_render_foundation_no_decoded_input_no_product_ui;"
        "lastError=%s",
        pass ? "PASS" : "FAIL",
        initialize,
        attach,
        graphBuild,
        import_,
        evaluation,
        renderedFrames,
        frameCount,
        static_cast<long long>(evaluatedPtsUs),
        renderFrame,
        failingFrame,
        release,
        width,
        height,
        releaseFenceFd,
        releaseFenceExported ? "true" : "false",
        (lastError && lastError[0] != '\0') ? lastError : "none");
    return env->NewStringUTF(status);
}

} // namespace

// ── Phase 1 Unit AX: GLES SurfaceProducer texture DAG render smoke ────────
extern "C" JNIEXPORT jstring JNICALL
Java_com_connects_vanguard_1media_1engine_bridge_VanguardNativeBridge_runAndroidDagPhase1AXGlesTextureRenderSmoke(
    JNIEnv*  env,
    jobject  /* this */,
    jobject  surface,
    jobject  hardwareBuffer,
    jint     width,
    jint     height,
    jint     frameCount,
    jlong    frameDurationUs) {

    const char* notRun  = "not_run";
    jlong       zeroPts = 0LL;

    if (surface == nullptr || hardwareBuffer == nullptr ||
        width <= 0 || height <= 0 || frameCount <= 0 || frameDurationUs <= 0) {
        return NewTextureDagRenderSmokeStatus(
            env, false, notRun, notRun, notRun, notRun, notRun,
            0, frameCount, zeroPts, notRun, -1, notRun,
            width, height, -1, false, "invalid_arguments");
    }

    ANativeWindow* nativeWindow = ANativeWindow_fromSurface(env, surface);
    if (nativeWindow == nullptr) {
        return NewTextureDagRenderSmokeStatus(
            env, false, notRun, "native_window_failed", notRun, notRun, notRun,
            0, frameCount, zeroPts, notRun, -1, notRun,
            width, height, -1, false, "native_window_from_surface_failed");
    }

    void* libAndroid = dlopen("libandroid.so", RTLD_NOW | RTLD_LOCAL);
    if (libAndroid == nullptr) {
        ANativeWindow_release(nativeWindow);
        return NewTextureDagRenderSmokeStatus(
            env, false, notRun, notRun, notRun, "hardware_buffer_jni_unavailable", notRun,
            0, frameCount, zeroPts, notRun, -1, notRun,
            width, height, -1, false, "hardware_buffer_jni_unavailable");
    }

    auto fnFromHardwareBuffer = reinterpret_cast<FnAHardwareBuffer_fromHardwareBuffer>(
        dlsym(libAndroid, "AHardwareBuffer_fromHardwareBuffer"));
    if (fnFromHardwareBuffer == nullptr) {
        dlclose(libAndroid);
        ANativeWindow_release(nativeWindow);
        return NewTextureDagRenderSmokeStatus(
            env, false, notRun, notRun, notRun, "hardware_buffer_jni_unavailable", notRun,
            0, frameCount, zeroPts, notRun, -1, notRun,
            width, height, -1, false, "hardware_buffer_jni_unavailable");
    }

    AHardwareBuffer* borrowedHardwareBuffer = fnFromHardwareBuffer(env, hardwareBuffer);
    dlclose(libAndroid);

    const char* initializeStatus = notRun;
    const char* attachStatus     = notRun;
    const char* graphBuildStatus = notRun;
    const char* importStatus     = (borrowedHardwareBuffer == nullptr)
                                       ? "hardware_buffer_failed"
                                       : notRun;
    const char* evaluationStatus = notRun;
    const char* renderStatus     = notRun;
    const char* releaseStatus    = notRun;

    int   renderedFrames         = 0;
    int   failingFrame           = -1;
    jlong lastEvaluatedPtsUs    = 0LL;
    bool  evalLoopOk             = true;
    bool  renderPassed           = false;
    bool  releasePassed          = false;
    bool  cleanupCompleted       = false;
    int   releaseFenceFd         = -1;
    int   capturedReleaseFenceFd = -1;
    bool  releaseFenceExported   = false;
    std::string lastErrorMessage;

    try {
        // ── 1. Initialize GlesBackend ───────────────────────────────────────
        vanguard::render::GlesBackend backend;
        const bool initialized = backend.initialize();
        initializeStatus = initialized ? "success" : "failed";

        bool attached = false;
        vanguard::render::HardwareBufferHandle handle =
            vanguard::render::kInvalidHardwareBufferHandle;
        bool imported = false;

        // ── 2. Attach the SurfaceProducer-backed window surface ─────────────
        if (initialized && borrowedHardwareBuffer != nullptr) {
            attached = backend.attachSurface(
                nativeWindow,
                static_cast<uint32_t>(width),
                static_cast<uint32_t>(height));
            attachStatus = attached ? "success" : "failed";
        }

        // ── 3. Build the tiny diagnostic source->sink DAG ───────────────────
        bool     graphOk   = false;
        uint64_t graphGenId = 0u;
        vanguard::graph::Graph graph;

        if (attached) {
            auto srcNode = std::make_shared<DiagAXGlesHardwareBufferSourceNode>(
                "diag_ax_hw_src");
            auto sinkNode = std::make_shared<DiagAXGlesTextureSurfaceSinkNode>(
                "diag_ax_texture_sink");

            const auto addSrcStatus  = graph.addNode(srcNode);
            const auto addSinkStatus = graph.addNode(sinkNode);
            const auto connectStatus = graph.connect(
                "diag_ax_hw_src",     "kVideoFrame",
                "diag_ax_texture_sink", "kVideoFrame");

            if (addSrcStatus.ok() && addSinkStatus.ok() && connectStatus.ok()) {
                graphGenId       = graph.generationId();
                graphBuildStatus = "success";
                graphOk          = true;
            } else {
                graphBuildStatus = "graph_build_failed";
            }
        }

        // ── 4. Import the borrowed RGBA HardwareBuffer ──────────────────────
        if (graphOk) {
            vanguard::render::HardwareBufferDescriptor descriptor{};
            const auto importResult = backend.importHardwareBuffer(
                borrowedHardwareBuffer,
                -1,
                &handle,
                &descriptor);
            importStatus = HardwareBufferResultName(importResult);
            imported = (importResult ==
                vanguard::render::HardwareBufferImportResult::kSuccess);
        }

        // ── 5. Per-frame: evaluatePlayhead → renderFrame ────────────────────
        if (imported) {
            renderStatus     = "success";
            evaluationStatus = "success";

            for (int f = 0; f < frameCount; ++f) {
                vanguard::graph::FrameRequest request;
                request.timelinePtsUs = static_cast<uint64_t>(f) *
                                        static_cast<uint64_t>(frameDurationUs);
                request.generationId  = graphGenId;
                request.canvasWidth   = static_cast<uint32_t>(width);
                request.canvasHeight  = static_cast<uint32_t>(height);

                vanguard::graph::FrameEvaluationResult evalResult;
                const auto evalStatus = graph.evaluatePlayhead(request, evalResult);

                lastEvaluatedPtsUs = static_cast<jlong>(evalResult.evaluatedPtsUs);

                if (!evalStatus.ok() || !evalResult.ok() ||
                    !evalResult.hasVideo ||
                    evalResult.activeNodes.empty()) {
                    evaluationStatus = "evaluation_failed";
                    evalLoopOk       = false;
                    failingFrame     = f;
                    break;
                }

                const auto renderResult = backend.renderFrame(handle);
                if (renderResult == vanguard::render::RenderFrameResult::kSuccess ||
                    renderResult == vanguard::render::RenderFrameResult::kSuboptimal) {
                    renderedFrames++;
                } else {
                    renderStatus = RenderFrameResultName(renderResult);
                    failingFrame = f;
                    break;
                }
            }

            renderPassed = (renderedFrames == frameCount) &&
                           evalLoopOk &&
                           (failingFrame == -1);

            // ── 6. Release the HardwareBuffer import ─────────────────────────
            const auto releaseResult =
                backend.releaseHardwareBuffer(handle, &releaseFenceFd);
            releaseStatus = HardwareBufferResultName(releaseResult);
            releasePassed = (releaseResult ==
                vanguard::render::HardwareBufferImportResult::kSuccess);

            capturedReleaseFenceFd = releaseFenceFd;
            releaseFenceExported   = (releaseFenceFd >= 0);
        }

        // ── 7. Close any exported fence fd, detach, shutdown ────────────────
        if (releaseFenceFd >= 0) {
            if (::close(releaseFenceFd) != 0) {
                releaseStatus = "fence_close_failed";
                releasePassed = false;
            }
            releaseFenceFd = -1;
        }
        lastErrorMessage = SanitizeString(backend.lastError());
        backend.detachSurface();
        backend.shutdown();
        cleanupCompleted = true;
    } catch (...) {
        initializeStatus = "exception";
        cleanupCompleted = false;
    }

    if (releaseFenceFd >= 0) {
        ::close(releaseFenceFd);
    }
    ANativeWindow_release(nativeWindow);

    const bool pass = renderPassed && releasePassed && cleanupCompleted;
    return NewTextureDagRenderSmokeStatus(
        env,
        pass,
        initializeStatus,
        attachStatus,
        graphBuildStatus,
        importStatus,
        evaluationStatus,
        renderedFrames,
        frameCount,
        lastEvaluatedPtsUs,
        renderStatus,
        failingFrame,
        releaseStatus,
        width,
        height,
        capturedReleaseFenceFd,
        releaseFenceExported,
        lastErrorMessage.c_str());
}
