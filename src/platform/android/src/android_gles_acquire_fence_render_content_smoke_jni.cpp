// Phase 1 Unit AN: Android GLES acquire-fence import -> renderFrame content physical proof JNI bridge.
//
// Android-only translation unit added via CMake target_sources block.
//
// Non-claim: proves real EGL native-fence fd ownership transfer/close through
// GlesBackend.importHardwareBuffer followed by GLES diagnostic render content
// readback from the imported AHB on physical hardware; does not implement
// production release fence, does not modify GlesBackend/GlesHardwareBufferImports
// behavior, does not support YUV/OES/external texture, does not add product API/UI,
// does not claim multi-node DAG composition/fleet parity.
//
// JNI entry point:
//   runAndroidDagPhase1ANGlesAcquireFenceRenderContentSmoke -> jstring

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

#include <cmath>
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
        << "eglCurrentDisplayOk=false;"
        << "symbolsResolved=false;"
        << "acquireFenceCreate=not_run;"
        << "glFlushOk=false;"
        << "acquireFenceFd=-1;"
        << "acquireFenceOpenBeforeImport=false;"
        << "acquireFenceDestroyed=false;"
        << "attach=not_run;"
        << "hasSurfaceAfterAttach=false;"
        << "import=not_run;"
        << "acquireFenceClosedAfterImport=false;"
        << "handle=0;"
        << "descriptorWidth=0;"
        << "descriptorHeight=0;"
        << "descriptorLayers=0;"
        << "descriptorFormat=0;"
        << "descriptorUsageSampled=false;"
        << "hasAfterImport=false;"
        << "diagnosticRender=not_run;"
        << "centerRead=not_run;"
        << "centerR=0;"
        << "centerG=0;"
        << "centerB=0;"
        << "centerA=0;"
        << "centerPixelMatches=false;"
        << "releaseBuffer=not_run;"
        << "releaseFence=-1;"
        << "hasAfterRelease=false;"
        << "detach=not_run;"
        << "surfaceKindAfterDetach=none;"
        << "shutdown=not_run;"
        << "idempotentShutdown=not_run;"
        << "proofBoundary=gles_acquire_fence_import_render_content_release_fence_optional_no_yuv_no_product;"
        << "lastError=" << lastErrorReason;
    return oss.str();
}

} // namespace

