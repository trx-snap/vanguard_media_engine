// Phase 1 Unit AK: Android GLES releaseHardwareBuffer live release-fence output physical proof JNI bridge.
//
// Android-only translation unit added via CMake target_sources block.
//
// JNI entry point:
//   runAndroidDagPhase1AKGlesReleaseFenceProductionSmoke -> jstring

#include <jni.h>
#include <android/hardware_buffer.h>
#include <android/native_window_jni.h>
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <unistd.h>

#include <cstdint>
#include <sstream>
#include <string>

#include "vanguard/render/gles_backend.h"
#include "vanguard/render/render_transform.h"

namespace {

using FnAHardwareBuffer_fromHardwareBuffer =
    AHardwareBuffer* (*)(JNIEnv*, jobject);
using FnAHardwareBuffer_describe =
    void (*)(const AHardwareBuffer*, AHardwareBuffer_Desc*);

struct NativeHardwareBufferFunctions {
    FnAHardwareBuffer_fromHardwareBuffer fromHardwareBuffer = nullptr;
    FnAHardwareBuffer_describe describe = nullptr;
    bool isValid() const {
        return fromHardwareBuffer && describe;
    }
};

NativeHardwareBufferFunctions ResolveNativeHardwareBufferFunctions() {
    NativeHardwareBufferFunctions fns;
    void* lib = dlopen("libandroid.so", RTLD_NOW | RTLD_LOCAL);
    if (!lib) return fns;

    fns.fromHardwareBuffer = reinterpret_cast<FnAHardwareBuffer_fromHardwareBuffer>(
        dlsym(lib, "AHardwareBuffer_fromHardwareBuffer"));
    fns.describe = reinterpret_cast<FnAHardwareBuffer_describe>(
        dlsym(lib, "AHardwareBuffer_describe"));

    dlclose(lib);
    return fns;
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

std::string BuildFailureString(const char* lastErrorReason) {
    std::ostringstream oss;
    oss << "status=FAIL;"
        << "clientVersion=0;"
        << "vendor=;"
        << "renderer=;"
        << "version=;"
        << "bufferDescribe=not_run;"
        << "initialize=not_run;"
        << "attach=not_run;"
        << "import=not_run;"
        << "handle=0;"
        << "diagnosticRender=not_run;"
        << "releaseBuffer=not_run;"
        << "releaseFenceFd=-1;"
        << "releaseFenceHighFd=-1;"
        << "releaseFenceHighFdOpen=false;"
        << "releaseFenceWaitOutcome=not_run;"
        << "releaseFenceWaitSignaled=false;"
        << "releaseFenceOriginalClose=not_run;"
        << "releaseFenceHighClose=not_run;"
        << "releaseFenceHighFdClosedAfterClose=false;"
        << "hasAfterRelease=false;"
        << "doubleRelease=not_run;"
        << "doubleReleaseFence=-1;"
        << "detach=not_run;"
        << "shutdown=not_run;"
        << "idempotentShutdown=not_run;"
        << "proofBoundary=gles_release_fence_production_fd_live_poll_close_no_yuv_no_product;"
        << "lastError=" << lastErrorReason;
    return oss.str();
}

} // namespace

extern "C" JNIEXPORT jstring JNICALL
Java_com_connects_vanguard_1media_1engine_bridge_VanguardNativeBridge_runAndroidDagPhase1AKGlesReleaseFenceProductionSmoke(
    JNIEnv* env,
    jobject /* this */,
    jobject jsurface,
    jobject jHardwareBuffer,
    jint width,
    jint height) {

    if (!jsurface || !jHardwareBuffer || width <= 0 || height <= 0) {
        return env->NewStringUTF(BuildFailureString("invalid_arguments").c_str());
    }

    ANativeWindow* window = ANativeWindow_fromSurface(env, jsurface);
    if (!window) {
        return env->NewStringUTF(BuildFailureString("native_window_from_surface_failed").c_str());
    }

    NativeHardwareBufferFunctions ahbFns = ResolveNativeHardwareBufferFunctions();
    if (!ahbFns.isValid()) {
        ANativeWindow_release(window);
        return env->NewStringUTF(BuildFailureString("hardware_buffer_symbols_unavailable").c_str());
    }

    AHardwareBuffer* ahb = ahbFns.fromHardwareBuffer(env, jHardwareBuffer);
    if (!ahb) {
        ANativeWindow_release(window);
        return env->NewStringUTF(BuildFailureString("hardware_buffer_from_jobject_failed").c_str());
    }

    // 1. Buffer describe
    AHardwareBuffer_Desc descBuf{};
    ahbFns.describe(ahb, &descBuf);
    const bool bufferUsageSampled = ((descBuf.usage & AHARDWAREBUFFER_USAGE_GPU_SAMPLED_IMAGE) != 0);
    const bool bufferDescribeOk = (descBuf.width == static_cast<uint32_t>(width)) &&
                                  (descBuf.height == static_cast<uint32_t>(height)) &&
                                  (descBuf.layers == 1) &&
                                  (descBuf.format == AHARDWAREBUFFER_FORMAT_R8G8B8A8_UNORM) &&
                                  bufferUsageSampled;

    vanguard::render::GlesBackend backend;

    // Initialize backend
    const bool initOk = backend.initialize();
    const bool isInitialized = backend.isInitialized();
    const int clientVersion = backend.clientVersion();
    const std::string vendor = SanitizeString(backend.diagnosticVendor());
    const std::string renderer = SanitizeString(backend.diagnosticRenderer());
    const std::string version = SanitizeString(backend.diagnosticVersion());
    const bool initCheckOk = initOk && isInitialized && (clientVersion >= 2) &&
                             !vendor.empty() && !renderer.empty() && !version.empty();

    // Attach provided Surface
    const bool attachOk = backend.attachSurface(window, static_cast<uint32_t>(width), static_cast<uint32_t>(height));
    const bool hasSurfaceAfterAttach = backend.hasSurface();
    const std::string surfaceKindAfterAttach = SanitizeString(backend.activeSurfaceKind());
    const bool attachCheckOk = attachOk && hasSurfaceAfterAttach && (surfaceKindAfterAttach == "window");

    // 2. Import RGBA_8888 GPU-sampled hardwareBuffer with acquire fence -1
    vanguard::render::HardwareBufferHandle handle = vanguard::render::kInvalidHardwareBufferHandle;
    vanguard::render::HardwareBufferDescriptor descImport{};
    const auto importRes = backend.importHardwareBuffer(ahb, -1, &handle, &descImport);
    const bool importOk = (importRes == vanguard::render::HardwareBufferImportResult::kSuccess) &&
                          (handle != vanguard::render::kInvalidHardwareBufferHandle);
    const bool hasAfterImport = backend.hasHardwareBuffer(handle);
    const bool importCheckOk = importOk && hasAfterImport;

    // 3. Execute diagnosticRenderFrameForReadback (no swap) to leave real GLES work before release
    const bool diagnosticRenderOk = importCheckOk && backend.diagnosticRenderFrameForReadback(
        handle, vanguard::render::VideoFrameTransform{0, false});

    // 4. Call releaseHardwareBuffer(handle, &releaseFenceFd)
    int releaseFenceFd = -999;
    const auto releaseRes = backend.releaseHardwareBuffer(handle, &releaseFenceFd);
    const bool releaseBufferOk = (releaseRes == vanguard::render::HardwareBufferImportResult::kSuccess);
    const int initialReleaseFenceFd = releaseFenceFd;
    const bool hasAfterRelease = backend.hasHardwareBuffer(handle);
    const bool releaseCheckOk = releaseBufferOk && (releaseFenceFd >= 0) && !hasAfterRelease;

    // 5. Duplicate into high range with fcntl(releaseFenceFd, F_DUPFD, 1000)
    int releaseFenceHighFd = -1;
    bool releaseFenceHighFdOpen = false;
    std::string releaseFenceWaitOutcome = "not_run";
    bool releaseFenceWaitSignaled = false;
    bool releaseFenceOriginalClose = false;
    bool releaseFenceHighClose = false;
    bool releaseFenceHighFdClosedAfterClose = false;

    if (releaseFenceFd >= 0) {
        releaseFenceHighFd = fcntl(releaseFenceFd, F_DUPFD, 1000);
        if (releaseFenceHighFd >= 0) {
            releaseFenceHighFdOpen = (fcntl(releaseFenceHighFd, F_GETFD) >= 0);

            // Close original returned fd exactly once after duplicating
            const int origCloseRes = ::close(releaseFenceFd);
            releaseFenceOriginalClose = (origCloseRes == 0);
            releaseFenceFd = -1;

            // Bounded poll on high fd (2000ms)
            struct pollfd pfd{};
            pfd.fd = releaseFenceHighFd;
            pfd.events = POLLIN;
            pfd.revents = 0;
            const int pollRet = ::poll(&pfd, 1, 2000);
            if (pollRet > 0) {
                if ((pfd.revents & (POLLERR | POLLNVAL)) != 0) {
                    releaseFenceWaitOutcome = "poll_revents_error";
                    releaseFenceWaitSignaled = false;
                } else if ((pfd.revents & POLLIN) != 0) {
                    releaseFenceWaitOutcome = "signaled";
                    releaseFenceWaitSignaled = true;
                } else {
                    releaseFenceWaitOutcome = "poll_other_revent";
                    releaseFenceWaitSignaled = false;
                }
            } else if (pollRet == 0) {
                releaseFenceWaitOutcome = "timeout";
                releaseFenceWaitSignaled = false;
            } else {
                releaseFenceWaitOutcome = "poll_error";
                releaseFenceWaitSignaled = false;
            }

            // Close high fd and check EBADF
            const int highCloseRes = ::close(releaseFenceHighFd);
            releaseFenceHighClose = (highCloseRes == 0);
            const int getfdRes = fcntl(releaseFenceHighFd, F_GETFD);
            releaseFenceHighFdClosedAfterClose = (getfdRes == -1 && errno == EBADF);
        } else {
            // Dup failed: close original fd
            const int origCloseRes = ::close(releaseFenceFd);
            releaseFenceOriginalClose = (origCloseRes == 0);
            releaseFenceFd = -1;
        }
    }

    // Defensive close if still open on any abnormal branch
    if (releaseFenceFd >= 0) {
        ::close(releaseFenceFd);
        releaseFenceFd = -1;
    }

    // 6. Unknown/double release after removal returns kUnknownHandle with output -1
    int doubleReleaseFence = -999;
    const auto doubleReleaseRes = backend.releaseHardwareBuffer(handle, &doubleReleaseFence);
    const bool doubleReleaseOk = (doubleReleaseRes == vanguard::render::HardwareBufferImportResult::kUnknownHandle) &&
                                 (doubleReleaseFence == -1);
    if (doubleReleaseFence >= 0) {
        ::close(doubleReleaseFence);
    }

    // 7. Detach surface, release ANativeWindow, shutdown and idempotent shutdown
    backend.detachSurface();
    const bool hasSurfaceAfterDetach = backend.hasSurface();
    const std::string surfaceKindAfterDetach = SanitizeString(backend.activeSurfaceKind());
    const bool detachOk = !hasSurfaceAfterDetach && (surfaceKindAfterDetach == "offscreen");

    ANativeWindow_release(window);

    backend.shutdown();
    const bool isInitAfterShutdown = backend.isInitialized();
    const bool hasAfterShutdown = backend.hasHardwareBuffer(handle);

    backend.shutdown();
    const bool idempotentShutdownOk = !backend.isInitialized() && !backend.hasHardwareBuffer(handle);
    const bool shutdownCheckOk = !isInitAfterShutdown && !hasAfterShutdown && idempotentShutdownOk;

    // 8. Overall pass evaluation
    const bool allChecksPass = bufferDescribeOk &&
                               initCheckOk &&
                               attachCheckOk &&
                               importCheckOk &&
                               diagnosticRenderOk &&
                               releaseCheckOk &&
                               (releaseFenceHighFd >= 1000) &&
                               releaseFenceHighFdOpen &&
                               (releaseFenceWaitOutcome == "signaled") &&
                               releaseFenceWaitSignaled &&
                               releaseFenceOriginalClose &&
                               releaseFenceHighClose &&
                               releaseFenceHighFdClosedAfterClose &&
                               !hasAfterRelease &&
                               doubleReleaseOk &&
                               detachOk &&
                               shutdownCheckOk;

    const std::string backendLastError = SanitizeString(backend.lastError());

    std::ostringstream oss;
    oss << "status=" << (allChecksPass ? "PASS" : "FAIL") << ";"
        << "clientVersion=" << clientVersion << ";"
        << "vendor=" << vendor << ";"
        << "renderer=" << renderer << ";"
        << "version=" << version << ";"
        << "bufferDescribe=" << (bufferDescribeOk ? "success" : "failed") << ";"
        << "initialize=" << (initCheckOk ? "success" : "failed") << ";"
        << "attach=" << (attachCheckOk ? "success" : "failed") << ";"
        << "import=" << (importCheckOk ? "success" : "failed") << ";"
        << "handle=" << handle << ";"
        << "diagnosticRender=" << (diagnosticRenderOk ? "success" : "failed") << ";"
        << "releaseBuffer=" << (releaseBufferOk ? "success" : "failed") << ";"
        << "releaseFenceFd=" << initialReleaseFenceFd << ";"
        << "releaseFenceHighFd=" << releaseFenceHighFd << ";"
        << "releaseFenceHighFdOpen=" << (releaseFenceHighFdOpen ? "true" : "false") << ";"
        << "releaseFenceWaitOutcome=" << releaseFenceWaitOutcome << ";"
        << "releaseFenceWaitSignaled=" << (releaseFenceWaitSignaled ? "true" : "false") << ";"
        << "releaseFenceOriginalClose=" << (releaseFenceOriginalClose ? "success" : "failed") << ";"
        << "releaseFenceHighClose=" << (releaseFenceHighClose ? "success" : "failed") << ";"
        << "releaseFenceHighFdClosedAfterClose=" << (releaseFenceHighFdClosedAfterClose ? "true" : "false") << ";"
        << "hasAfterRelease=" << (hasAfterRelease ? "true" : "false") << ";"
        << "doubleRelease=" << (doubleReleaseOk ? "rejected_as_expected" : "failed") << ";"
        << "doubleReleaseFence=" << doubleReleaseFence << ";"
        << "detach=" << (detachOk ? "success" : "failed") << ";"
        << "shutdown=" << (!isInitAfterShutdown ? "success" : "failed") << ";"
        << "idempotentShutdown=" << (idempotentShutdownOk ? "success" : "failed") << ";"
        << "proofBoundary=gles_release_fence_production_fd_live_poll_close_no_yuv_no_product;"
        << "lastError=" << (backendLastError.empty() ? "none" : backendLastError);

    const std::string resultStr = oss.str();
    return env->NewStringUTF(resultStr.c_str());
}
