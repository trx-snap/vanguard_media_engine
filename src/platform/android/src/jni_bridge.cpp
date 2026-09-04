#include <jni.h>

#include <android/hardware_buffer.h>
#include <android/native_window_jni.h>
#include <dlfcn.h>
#include <unistd.h>

#include <cstdio>
#include <cstdint>

#include "vanguard/platform/android_backend_probe.h"
#include "vanguard/core/logging.h"
#include "vanguard/render/vulkan_backend.h"
#include "vanguard/graph/graph.h"
#include "vanguard/graph/frame_request.h"

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
        case Result::kVulkanFailure: return "vulkan_failure";
        case Result::kUnavailable: return "unavailable";
    }
    return "unknown";
}

constexpr size_t kSmokeStatusCapacity = 512;

jstring NewSmokeStatus(
    JNIEnv* env,
    bool pass,
    const char* initialize,
    const char* attach,
    const char* import,
    const char* renderFrame,
    const char* release,
    jint width,
    jint height,
    jint releaseFenceFd,
    bool releaseFenceExported) {
    char status[kSmokeStatusCapacity];
    std::snprintf(
        status,
        sizeof(status),
        "status=%s;initialize=%s;attach=%s;import=%s;renderFrame=%s;"
        "release=%s;width=%d;height=%d;releaseFenceFd=%d;releaseFenceExported=%s",
        pass ? "PASS" : "FAIL",
        initialize,
        attach,
        import,
        renderFrame,
        release,
        width,
        height,
        releaseFenceFd,
        releaseFenceExported ? "true" : "false");
    return env->NewStringUTF(status);
}

jstring NewLoopSmokeStatus(
    JNIEnv* env,
    bool pass,
    const char* initialize,
    const char* attach,
    const char* import,
    jint renderedFrames,
    jint frameCount,
    const char* renderFrame,
    jint failingFrame,
    const char* release,
    jint width,
    jint height,
    jint releaseFenceFd,
    bool releaseFenceExported) {
    char status[kSmokeStatusCapacity];
    std::snprintf(
        status,
        sizeof(status),
        "status=%s;initialize=%s;attach=%s;import=%s;renderedFrames=%d;frameCount=%d;"
        "renderFrame=%s;failingFrame=%d;release=%s;width=%d;height=%d;"
        "releaseFenceFd=%d;releaseFenceExported=%s",
        pass ? "PASS" : "FAIL",
        initialize,
        attach,
        import,
        renderedFrames,
        frameCount,
        renderFrame,
        failingFrame,
        release,
        width,
        height,
        releaseFenceFd,
        releaseFenceExported ? "true" : "false");
    return env->NewStringUTF(status);
}

// ── Phase 3C: private diagnostic DAG nodes ────────────────────────────────
// These node classes are local to this translation unit (anonymous namespace)
// and are used only by the diagnostic smoke; they are not part of any product
// graph session.

