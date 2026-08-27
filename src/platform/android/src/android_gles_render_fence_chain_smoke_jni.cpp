// Phase 1 Unit AM: Android GLES renderFrame -> EGL native-fence GPU chain physical proof JNI bridge.
//
// Android-only translation unit added via CMake target_sources block.
//
// Non-claim: proves native-fence fd creation/signaling/ownership after a real GLES
// renderFrame of imported RGBA AHardwareBuffer on physical hardware; does not
// implement production release fence, does not modify GlesBackend/GlesHardwareBufferImports
// behavior, does not support YUV/OES/external texture, does not add product API/UI,
// does not claim multi-node DAG composition/fleet parity.
//
// JNI entry point:
//   runAndroidDagPhase1AMGlesRenderFenceChainSmoke -> jstring

#include <jni.h>
#include <android/hardware_buffer.h>
#include <android/native_window_jni.h>
#include <android/rect.h>
#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES2/gl2.h>
#include <GLES2/gl2ext.h>
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <unistd.h>

#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <sstream>
#include <string>
#include <vector>

#include "vanguard/render/gles_backend.h"
#include "vanguard/render/render_transform.h"

#ifndef EGL_SYNC_NATIVE_FENCE_ANDROID
#define EGL_SYNC_NATIVE_FENCE_ANDROID 0x3144
#endif
#ifndef EGL_SYNC_NATIVE_FENCE_FD_ANDROID
#define EGL_SYNC_NATIVE_FENCE_FD_ANDROID 0x3145
#endif
#ifndef EGL_NO_NATIVE_FENCE_FD_ANDROID
#define EGL_NO_NATIVE_FENCE_FD_ANDROID -1
#endif
#ifndef EGL_SYNC_NATIVE_FENCE_SIGNALED_ANDROID
#define EGL_SYNC_NATIVE_FENCE_SIGNALED_ANDROID 0x3146
#endif