extern "C" JNIEXPORT jstring JNICALL
Java_com_connects_vanguard_1media_1engine_bridge_VanguardNativeBridge_runAndroidDagPhase1ANGlesAcquireFenceRenderContentSmoke(
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

    // CPU-fill buffer with solid color R=53, G=137, B=219, A=255
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
                pixel[0] = 53;
                pixel[1] = 137;
                pixel[2] = 219;
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

    // 1. Initialize GlesBackend first so an EGL context/display is current
    const bool initOk = backend.initialize();
    const bool isInitialized = backend.isInitialized();
    const int clientVersion = backend.clientVersion();
    const std::string vendor = SanitizeString(backend.diagnosticVendor());
    const std::string renderer = SanitizeString(backend.diagnosticRenderer());
    const std::string version = SanitizeString(backend.diagnosticVersion());
    const bool initCheckOk = initOk && isInitialized && (clientVersion >= 2) &&
                             !vendor.empty() && !renderer.empty() && !version.empty();

    // 2. Resolve EGL native-fence symbols and check current display
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

    // 3. Create EGL_SYNC_NATIVE_FENCE_ANDROID, glFlush, dup native fence fd, destroy sync object
    bool acquireFenceCreateOk = false;
    bool glFlushOk = false;
    int acquireFenceFd = -1;
    bool acquireFenceOpenBeforeImport = false;
    bool acquireFenceDestroyed = false;

    if (initCheckOk && symbolsResolved) {
        const EGLint syncAttribs[] = {
            EGL_SYNC_NATIVE_FENCE_FD_ANDROID, EGL_NO_NATIVE_FENCE_FD_ANDROID,
            EGL_NONE
        };
        EGLSyncKHR sync = fnCreateSyncKHR(display, EGL_SYNC_NATIVE_FENCE_ANDROID, syncAttribs);
        if (sync != EGL_NO_SYNC_KHR) {
            acquireFenceCreateOk = true;
            while (glGetError() != GL_NO_ERROR) {}
            glFlush();
            glFlushOk = (glGetError() == GL_NO_ERROR);
            const int rawFd = fnDupNativeFenceFDANDROID(display, sync);
            const EGLBoolean destroyRes = fnDestroySyncKHR(display, sync);
            acquireFenceDestroyed = (destroyRes == EGL_TRUE);
            if (rawFd >= 0) {
#ifdef F_DUPFD_CLOEXEC
                int dupFd = fcntl(rawFd, F_DUPFD_CLOEXEC, 1000);
#else
                int dupFd = -1;
#endif
                if (dupFd < 0) {
                    dupFd = fcntl(rawFd, F_DUPFD, 1000);
                    if (dupFd >= 0) {
                        fcntl(dupFd, F_SETFD, FD_CLOEXEC);
                    }
                }
                close(rawFd);
                if (dupFd >= 0) {
                    acquireFenceFd = dupFd;
                    acquireFenceOpenBeforeImport = (fcntl(acquireFenceFd, F_GETFD) >= 0);
                }
            }
        }
    }

    // 4. Attach ANativeWindow
    const bool attachOk = backend.attachSurface(window, static_cast<uint32_t>(width), static_cast<uint32_t>(height));
    const bool hasSurfaceAfterAttach = backend.hasSurface();
    const bool attachCheckOk = attachOk && hasSurfaceAfterAttach;

    // 5. Call backend.importHardwareBuffer(ahb, acquireFenceFd, &handle, &desc)
    vanguard::render::HardwareBufferHandle handle = vanguard::render::kInvalidHardwareBufferHandle;
    vanguard::render::HardwareBufferDescriptor descImport{};
    bool importOk = false;
    bool acquireFenceClosedAfterImport = false;
    bool descImportOk = false;
    bool hasAfterImport = false;

    if (attachCheckOk && acquireFenceOpenBeforeImport && acquireFenceFd >= 0) {
        const int passedFd = acquireFenceFd;
        const auto importRes = backend.importHardwareBuffer(ahb, passedFd, &handle, &descImport);
        importOk = (importRes == vanguard::render::HardwareBufferImportResult::kSuccess) &&
                   (handle != vanguard::render::kInvalidHardwareBufferHandle);
        errno = 0;
        const int getfdRes = fcntl(passedFd, F_GETFD);
        acquireFenceClosedAfterImport = (getfdRes == -1 && errno == EBADF);
        descImportOk = (descImport.width == static_cast<uint32_t>(width)) &&
                       (descImport.height == static_cast<uint32_t>(height)) &&
                       (descImport.layers == 1) &&
                       ((descImport.usage & AHARDWAREBUFFER_USAGE_GPU_SAMPLED_IMAGE) != 0) &&
                       (descImport.format != 0);
        hasAfterImport = backend.hasHardwareBuffer(handle);
    } else {
        // If not passed into importHardwareBuffer, close acquireFenceFd to prevent fd leak
        if (acquireFenceFd >= 0) {
            close(acquireFenceFd);
        }
    }

    // 6. Diagnostic render and center 1x1 readback
    bool diagnosticRenderOk = false;
    bool centerReadOk = false;
    int centerR = 0;
    int centerG = 0;
    int centerB = 0;
    int centerA = 0;
    bool centerPixelMatches = false;

    if (importOk && hasAfterImport) {
        diagnosticRenderOk = backend.diagnosticRenderFrameForReadback(
            handle,
            vanguard::render::VideoFrameTransform{0, false});

        if (diagnosticRenderOk) {
            std::vector<uint8_t> centerPixel(4, 0);
            centerReadOk = backend.diagnosticReadPixels(
                static_cast<uint32_t>(width / 2),
                static_cast<uint32_t>(height / 2),
                1, 1,
                centerPixel.data(),
                4);
            centerR = static_cast<int>(centerPixel[0]);
            centerG = static_cast<int>(centerPixel[1]);
            centerB = static_cast<int>(centerPixel[2]);
            centerA = static_cast<int>(centerPixel[3]);
            centerPixelMatches = (std::abs(centerR - 53) <= 8) &&
                                 (std::abs(centerG - 137) <= 8) &&
                                 (std::abs(centerB - 219) <= 8) &&
                                 (centerA >= 240);
        }
    }

    // 7. Release buffer with non-null outReleaseFenceFd
    int releaseFence = -999;
    bool releaseBufferOk = false;
    bool hasAfterRelease = true;

    if (handle != vanguard::render::kInvalidHardwareBufferHandle) {
        const auto releaseRes = backend.releaseHardwareBuffer(handle, &releaseFence);
        hasAfterRelease = backend.hasHardwareBuffer(handle);
        releaseBufferOk = (releaseRes == vanguard::render::HardwareBufferImportResult::kSuccess) &&
                          (releaseFence >= -1) &&
                          !hasAfterRelease;
    }

    // 8. Detach surface, release ANativeWindow, shutdown and idempotent shutdown
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

    // Close any non-negative fds returned by releaseHardwareBuffer exactly once after capturing
    if (releaseFence >= 0) {
        ::close(releaseFence);
    }

    const bool allChecksPass = bufferDescribeOk &&
                               bufferFillOk &&
                               writeFenceOk &&
                               initCheckOk &&
                               eglCurrentDisplayOk &&
                               symbolsResolved &&
                               acquireFenceCreateOk &&
                               glFlushOk &&
                               (acquireFenceFd >= 0) &&
                               acquireFenceOpenBeforeImport &&
                               acquireFenceDestroyed &&
                               attachCheckOk &&
                               hasSurfaceAfterAttach &&
                               importOk &&
                               acquireFenceClosedAfterImport &&
                               (handle != vanguard::render::kInvalidHardwareBufferHandle) &&
                               descImportOk &&
                               hasAfterImport &&
                               diagnosticRenderOk &&
                               centerReadOk &&
                               centerPixelMatches &&
                               releaseBufferOk &&
                               (releaseFence >= -1) &&
                               !hasAfterRelease &&
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
        << "eglCurrentDisplayOk=" << (eglCurrentDisplayOk ? "true" : "false") << ";"
        << "symbolsResolved=" << (symbolsResolved ? "true" : "false") << ";"
        << "acquireFenceCreate=" << (acquireFenceCreateOk ? "success" : "failed") << ";"
        << "glFlushOk=" << (glFlushOk ? "true" : "false") << ";"
        << "acquireFenceFd=" << acquireFenceFd << ";"
        << "acquireFenceOpenBeforeImport=" << (acquireFenceOpenBeforeImport ? "true" : "false") << ";"
        << "acquireFenceDestroyed=" << (acquireFenceDestroyed ? "true" : "false") << ";"
        << "attach=" << (attachCheckOk ? "success" : "failed") << ";"
        << "hasSurfaceAfterAttach=" << (hasSurfaceAfterAttach ? "true" : "false") << ";"
        << "import=" << (importOk ? "success" : "failed") << ";"
        << "acquireFenceClosedAfterImport=" << (acquireFenceClosedAfterImport ? "true" : "false") << ";"
        << "handle=" << handle << ";"
        << "descriptorWidth=" << descImport.width << ";"
        << "descriptorHeight=" << descImport.height << ";"
        << "descriptorLayers=" << descImport.layers << ";"
        << "descriptorFormat=" << descImport.format << ";"
        << "descriptorUsageSampled=" << (((descImport.usage & AHARDWAREBUFFER_USAGE_GPU_SAMPLED_IMAGE) != 0) ? "true" : "false") << ";"
        << "hasAfterImport=" << (hasAfterImport ? "true" : "false") << ";"
        << "diagnosticRender=" << (diagnosticRenderOk ? "success" : "failed") << ";"
        << "centerRead=" << (centerReadOk ? "success" : "failed") << ";"
        << "centerR=" << centerR << ";"
        << "centerG=" << centerG << ";"
        << "centerB=" << centerB << ";"
        << "centerA=" << centerA << ";"
        << "centerPixelMatches=" << (centerPixelMatches ? "true" : "false") << ";"
        << "releaseBuffer=" << (releaseBufferOk ? "success" : "failed") << ";"
        << "releaseFence=" << releaseFence << ";"
        << "hasAfterRelease=" << (hasAfterRelease ? "true" : "false") << ";"
        << "detach=" << (detachOk ? "success" : "failed") << ";"
        << "surfaceKindAfterDetach=" << surfaceKindAfterDetach << ";"
        << "shutdown=" << (shutdownOk ? "success" : "failed") << ";"
        << "idempotentShutdown=" << (idempotentShutdownOk ? "success" : "failed") << ";"
        << "proofBoundary=gles_acquire_fence_import_render_content_release_fence_optional_no_yuv_no_product;"
        << "lastError=" << (backendLastError.empty() ? "none" : backendLastError);

    const std::string resultStr = oss.str();
    return env->NewStringUTF(resultStr.c_str());
}