class Diag3CHardwareBufferSourceNode final : public vanguard::graph::Node {
public:
    explicit Diag3CHardwareBufferSourceNode(std::string id)
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

class Diag3CPreviewSurfaceSinkNode final : public vanguard::graph::Node {
public:
    explicit Diag3CPreviewSurfaceSinkNode(std::string id)
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

// Phase 3C status string — superset of NewLoopSmokeStatus with evaluation fields.
constexpr size_t kDagEvalSmokeStatusCapacity = 768;

jstring NewDagEvalSmokeStatus(
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
    bool        releaseFenceExported) {
    char status[kDagEvalSmokeStatusCapacity];
    std::snprintf(
        status,
        sizeof(status),
        "status=%s;initialize=%s;attach=%s;graphBuild=%s;import=%s;"
        "evaluation=%s;renderedFrames=%d;frameCount=%d;evaluatedPtsUs=%lld;"
        "renderFrame=%s;failingFrame=%d;release=%s;"
        "width=%d;height=%d;releaseFenceFd=%d;releaseFenceExported=%s",
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
        releaseFenceExported ? "true" : "false");
    return env->NewStringUTF(status);
}

} // namespace

extern "C" JNIEXPORT jint JNICALL JNI_OnLoad(JavaVM* vm, void* reserved) {
    vanguard::core::Logger::log("Vanguard JNI_OnLoad");
    return JNI_VERSION_1_6;
}

extern "C" JNIEXPORT jobject JNICALL
Java_com_connects_vanguard_1media_1engine_bridge_VanguardNativeBridge_probeCapabilities(JNIEnv* env, jobject /* this */) {
    auto caps = vanguard::platform::AndroidProbeBackendCapability();

    // Convert to Kotlin BackendCapabilityReport
    jclass reportClass = env->FindClass("com/connects/vanguard_media_engine/diagnostics/BackendCapabilityReport");
    if (!reportClass) return nullptr;

    // Descriptor matches the Phase 2Q / Unit T Kotlin constructor field order:
    //   vulkanSupported: Boolean  -> Z
    //   glesSupported: Boolean    -> Z
    //   selectedBackend: Int      -> I
    //   fallbackReason: String    -> Ljava/lang/String;
    //   gpuVendor: String         -> Ljava/lang/String;
    //   gpuRenderer: String       -> Ljava/lang/String;
    //   vendorId: Long            -> J
    //   deviceId: Long            -> J
    //   apiVersion: Long          -> J
    //   vulkanDriverVersion: Long -> J
    //   profileGateStatus: String -> Ljava/lang/String;
    //   blacklistStatus: String   -> Ljava/lang/String;
    jmethodID ctor = env->GetMethodID(
        reportClass, "<init>",
        "(ZZILjava/lang/String;Ljava/lang/String;Ljava/lang/String;JJJJLjava/lang/String;Ljava/lang/String;)V");
    if (!ctor) return nullptr;

    int selectedInt = (caps.selected == vanguard::render::RenderBackendType::kVulkan) ? 0 :
                      (caps.selected == vanguard::render::RenderBackendType::kGles)   ? 1 : 2;

    jstring fallbackReasonStr    = env->NewStringUTF(caps.fallbackReason.c_str());
    jstring gpuVendorStr         = env->NewStringUTF(caps.gpuVendor.c_str());
    jstring gpuRendererStr       = env->NewStringUTF(caps.gpuRenderer.c_str());
    jstring profileGateStatusStr = env->NewStringUTF(caps.profileGateStatus.c_str());
    jstring blacklistStatusStr   = env->NewStringUTF(caps.blacklistStatus.c_str());

    jobject report = env->NewObject(
        reportClass, ctor,
        static_cast<jboolean>(caps.vulkanSupported),
        static_cast<jboolean>(caps.glesSupported),
        static_cast<jint>(selectedInt),
        fallbackReasonStr,
        gpuVendorStr,
        gpuRendererStr,
        static_cast<jlong>(caps.vendorId),
        static_cast<jlong>(caps.deviceId),
        static_cast<jlong>(caps.apiVersion),
        static_cast<jlong>(caps.vulkanDriverVersion),
        profileGateStatusStr,
        blacklistStatusStr);

    // Release local string refs now that the object is constructed.
    env->DeleteLocalRef(fallbackReasonStr);
    env->DeleteLocalRef(gpuVendorStr);
    env->DeleteLocalRef(gpuRendererStr);
    env->DeleteLocalRef(profileGateStatusStr);
    env->DeleteLocalRef(blacklistStatusStr);

    return report;
}

// ── P1-GPU-BLACKLIST-NATIVE-RULE-PROOF: native rule evaluator diagnostic ────
// Runs synthetic lanes against vanguard::platform::EvaluateGpuDriverBlacklist()
// using locally constructed rule tables; never reads or mutates the
// production (currently zero-entry) driver blacklist beyond confirming its
// size stays zero. Diagnostic-only: no fleet data, no product/app/editor
// wiring, no Vulkan/GLES lifecycle changes.
extern "C" JNIEXPORT jstring JNICALL
Java_com_connects_vanguard_1media_1engine_bridge_VanguardNativeBridge_runAndroidDagPhase1GpuBlacklistNativeSmoke(
    JNIEnv* env, jobject /* this */) {
    const auto smoke = vanguard::platform::RunGpuDriverBlacklistNativeRuleSmoke();
    char status[768];
    std::snprintf(
        status,
        sizeof(status),
        "status=%s;totalLanes=%d;passedLanes=%d;lanes=%s",
        smoke.pass ? "PASS" : "FAIL",
        smoke.totalLanes,
        smoke.passedLanes,
        smoke.laneSummary.c_str());
    return env->NewStringUTF(status);
}

extern "C" JNIEXPORT jstring JNICALL
Java_com_connects_vanguard_1media_1engine_bridge_VanguardNativeBridge_runAndroidDagRenderSmoke(
    JNIEnv* env,
    jobject /* this */,
    jobject surface,
    jobject hardwareBuffer,
    jint width,
    jint height) {
    if (surface == nullptr || hardwareBuffer == nullptr || width <= 0 || height <= 0) {
        return NewSmokeStatus(
            env, false, "not_run", "not_run", "not_run", "not_run",
            "not_run", width, height, -1, false);
    }

    ANativeWindow* nativeWindow = ANativeWindow_fromSurface(env, surface);
    if (nativeWindow == nullptr) {
        return NewSmokeStatus(
            env, false, "not_run", "native_window_failed", "not_run", "not_run",
            "not_run", width, height, -1, false);
    }

    void* libAndroid = dlopen("libandroid.so", RTLD_NOW | RTLD_LOCAL);
    if (libAndroid == nullptr) {
        ANativeWindow_release(nativeWindow);
        return NewSmokeStatus(
            env, false, "not_run", "not_run", "hardware_buffer_jni_unavailable",
            "not_run", "not_run", width, height, -1, false);
    }

    auto fnFromHardwareBuffer = reinterpret_cast<FnAHardwareBuffer_fromHardwareBuffer>(
        dlsym(libAndroid, "AHardwareBuffer_fromHardwareBuffer"));
    if (fnFromHardwareBuffer == nullptr) {
        dlclose(libAndroid);
        ANativeWindow_release(nativeWindow);
        return NewSmokeStatus(
            env, false, "not_run", "not_run", "hardware_buffer_jni_unavailable",
            "not_run", "not_run", width, height, -1, false);
    }

    AHardwareBuffer* borrowedHardwareBuffer =
        fnFromHardwareBuffer(env, hardwareBuffer);
    dlclose(libAndroid);

    const char* initializeStatus = "not_run";
    const char* attachStatus = "not_run";
    const char* importStatus = borrowedHardwareBuffer == nullptr
        ? "hardware_buffer_failed"
        : "not_run";
    const char* renderStatus = "not_run";
    const char* releaseStatus = "not_run";
    bool renderPassed = false;
    bool releasePassed = false;
    bool cleanupCompleted = false;
    int releaseFenceFd = -1;
    // Phase 2P1: capture pre-close fd value and exported flag for status reporting.
    int capturedReleaseFenceFd = -1;
    bool releaseFenceExported = false;

    try {
        vanguard::render::VulkanBackend backend;
        const bool initialized = backend.initialize();
        initializeStatus = initialized ? "success" : "failed";

        bool attached = false;
        vanguard::render::HardwareBufferHandle handle =
            vanguard::render::kInvalidHardwareBufferHandle;
        bool imported = false;

        if (initialized && borrowedHardwareBuffer != nullptr) {
            attached = backend.attachSurface(
                nativeWindow,
                static_cast<uint32_t>(width),
                static_cast<uint32_t>(height));
            attachStatus = attached ? "success" : "failed";
        }

        if (attached) {
            vanguard::render::HardwareBufferDescriptor descriptor{};
            const auto importResult = backend.importHardwareBuffer(
                borrowedHardwareBuffer,
                -1,
                &handle,
                &descriptor);
            importStatus = HardwareBufferResultName(importResult);
            imported = importResult ==
                vanguard::render::HardwareBufferImportResult::kSuccess;
        }

        if (imported) {
            const auto renderResult = backend.renderFrame(handle);
            renderStatus = RenderFrameResultName(renderResult);
            renderPassed =
                renderResult == vanguard::render::RenderFrameResult::kSuccess ||
                renderResult == vanguard::render::RenderFrameResult::kSuboptimal;

            const auto releaseResult =
                backend.releaseHardwareBuffer(handle, &releaseFenceFd);
            releaseStatus = HardwareBufferResultName(releaseResult);
            releasePassed = releaseResult ==
                vanguard::render::HardwareBufferImportResult::kSuccess;

            // Phase 2P1: capture pre-close fd and exported flag immediately after
            // releaseHardwareBuffer and before close/reset.
            capturedReleaseFenceFd = releaseFenceFd;
            releaseFenceExported = (releaseFenceFd >= 0);
        }

        if (releaseFenceFd >= 0) {
            if (::close(releaseFenceFd) != 0) {
                releaseStatus = "fence_close_failed";
                releasePassed = false;
            }
            releaseFenceFd = -1;
        }
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
    return NewSmokeStatus(
        env,
        pass,
        initializeStatus,
        attachStatus,
        importStatus,
        renderStatus,
        releaseStatus,
        width,
        height,
        capturedReleaseFenceFd,
        releaseFenceExported);
}

extern "C" JNIEXPORT jstring JNICALL
Java_com_connects_vanguard_1media_1engine_bridge_VanguardNativeBridge_runAndroidDagRenderLoopSmoke(
    JNIEnv* env,
    jobject /* this */,
    jobject surface,
    jobject hardwareBuffer,
    jint width,
    jint height,
    jint frameCount) {
    if (surface == nullptr || hardwareBuffer == nullptr || width <= 0 || height <= 0 || frameCount <= 0) {
        return NewLoopSmokeStatus(
            env, false, "not_run", "not_run", "not_run", 0, frameCount,
            "not_run", -1, "not_run", width, height, -1, false);
    }

    ANativeWindow* nativeWindow = ANativeWindow_fromSurface(env, surface);
    if (nativeWindow == nullptr) {
        return NewLoopSmokeStatus(
            env, false, "not_run", "native_window_failed", "not_run", 0, frameCount,
            "not_run", -1, "not_run", width, height, -1, false);
    }

    void* libAndroid = dlopen("libandroid.so", RTLD_NOW | RTLD_LOCAL);
    if (libAndroid == nullptr) {
        ANativeWindow_release(nativeWindow);
        return NewLoopSmokeStatus(
            env, false, "not_run", "not_run", "hardware_buffer_jni_unavailable", 0, frameCount,
            "not_run", -1, "not_run", width, height, -1, false);
    }

    auto fnFromHardwareBuffer = reinterpret_cast<FnAHardwareBuffer_fromHardwareBuffer>(
        dlsym(libAndroid, "AHardwareBuffer_fromHardwareBuffer"));
    if (fnFromHardwareBuffer == nullptr) {
        dlclose(libAndroid);
        ANativeWindow_release(nativeWindow);
        return NewLoopSmokeStatus(
            env, false, "not_run", "not_run", "hardware_buffer_jni_unavailable", 0, frameCount,
            "not_run", -1, "not_run", width, height, -1, false);
    }

    AHardwareBuffer* borrowedHardwareBuffer =
        fnFromHardwareBuffer(env, hardwareBuffer);
    dlclose(libAndroid);

    const char* initializeStatus = "not_run";
    const char* attachStatus = "not_run";
    const char* importStatus = borrowedHardwareBuffer == nullptr
        ? "hardware_buffer_failed"
        : "not_run";
    const char* renderStatus = "not_run";
    const char* releaseStatus = "not_run";
    int renderedFrames = 0;
    int failingFrame = -1;
    bool renderPassed = false;
    bool releasePassed = false;
    bool cleanupCompleted = false;
    int releaseFenceFd = -1;
    // Phase 2P1: capture pre-close fd value and exported flag for status reporting.
    int capturedReleaseFenceFd = -1;
    bool releaseFenceExported = false;

    try {
        vanguard::render::VulkanBackend backend;
        const bool initialized = backend.initialize();
        initializeStatus = initialized ? "success" : "failed";

        bool attached = false;
        vanguard::render::HardwareBufferHandle handle =
            vanguard::render::kInvalidHardwareBufferHandle;
        bool imported = false;

        if (initialized && borrowedHardwareBuffer != nullptr) {
            attached = backend.attachSurface(
                nativeWindow,
                static_cast<uint32_t>(width),
                static_cast<uint32_t>(height));
            attachStatus = attached ? "success" : "failed";
        }

        if (attached) {
            vanguard::render::HardwareBufferDescriptor descriptor{};
            const auto importResult = backend.importHardwareBuffer(
                borrowedHardwareBuffer,
                -1,
                &handle,
                &descriptor);
            importStatus = HardwareBufferResultName(importResult);
            imported = importResult ==
                vanguard::render::HardwareBufferImportResult::kSuccess;
        }

        if (imported) {
            renderStatus = "success";
            for (int f = 0; f < frameCount; ++f) {
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
            renderPassed = (renderedFrames == frameCount);

            const auto releaseResult =
                backend.releaseHardwareBuffer(handle, &releaseFenceFd);
            releaseStatus = HardwareBufferResultName(releaseResult);
            releasePassed = releaseResult ==
                vanguard::render::HardwareBufferImportResult::kSuccess;

            // Phase 2P1: capture pre-close fd and exported flag immediately after
            // releaseHardwareBuffer and before close/reset.
            capturedReleaseFenceFd = releaseFenceFd;
            releaseFenceExported = (releaseFenceFd >= 0);
        }

        if (releaseFenceFd >= 0) {
            if (::close(releaseFenceFd) != 0) {
                releaseStatus = "fence_close_failed";
                releasePassed = false;
            }
            releaseFenceFd = -1;
        }
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
    return NewLoopSmokeStatus(
        env,
        pass,
        initializeStatus,
        attachStatus,
        importStatus,
        renderedFrames,
        frameCount,
        renderStatus,
        failingFrame,
        releaseStatus,
        width,
        height,
        capturedReleaseFenceFd,
        releaseFenceExported);
}

// ── Phase 3C: DAG playhead evaluation + multi-frame Vulkan render smoke ──────
extern "C" JNIEXPORT jstring JNICALL
Java_com_connects_vanguard_1media_1engine_bridge_VanguardNativeBridge_runAndroidDagPhase3CEvalRenderSmoke(
    JNIEnv*  env,
    jobject  /* this */,
    jobject  surface,
    jobject  hardwareBuffer,
    jint     width,
    jint     height,
    jint     frameCount,
    jlong    frameDurationUs) {

    // Early-exit sentinel values.
    const char* notRun  = "not_run";
    jlong       zeroPts = 0LL;

    if (surface == nullptr || hardwareBuffer == nullptr ||
        width <= 0 || height <= 0 || frameCount <= 0 || frameDurationUs <= 0) {
        return NewDagEvalSmokeStatus(
            env, false, notRun, notRun, notRun, notRun, notRun,
            0, frameCount, zeroPts, notRun, -1, notRun,
            width, height, -1, false);
    }

    ANativeWindow* nativeWindow = ANativeWindow_fromSurface(env, surface);
    if (nativeWindow == nullptr) {
        return NewDagEvalSmokeStatus(
            env, false, notRun, "native_window_failed", notRun, notRun, notRun,
            0, frameCount, zeroPts, notRun, -1, notRun,
            width, height, -1, false);
    }

    void* libAndroid = dlopen("libandroid.so", RTLD_NOW | RTLD_LOCAL);
    if (libAndroid == nullptr) {
        ANativeWindow_release(nativeWindow);
        return NewDagEvalSmokeStatus(
            env, false, notRun, notRun, notRun, "hardware_buffer_jni_unavailable", notRun,
            0, frameCount, zeroPts, notRun, -1, notRun,
            width, height, -1, false);
    }

    auto fnFromHardwareBuffer = reinterpret_cast<FnAHardwareBuffer_fromHardwareBuffer>(
        dlsym(libAndroid, "AHardwareBuffer_fromHardwareBuffer"));
    if (fnFromHardwareBuffer == nullptr) {
        dlclose(libAndroid);
        ANativeWindow_release(nativeWindow);
        return NewDagEvalSmokeStatus(
            env, false, notRun, notRun, notRun, "hardware_buffer_jni_unavailable", notRun,
            0, frameCount, zeroPts, notRun, -1, notRun,
            width, height, -1, false);
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

    try {
        // ── 1. Initialize VulkanBackend ────────────────────────────────────
        vanguard::render::VulkanBackend backend;
        const bool initialized = backend.initialize();
        initializeStatus = initialized ? "success" : "failed";

        bool attached = false;
        vanguard::render::HardwareBufferHandle handle =
            vanguard::render::kInvalidHardwareBufferHandle;
        bool imported = false;

        // ── 2. Attach surface ──────────────────────────────────────────────
        if (initialized && borrowedHardwareBuffer != nullptr) {
            attached = backend.attachSurface(
                nativeWindow,
                static_cast<uint32_t>(width),
                static_cast<uint32_t>(height));
            attachStatus = attached ? "success" : "failed";
        }

        // ── 3. Build the diagnostic DAG ────────────────────────────────────
        bool     graphOk  = false;
        uint64_t graphGenId = 0u;
        vanguard::graph::Graph graph;

        if (attached) {
            auto srcNode = std::make_shared<Diag3CHardwareBufferSourceNode>(
                "diag3c_hw_src");
            auto sinkNode = std::make_shared<Diag3CPreviewSurfaceSinkNode>(
                "diag3c_preview_sink");

            const auto addSrcStatus  = graph.addNode(srcNode);
            const auto addSinkStatus = graph.addNode(sinkNode);
            const auto connectStatus = graph.connect(
                "diag3c_hw_src",       "kVideoFrame",
                "diag3c_preview_sink", "kVideoFrame");

            if (addSrcStatus.ok() && addSinkStatus.ok() && connectStatus.ok()) {
                graphGenId       = graph.generationId();
                graphBuildStatus = "success";
                graphOk          = true;
            } else {
                graphBuildStatus = "graph_build_failed";
            }
        }

        // ── 4. Import HardwareBuffer ───────────────────────────────────────
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

        // ── 5. Per-frame: evaluatePlayhead → renderFrame ───────────────────
        if (imported) {
            renderStatus     = "success";
            evaluationStatus = "success";

            for (int f = 0; f < frameCount; ++f) {
                // Build FrameRequest for this frame.
                vanguard::graph::FrameRequest request;
                request.timelinePtsUs = static_cast<uint64_t>(f) *
                                        static_cast<uint64_t>(frameDurationUs);
                request.generationId  = graphGenId;
                request.canvasWidth   = static_cast<uint32_t>(width);
                request.canvasHeight  = static_cast<uint32_t>(height);

                // Evaluate playhead — this gates the render.
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

                // Gate: only render if evaluation passed.
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

            // ── 6. Release HardwareBuffer ──────────────────────────────────
            const auto releaseResult =
                backend.releaseHardwareBuffer(handle, &releaseFenceFd);
            releaseStatus = HardwareBufferResultName(releaseResult);
            releasePassed = (releaseResult ==
                vanguard::render::HardwareBufferImportResult::kSuccess);

            capturedReleaseFenceFd = releaseFenceFd;
            releaseFenceExported   = (releaseFenceFd >= 0);
        }

        // ── 7. Close fence fd, detach, shutdown ───────────────────────────
        if (releaseFenceFd >= 0) {
            if (::close(releaseFenceFd) != 0) {
                releaseStatus = "fence_close_failed";
                releasePassed = false;
            }
            releaseFenceFd = -1;
        }
        backend.detachSurface();
        backend.shutdown();
        cleanupCompleted = true;
    } catch (...) {
        initializeStatus = "exception";
        cleanupCompleted = false;
    }

    // Outer safety fence close (if exception bypassed inner close).
    if (releaseFenceFd >= 0) {
        ::close(releaseFenceFd);
    }
    ANativeWindow_release(nativeWindow);

    const bool pass = renderPassed && releasePassed && cleanupCompleted;
    return NewDagEvalSmokeStatus(
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
        releaseFenceExported);
}