namespace {

using FnEGLCreateSyncKHR =
    EGLSyncKHR (*)(EGLDisplay, EGLenum, const EGLint*);
using FnEGLDestroySyncKHR =
    EGLBoolean (*)(EGLDisplay, EGLSyncKHR);
using FnEGLDupNativeFenceFDANDROID =
    EGLint (*)(EGLDisplay, EGLSyncKHR);

using FnAHardwareBuffer_fromHardwareBuffer =
    AHardwareBuffer* (*)(JNIEnv*, jobject);
using FnAHardwareBuffer_describe =
    void (*)(const AHardwareBuffer*, AHardwareBuffer_Desc*);
using FnAHardwareBuffer_lock =
    int32_t (*)(AHardwareBuffer*, uint64_t, int32_t, const ARect*, void**);
using FnAHardwareBuffer_unlock =
    int32_t (*)(AHardwareBuffer*, int32_t*);

struct NativeHardwareBufferFunctions {
    FnAHardwareBuffer_fromHardwareBuffer fromHardwareBuffer = nullptr;
    FnAHardwareBuffer_describe describe = nullptr;
    FnAHardwareBuffer_lock lock = nullptr;
    FnAHardwareBuffer_unlock unlock = nullptr;
    bool isValid() const {
        return fromHardwareBuffer && describe && lock && unlock;
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
    fns.lock = reinterpret_cast<FnAHardwareBuffer_lock>(
        dlsym(lib, "AHardwareBuffer_lock"));
    fns.unlock = reinterpret_cast<FnAHardwareBuffer_unlock>(
        dlsym(lib, "AHardwareBuffer_unlock"));

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
        << "bufferWidth=0;"
        << "bufferHeight=0;"
        << "bufferLayers=0;"
        << "bufferFormat=0;"
        << "bufferUsageSampled=false;"
        << "bufferUsageCpuWrite=false;"
        << "bufferFill=not_run;"
        << "writeFenceFd=-1;"
        << "writeFenceWait=none;"
        << "initialize=not_run;"
        << "attach=not_run;"
        << "hasSurfaceAfterAttach=false;"
        << "import=not_run;"
        << "handle=0;"
        << "hasAfterImport=false;"
        << "renderFrame=not_run;"
        << "eglCurrentDisplayOk=false;"
        << "symbolsResolved=false;"
        << "nativeFenceSyncCreate=not_run;"
        << "glFlushOk=false;"
        << "dupNativeFenceFd=-1;"
        << "fdOpenBeforeClose=false;"
        << "waitOutcome=not_run;"
        << "waitSignaled=false;"
        << "closeResult=not_run;"
        << "fdClosedAfterClose=false;"
        << "destroySync=not_run;"
        << "releaseBuffer=not_run;"
        << "releaseFence=-1;"
        << "hasAfterRelease=false;"
        << "detach=not_run;"
        << "surfaceKindAfterDetach=none;"
        << "shutdown=not_run;"
        << "idempotentShutdown=not_run;"
        << "proofBoundary=gles_renderFrame_native_fence_chain_no_release_fence_production_no_yuv_no_product;"
        << "lastError=" << lastErrorReason;
    return oss.str();
}

} // namespace

extern "C" JNIEXPORT jstring JNICALL
Java_com_connects_vanguard_1media_1engine_bridge_VanguardNativeBridge_runAndroidDagPhase1AMGlesRenderFenceChainSmoke(
    JNIEnv* env,
    jobject /* this */,
    jobject jsurface,
    jobject jbuffer,
    jint width,
    jint height) {

    if (!jsurface || !jbuffer || width <= 0 || height <= 0) {
        return env->NewStringUTF(BuildFailureString("invalid_arguments").c_str());
    }

    NativeHardwareBufferFunctions ahbFns = ResolveNativeHardwareBufferFunctions();
    if (!ahbFns.isValid()) {
        return env->NewStringUTF(BuildFailureString("hardware_buffer_symbols_unavailable").c_str());
    }

    ANativeWindow* window = ANativeWindow_fromSurface(env, jsurface);
    if (!window) {
        return env->NewStringUTF(BuildFailureString("native_window_from_surface_failed").c_str());
    }

    AHardwareBuffer* ahb = ahbFns.fromHardwareBuffer(env, jbuffer);
    if (!ahb) {
        ANativeWindow_release(window);
        return env->NewStringUTF(BuildFailureString("hardware_buffer_from_jobject_failed").c_str());
    }

    AHardwareBuffer_Desc desc{};
    ahbFns.describe(ahb, &desc);
    const bool bufferUsageSampled = ((desc.usage & AHARDWAREBUFFER_USAGE_GPU_SAMPLED_IMAGE) != 0);
    const bool bufferUsageCpuWrite = ((desc.usage & AHARDWAREBUFFER_USAGE_CPU_WRITE_OFTEN) != 0);
    const bool bufferDescribeOk = (desc.width == static_cast<uint32_t>(width)) &&
                                  (desc.height == static_cast<uint32_t>(height)) &&
                                  (desc.layers == 1) &&
                                  (desc.format == AHARDWAREBUFFER_FORMAT_R8G8B8A8_UNORM) &&
                                  bufferUsageSampled &&
                                  bufferUsageCpuWrite &&
                                  (desc.stride >= desc.width);

    if (!bufferDescribeOk) {
        ANativeWindow_release(window);
        return env->NewStringUTF(BuildFailureString("hardware_buffer_descriptor_mismatch").c_str());
    }

    // CPU-fill buffer with solid non-black color (R=37, G=111, B=203, A=255)
    void* writeAddr = nullptr;
    int32_t lockRes = ahbFns.lock(ahb, AHARDWAREBUFFER_USAGE_CPU_WRITE_OFTEN, -1, nullptr, &writeAddr);
    bool bufferFillOk = false;
    int writeFenceFd = -1;
    std::string writeFenceWait = "none";
    bool writeFenceOk = false;

    if (lockRes == 0 && writeAddr != nullptr) {
        uint8_t* base = static_cast<uint8_t*>(writeAddr);
        for (uint32_t y = 0; y < desc.height; ++y) {
            uint8_t* row = base + y * desc.stride * 4;
            for (uint32_t x = 0; x < desc.width; ++x) {
                uint8_t* pixel = row + x * 4;
                pixel[0] = 37;
                pixel[1] = 111;
                pixel[2] = 203;
                pixel[3] = 255;
            }
        }
        bufferFillOk = true;

        int32_t fence = -1;
        int32_t unlockRes = ahbFns.unlock(ahb, &fence);
        if (unlockRes == 0) {
            writeFenceFd = fence;
            if (fence >= 0) {
                struct pollfd pfd{};
                pfd.fd = fence;
                pfd.events = POLLIN;
                int pollRes = poll(&pfd, 1, 1000);
                if (pollRes > 0) {
                    if (pfd.revents & (POLLERR | POLLNVAL)) {
                        writeFenceWait = "error";
                        writeFenceOk = false;
                    } else {
                        writeFenceWait = "signaled";
                        writeFenceOk = true;
                    }
                } else if (pollRes == 0) {
                    writeFenceWait = "timeout";
                    writeFenceOk = false;
                } else {
                    writeFenceWait = "error";
                    writeFenceOk = false;
                }
                close(fence);
            } else {
                writeFenceWait = "none";
                writeFenceOk = true;
            }
        } else {
            writeFenceWait = "error";
            writeFenceOk = false;
        }
    }

    if (!bufferFillOk || !writeFenceOk) {
        ANativeWindow_release(window);
        return env->NewStringUTF(BuildFailureString("hardware_buffer_lock_fill_or_fence_failed").c_str());
    }

    vanguard::render::GlesBackend backend;

    // 1. Initialize backend
    const bool initOk = backend.initialize();
    const bool isInitialized = backend.isInitialized();
    const int clientVersion = backend.clientVersion();
    const std::string vendor = SanitizeString(backend.diagnosticVendor());
    const std::string renderer = SanitizeString(backend.diagnosticRenderer());
    const std::string version = SanitizeString(backend.diagnosticVersion());
    const bool initCheckOk = initOk && isInitialized && (clientVersion >= 2) &&
                             !vendor.empty() && !renderer.empty() && !version.empty();

    // 2. Attach surface
    const bool attachOk = backend.attachSurface(window, static_cast<uint32_t>(width), static_cast<uint32_t>(height));
    const bool hasSurfaceAfterAttach = backend.hasSurface();
    const bool attachCheckOk = attachOk && hasSurfaceAfterAttach;

    // 3. Import buffer
    vanguard::render::HardwareBufferHandle handle = vanguard::render::kInvalidHardwareBufferHandle;
    vanguard::render::HardwareBufferDescriptor descImport{};
    const auto importRes = backend.importHardwareBuffer(ahb, -1, &handle, &descImport);
    const bool hasAfterImport = backend.hasHardwareBuffer(handle);
    const bool importCheckOk = (importRes == vanguard::render::HardwareBufferImportResult::kSuccess) &&
                               (handle != vanguard::render::kInvalidHardwareBufferHandle) &&
                               hasAfterImport;

    // 4. renderFrame
    vanguard::render::RenderFrameResult renderFrameRes = vanguard::render::RenderFrameResult::kBackendNotInitialized;
    bool renderFrameOk = false;
    if (importCheckOk && attachCheckOk) {
        renderFrameRes = backend.renderFrame(handle, vanguard::render::VideoFrameTransform{});
        renderFrameOk = (renderFrameRes == vanguard::render::RenderFrameResult::kSuccess);
    }

    // 5. EGL Native Fence GPU Chaining
    EGLDisplay display = eglGetCurrentDisplay();
    const bool eglCurrentDisplayOk = (display != EGL_NO_DISPLAY);

    auto fnCreateSyncKHR = reinterpret_cast<FnEGLCreateSyncKHR>(
        eglGetProcAddress("eglCreateSyncKHR"));
    auto fnDestroySyncKHR = reinterpret_cast<FnEGLDestroySyncKHR>(
        eglGetProcAddress("eglDestroySyncKHR"));
    auto fnDupNativeFenceFDANDROID = reinterpret_cast<FnEGLDupNativeFenceFDANDROID>(
        eglGetProcAddress("eglDupNativeFenceFDANDROID"));

    const bool symbolsResolved = eglCurrentDisplayOk &&
                                 (fnCreateSyncKHR != nullptr) &&
                                 (fnDestroySyncKHR != nullptr) &&
                                 (fnDupNativeFenceFDANDROID != nullptr);

    bool nativeFenceSyncCreateOk = false;
    bool glFlushOk = false;
    int dupFdReportValue = -1;
    bool dupNativeFenceFdOk = false;
    bool fdOpenBeforeClose = false;
    std::string waitOutcome = "not_run";
    bool waitSignaled = false;
    bool closeOk = false;
    bool fdClosedAfterClose = false;
    bool destroySyncOk = false;

    EGLSyncKHR sync = EGL_NO_SYNC_KHR;
    int fenceFd = -1;
    bool fdClosed = false;

    if (renderFrameOk && symbolsResolved) {
        const EGLint syncAttribs[] = {
            EGL_SYNC_NATIVE_FENCE_FD_ANDROID, EGL_NO_NATIVE_FENCE_FD_ANDROID,
            EGL_NONE
        };
        sync = fnCreateSyncKHR(display, EGL_SYNC_NATIVE_FENCE_ANDROID, syncAttribs);
        if (sync != EGL_NO_SYNC_KHR) {
            nativeFenceSyncCreateOk = true;

            while (glGetError() != GL_NO_ERROR) {}
            glFlush();
            glFlushOk = (glGetError() == GL_NO_ERROR);

            fenceFd = fnDupNativeFenceFDANDROID(display, sync);
            if (fenceFd >= 0) {
                dupNativeFenceFdOk = true;
                dupFdReportValue = fenceFd;
                fdOpenBeforeClose = (fcntl(fenceFd, F_GETFD) >= 0);

                struct pollfd pfd{};
                pfd.fd = fenceFd;
                pfd.events = POLLIN;
                pfd.revents = 0;
                const int pollRet = poll(&pfd, 1, 1000);
                if (pollRet > 0) {
                    if ((pfd.revents & (POLLERR | POLLNVAL)) != 0) {
                        waitOutcome = "poll_revents_error";
                        waitSignaled = false;
                    } else if ((pfd.revents & POLLIN) != 0) {
                        waitOutcome = "signaled";
                        waitSignaled = true;
                    } else {
                        waitOutcome = "poll_other_revent";
                        waitSignaled = false;
                    }
                } else if (pollRet == 0) {
                    waitOutcome = "timeout";
                    waitSignaled = false;
                } else {
                    waitOutcome = "poll_error";
                    waitSignaled = false;
                }

                const int closeRes = close(fenceFd);
                fdClosed = true;
                closeOk = (closeRes == 0);
                const int getfdRes = fcntl(fenceFd, F_GETFD);
                fdClosedAfterClose = (getfdRes == -1 && errno == EBADF);
            }

            const EGLBoolean destroyRes = fnDestroySyncKHR(display, sync);
            destroySyncOk = (destroyRes == EGL_TRUE);
            sync = EGL_NO_SYNC_KHR;
        }
    }

    // Ensure sync destroyed and fd closed on all error paths
    if (fenceFd >= 0 && !fdClosed) {
        close(fenceFd);
        fdClosed = true;
    }
    if (sync != EGL_NO_SYNC_KHR && fnDestroySyncKHR != nullptr && display != EGL_NO_DISPLAY) {
        fnDestroySyncKHR(display, sync);
        sync = EGL_NO_SYNC_KHR;
    }

    // 6. Release buffer through backend.releaseHardwareBuffer
    int releaseFence = -999;
    bool releaseBufferOk = false;
    bool hasAfterRelease = true;
    if (handle != vanguard::render::kInvalidHardwareBufferHandle) {
        const auto releaseRes = backend.releaseHardwareBuffer(handle, &releaseFence);
        hasAfterRelease = backend.hasHardwareBuffer(handle);
        releaseBufferOk = (releaseRes == vanguard::render::HardwareBufferImportResult::kSuccess) &&
                          (releaseFence == -1) &&
                          !hasAfterRelease;
    }

    // 7. Detach surface, release ANativeWindow, shutdown and idempotent shutdown
    backend.detachSurface();
    const bool hasSurfaceAfterDetach = backend.hasSurface();
    const std::string surfaceKindAfterDetach = SanitizeString(backend.activeSurfaceKind());
    const bool detachOk = !hasSurfaceAfterDetach;

    // Release ANativeWindow acquired from JNI Surface
    ANativeWindow_release(window);

    backend.shutdown();
    const bool shutdownOk = !backend.isInitialized();

    backend.shutdown();
    const bool idempotentShutdownOk = !backend.isInitialized();

    const bool allChecksPass = bufferDescribeOk &&
                               bufferFillOk &&
                               writeFenceOk &&
                               initCheckOk &&
                               attachCheckOk &&
                               importCheckOk &&
                               renderFrameOk &&
                               eglCurrentDisplayOk &&
                               symbolsResolved &&
                               nativeFenceSyncCreateOk &&
                               glFlushOk &&
                               dupNativeFenceFdOk &&
                               fdOpenBeforeClose &&
                               (waitOutcome == "signaled") &&
                               waitSignaled &&
                               closeOk &&
                               fdClosedAfterClose &&
                               destroySyncOk &&
                               releaseBufferOk &&
                               detachOk &&
                               shutdownOk &&
                               idempotentShutdownOk;

    const std::string backendLastError = SanitizeString(backend.lastError());

    std::ostringstream oss;
    oss << "status=" << (allChecksPass ? "PASS" : "FAIL") << ";"
        << "clientVersion=" << clientVersion << ";"
        << "vendor=" << vendor << ";"
        << "renderer=" << renderer << ";"
        << "version=" << version << ";"
        << "bufferDescribe=" << (bufferDescribeOk ? "success" : "failed") << ";"
        << "bufferWidth=" << desc.width << ";"
        << "bufferHeight=" << desc.height << ";"
        << "bufferLayers=" << desc.layers << ";"
        << "bufferFormat=" << desc.format << ";"
        << "bufferUsageSampled=" << (bufferUsageSampled ? "true" : "false") << ";"
        << "bufferUsageCpuWrite=" << (bufferUsageCpuWrite ? "true" : "false") << ";"
        << "bufferFill=" << (bufferFillOk ? "success" : "failed") << ";"
        << "writeFenceFd=" << writeFenceFd << ";"
        << "writeFenceWait=" << writeFenceWait << ";"
        << "initialize=" << (initCheckOk ? "success" : "failed") << ";"
        << "attach=" << (attachCheckOk ? "success" : "failed") << ";"
        << "hasSurfaceAfterAttach=" << (hasSurfaceAfterAttach ? "true" : "false") << ";"
        << "import=" << (importCheckOk ? "success" : "failed") << ";"
        << "handle=" << handle << ";"
        << "hasAfterImport=" << (hasAfterImport ? "true" : "false") << ";"
        << "renderFrame=" << (renderFrameOk ? "success" : "failed") << ";"
        << "eglCurrentDisplayOk=" << (eglCurrentDisplayOk ? "true" : "false") << ";"
        << "symbolsResolved=" << (symbolsResolved ? "true" : "false") << ";"
        << "nativeFenceSyncCreate=" << (nativeFenceSyncCreateOk ? "success" : "failed") << ";"
        << "glFlushOk=" << (glFlushOk ? "true" : "false") << ";"
        << "dupNativeFenceFd=" << dupFdReportValue << ";"
        << "fdOpenBeforeClose=" << (fdOpenBeforeClose ? "true" : "false") << ";"
        << "waitOutcome=" << waitOutcome << ";"
        << "waitSignaled=" << (waitSignaled ? "true" : "false") << ";"
        << "closeResult=" << (closeOk ? "success" : "failed") << ";"
        << "fdClosedAfterClose=" << (fdClosedAfterClose ? "true" : "false") << ";"
        << "destroySync=" << (destroySyncOk ? "success" : "failed") << ";"
        << "releaseBuffer=" << (releaseBufferOk ? "success" : "failed") << ";"
        << "releaseFence=" << releaseFence << ";"
        << "hasAfterRelease=" << (hasAfterRelease ? "true" : "false") << ";"
        << "detach=" << (detachOk ? "success" : "failed") << ";"
        << "surfaceKindAfterDetach=" << surfaceKindAfterDetach << ";"
        << "shutdown=" << (shutdownOk ? "success" : "failed") << ";"
        << "idempotentShutdown=" << (idempotentShutdownOk ? "success" : "failed") << ";"
        << "proofBoundary=gles_renderFrame_native_fence_chain_no_release_fence_production_no_yuv_no_product;"
        << "lastError=" << (backendLastError.empty() ? "none" : backendLastError);

    const std::string resultStr = oss.str();
    return env->NewStringUTF(resultStr.c_str());
}
