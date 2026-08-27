// Phase 1 Unit AE: Android GLES AHardwareBuffer acquire-fence wait/close foundation smoke JNI bridge.
//
// Android-only translation unit added via CMake target_sources block.
//
// JNI entry point:
//   runAndroidDagPhase1AEGlesAcquireFenceSmoke -> jstring

#include <jni.h>
#include <android/hardware_buffer.h>
#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES2/gl2.h>
#include <GLES2/gl2ext.h>

#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <unistd.h>

#include <sstream>
#include <string>

#include "vanguard/render/gles_backend.h"

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

using FnAHardwareBuffer_fromHardwareBuffer =
    AHardwareBuffer* (*)(JNIEnv*, jobject);

using FnEGLCreateSyncKHR =
    EGLSyncKHR (*)(EGLDisplay, EGLenum, const EGLint*);
using FnEGLDestroySyncKHR =
    EGLBoolean (*)(EGLDisplay, EGLSyncKHR);
using FnEGLDupNativeFenceFDANDROID =
    EGLint (*)(EGLDisplay, EGLSyncKHR);

AHardwareBuffer* ResolveAHardwareBufferFromJObject(JNIEnv* env, jobject jHwBuf) {
    if (!jHwBuf) return nullptr;
    void* lib = dlopen("libandroid.so", RTLD_NOW | RTLD_LOCAL);
    if (!lib) return nullptr;
    auto fn = reinterpret_cast<FnAHardwareBuffer_fromHardwareBuffer>(
        dlsym(lib, "AHardwareBuffer_fromHardwareBuffer"));
    AHardwareBuffer* buf = nullptr;
    if (fn) {
        buf = fn(env, jHwBuf);
    }
    dlclose(lib);
    return buf;
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

bool IsFdClosed(int fd) {
    if (fd < 0) return true;
    const int res = fcntl(fd, F_GETFD);
    return (res == -1 && errno == EBADF);
}

} // namespace

extern "C" JNIEXPORT jstring JNICALL
Java_com_connects_vanguard_1media_1engine_bridge_VanguardNativeBridge_runAndroidDagPhase1AEGlesAcquireFenceSmoke(
    JNIEnv* env,
    jobject /* this */,
    jobject jHardwareBuffer,
    jint width,
    jint height) {

    if (!jHardwareBuffer || width <= 0 || height <= 0) {
        std::ostringstream oss;
        oss << "status=FAIL;"
            << "clientVersion=0;"
            << "vendor=;"
            << "renderer=;"
            << "version=;"
            << "symbolsResolved=false;"
            << "nativeFenceExtension=not_run;"
            << "preInitImport=not_run;"
            << "preInitHandle=0;"
            << "preInitDescriptorZero=false;"
            << "initialize=not_run;"
            << "invalidFenceImport=not_run;"
            << "invalidFenceLastError=none;"
            << "invalidFenceDescriptorZero=false;"
            << "invalidFenceHandle=0;"
            << "invalidFenceClosed=false;"
            << "timeoutImport=not_run;"
            << "timeoutLastError=none;"
            << "timeoutDescriptorZero=false;"
            << "timeoutHandle=0;"
            << "timeoutFdClosed=false;"
            << "signaledFenceCreate=not_run;"
            << "signaledFenceDup=not_run;"
            << "signaledFenceFd=-1;"
            << "signaledImport=not_run;"
            << "signaledFdClosed=false;"
            << "signaledHandle=0;"
            << "descriptorWidth=0;"
            << "descriptorHeight=0;"
            << "descriptorLayers=0;"
            << "descriptorFormat=0;"
            << "descriptorUsageSampled=false;"
            << "hasAfterImport=false;"
            << "release=not_run;"
            << "releaseFence=-1;"
            << "hasAfterRelease=false;"
            << "shutdown=not_run;"
            << "idempotentShutdown=not_run;"
            << "proofBoundary=gles_ahb_rgba_import_acquire_fence_wait_close_no_yuv_no_release_fence_no_product;"
            << "lastError=invalid_arguments";
        return env->NewStringUTF(oss.str().c_str());
    }

    AHardwareBuffer* ahb = ResolveAHardwareBufferFromJObject(env, jHardwareBuffer);
    if (!ahb) {
        std::ostringstream oss;
        oss << "status=FAIL;"
            << "clientVersion=0;"
            << "vendor=;"
            << "renderer=;"
            << "version=;"
            << "symbolsResolved=false;"
            << "nativeFenceExtension=not_run;"
            << "preInitImport=not_run;"
            << "preInitHandle=0;"
            << "preInitDescriptorZero=false;"
            << "initialize=not_run;"
            << "invalidFenceImport=not_run;"
            << "invalidFenceLastError=none;"
            << "invalidFenceDescriptorZero=false;"
            << "invalidFenceHandle=0;"
            << "invalidFenceClosed=false;"
            << "timeoutImport=not_run;"
            << "timeoutLastError=none;"
            << "timeoutDescriptorZero=false;"
            << "timeoutHandle=0;"
            << "timeoutFdClosed=false;"
            << "signaledFenceCreate=not_run;"
            << "signaledFenceDup=not_run;"
            << "signaledFenceFd=-1;"
            << "signaledImport=not_run;"
            << "signaledFdClosed=false;"
            << "signaledHandle=0;"
            << "descriptorWidth=0;"
            << "descriptorHeight=0;"
            << "descriptorLayers=0;"
            << "descriptorFormat=0;"
            << "descriptorUsageSampled=false;"
            << "hasAfterImport=false;"
            << "release=not_run;"
            << "releaseFence=-1;"
            << "hasAfterRelease=false;"
            << "shutdown=not_run;"
            << "idempotentShutdown=not_run;"
            << "proofBoundary=gles_ahb_rgba_import_acquire_fence_wait_close_no_yuv_no_release_fence_no_product;"
            << "lastError=hardware_buffer_from_jobject_failed";
        return env->NewStringUTF(oss.str().c_str());
    }

    vanguard::render::GlesBackend backend;

    // 1. Pre-init import: returns kBackendNotInitialized, handle=0, descriptor zeroed
    vanguard::render::HardwareBufferHandle hPre = 999;
    vanguard::render::HardwareBufferDescriptor descPre{1, 1, 1, 1, 1, 1};
    const auto preRes = backend.importHardwareBuffer(ahb, -1, &hPre, &descPre);
    const bool preDescZero = (descPre.width == 0 && descPre.height == 0 && descPre.layers == 0 &&
                              descPre.format == 0 && descPre.stride == 0 && descPre.usage == 0);
    const bool preInitCheckOk = (preRes == vanguard::render::HardwareBufferImportResult::kBackendNotInitialized) &&
                                (hPre == vanguard::render::kInvalidHardwareBufferHandle) &&
                                preDescZero;

    // 2. Initialize GlesBackend
    const bool initOk = backend.initialize();
    const int clientVersion = backend.clientVersion();
    const std::string vendor = SanitizeString(backend.diagnosticVendor());
    const std::string renderer = SanitizeString(backend.diagnosticRenderer());
    const std::string version = SanitizeString(backend.diagnosticVersion());
    const bool initCheckOk = initOk && backend.isInitialized() && (clientVersion >= 2) &&
                             !vendor.empty() && !renderer.empty() && !version.empty();

    // 3. Negative invalid-fd lane: create closed fd, verify wait fails, output zeroed, lastError set, no import active
    int pInvalid[2] = {-1, -1};
    int pipeInvRes = pipe(pInvalid);
    if (pipeInvRes == 0) {
        close(pInvalid[0]);
        close(pInvalid[1]);
    }
    const int invalidFd = pInvalid[0];
    vanguard::render::HardwareBufferHandle hInv = 999;
    vanguard::render::HardwareBufferDescriptor descInv{1, 1, 1, 1, 1, 1};
    const auto invRes = backend.importHardwareBuffer(ahb, invalidFd, &hInv, &descInv);
    const bool invalidFenceClosed = IsFdClosed(invalidFd);
    const bool invDescZero = (descInv.width == 0 && descInv.height == 0 && descInv.layers == 0 &&
                              descInv.format == 0 && descInv.stride == 0 && descInv.usage == 0);
    const std::string invLastError = SanitizeString(backend.lastError());
    const bool invalidFdCheckOk = (pipeInvRes == 0) &&
                                  (invRes == vanguard::render::HardwareBufferImportResult::kUnavailable) &&
                                  (hInv == vanguard::render::kInvalidHardwareBufferHandle) &&
                                  invDescZero &&
                                  (invLastError == "ahb_import_acquire_fence_wait_failed") &&
                                  invalidFenceClosed &&
                                  !backend.hasHardwareBuffer(hInv);

    // 4. Negative timeout lane: unwritten open pipe read fd times out (1000ms), output zeroed, read fd closed by import
    int pTimeout[2] = {-1, -1};
    int pipeTimeoutRes = pipe(pTimeout);
    const int timeoutReadFd = pTimeout[0];
    const int timeoutWriteFd = pTimeout[1];
    vanguard::render::HardwareBufferHandle hTimeout = 999;
    vanguard::render::HardwareBufferDescriptor descTimeout{1, 1, 1, 1, 1, 1};
    const auto timeoutRes = backend.importHardwareBuffer(ahb, timeoutReadFd, &hTimeout, &descTimeout);
    const bool timeoutReadFdClosed = IsFdClosed(timeoutReadFd);
    if (timeoutWriteFd >= 0) {
        close(timeoutWriteFd);
    }
    const bool timeoutDescZero = (descTimeout.width == 0 && descTimeout.height == 0 && descTimeout.layers == 0 &&
                                  descTimeout.format == 0 && descTimeout.stride == 0 && descTimeout.usage == 0);
    const std::string timeoutLastError = SanitizeString(backend.lastError());
    const bool timeoutCheckOk = (pipeTimeoutRes == 0) &&
                                (timeoutRes == vanguard::render::HardwareBufferImportResult::kUnavailable) &&
                                (hTimeout == vanguard::render::kInvalidHardwareBufferHandle) &&
                                timeoutDescZero &&
                                (timeoutLastError == "ahb_import_acquire_fence_wait_timeout") &&
                                timeoutReadFdClosed &&
                                !backend.hasHardwareBuffer(hTimeout);

    // 5. Positive acquire-fence lane: create real EGL native fence from current context, import AHB with fence
    EGLDisplay display = eglGetCurrentDisplay();
    auto fnCreateSyncKHR = reinterpret_cast<FnEGLCreateSyncKHR>(
        eglGetProcAddress("eglCreateSyncKHR"));
    auto fnDestroySyncKHR = reinterpret_cast<FnEGLDestroySyncKHR>(
        eglGetProcAddress("eglDestroySyncKHR"));
    auto fnDupNativeFenceFDANDROID = reinterpret_cast<FnEGLDupNativeFenceFDANDROID>(
        eglGetProcAddress("eglDupNativeFenceFDANDROID"));

    const bool symbolsResolved = (display != EGL_NO_DISPLAY) &&
                                 (fnCreateSyncKHR != nullptr) &&
                                 (fnDestroySyncKHR != nullptr) &&
                                 (fnDupNativeFenceFDANDROID != nullptr);

    bool signaledFenceCreateOk = false;
    bool signaledFenceDupOk = false;
    int signaledFenceFd = -1;
    bool validImportOk = false;
    bool signaledFdClosed = false;
    vanguard::render::HardwareBufferHandle handle = vanguard::render::kInvalidHardwareBufferHandle;
    vanguard::render::HardwareBufferDescriptor desc{};
    bool hasAfterImport = false;
    bool descOk = false;

    if (symbolsResolved) {
        const EGLint syncAttribs[] = {
            EGL_SYNC_NATIVE_FENCE_FD_ANDROID, EGL_NO_NATIVE_FENCE_FD_ANDROID,
            EGL_NONE
        };
        EGLSyncKHR sync = fnCreateSyncKHR(display, EGL_SYNC_NATIVE_FENCE_ANDROID, syncAttribs);
        if (sync != EGL_NO_SYNC_KHR) {
            signaledFenceCreateOk = true;
            glFlush();
            signaledFenceFd = fnDupNativeFenceFDANDROID(display, sync);
            fnDestroySyncKHR(display, sync);
            if (signaledFenceFd >= 0) {
                signaledFenceDupOk = true;
                const int fdToPass = signaledFenceFd;
                const auto importRes = backend.importHardwareBuffer(ahb, fdToPass, &handle, &desc);
                validImportOk = (importRes == vanguard::render::HardwareBufferImportResult::kSuccess) &&
                                (handle != vanguard::render::kInvalidHardwareBufferHandle);
                signaledFdClosed = IsFdClosed(fdToPass);
                descOk = (desc.width == static_cast<uint32_t>(width)) &&
                         (desc.height == static_cast<uint32_t>(height)) &&
                         (desc.layers == 1) &&
                         ((desc.usage & AHARDWAREBUFFER_USAGE_GPU_SAMPLED_IMAGE) != 0) &&
                         (desc.format != 0);
                hasAfterImport = backend.hasHardwareBuffer(handle);
            }
        }
    }

    const bool positiveCheckOk = symbolsResolved &&
                                 signaledFenceCreateOk &&
                                 signaledFenceDupOk &&
                                 validImportOk &&
                                 signaledFdClosed &&
                                 descOk &&
                                 hasAfterImport;

    // 6. Release handle: releaseFence=-1, has false
    int releaseFence = -999;
    const auto releaseRes = backend.releaseHardwareBuffer(handle, &releaseFence);
    const bool releaseOk = (releaseRes == vanguard::render::HardwareBufferImportResult::kSuccess) &&
                           (releaseFence == -1);
    const bool hasAfterRelease = backend.hasHardwareBuffer(handle);
    const bool releaseCheckOk = releaseOk && !hasAfterRelease;

    // 7. Shutdown and idempotent shutdown
    backend.shutdown();
    const bool hasAfterShutdown = backend.hasHardwareBuffer(handle);
    const bool isInitAfterShutdown = backend.isInitialized();

    backend.shutdown();
    const bool idempotentShutdownOk = !backend.hasHardwareBuffer(handle) && !backend.isInitialized();
    const bool shutdownCheckOk = !hasAfterShutdown && !isInitAfterShutdown && idempotentShutdownOk;

    // Overall check pass evaluation
    const bool allChecksPass = preInitCheckOk &&
                               initCheckOk &&
                               invalidFdCheckOk &&
                               timeoutCheckOk &&
                               positiveCheckOk &&
                               releaseCheckOk &&
                               shutdownCheckOk;

    const std::string backendLastError = SanitizeString(backend.lastError());

    std::ostringstream oss;
    oss << "status=" << (allChecksPass ? "PASS" : "FAIL") << ";"
        << "clientVersion=" << clientVersion << ";"
        << "vendor=" << vendor << ";"
        << "renderer=" << renderer << ";"
        << "version=" << version << ";"
        << "symbolsResolved=" << (symbolsResolved ? "true" : "false") << ";"
        << "nativeFenceExtension=" << (symbolsResolved ? "supported" : "unavailable") << ";"
        << "preInitImport=" << (preRes == vanguard::render::HardwareBufferImportResult::kBackendNotInitialized ? "rejected_as_expected" : "failed") << ";"
        << "preInitHandle=" << hPre << ";"
        << "preInitDescriptorZero=" << (preDescZero ? "true" : "false") << ";"
        << "initialize=" << (initCheckOk ? "success" : "failed") << ";"
        << "invalidFenceImport=" << (invRes == vanguard::render::HardwareBufferImportResult::kUnavailable ? "rejected_as_expected" : "failed") << ";"
        << "invalidFenceLastError=" << (invLastError.empty() ? "none" : invLastError) << ";"
        << "invalidFenceDescriptorZero=" << (invDescZero ? "true" : "false") << ";"
        << "invalidFenceHandle=" << hInv << ";"
        << "invalidFenceClosed=" << (invalidFenceClosed ? "true" : "false") << ";"
        << "timeoutImport=" << (timeoutRes == vanguard::render::HardwareBufferImportResult::kUnavailable ? "rejected_as_expected" : "failed") << ";"
        << "timeoutLastError=" << (timeoutLastError.empty() ? "none" : timeoutLastError) << ";"
        << "timeoutDescriptorZero=" << (timeoutDescZero ? "true" : "false") << ";"
        << "timeoutHandle=" << hTimeout << ";"
        << "timeoutFdClosed=" << (timeoutReadFdClosed ? "true" : "false") << ";"
        << "signaledFenceCreate=" << (signaledFenceCreateOk ? "success" : "failed") << ";"
        << "signaledFenceDup=" << (signaledFenceDupOk ? "success" : "failed") << ";"
        << "signaledFenceFd=" << signaledFenceFd << ";"
        << "signaledImport=" << (validImportOk ? "success" : "failed") << ";"
        << "signaledFdClosed=" << (signaledFdClosed ? "true" : "false") << ";"
        << "signaledHandle=" << handle << ";"
        << "descriptorWidth=" << desc.width << ";"
        << "descriptorHeight=" << desc.height << ";"
        << "descriptorLayers=" << desc.layers << ";"
        << "descriptorFormat=" << desc.format << ";"
        << "descriptorUsageSampled=" << (((desc.usage & AHARDWAREBUFFER_USAGE_GPU_SAMPLED_IMAGE) != 0) ? "true" : "false") << ";"
        << "hasAfterImport=" << (hasAfterImport ? "true" : "false") << ";"
        << "release=" << (releaseOk ? "success" : "failed") << ";"
        << "releaseFence=" << releaseFence << ";"
        << "hasAfterRelease=" << (hasAfterRelease ? "true" : "false") << ";"
        << "shutdown=" << (!hasAfterShutdown ? "success" : "failed") << ";"
        << "idempotentShutdown=" << (idempotentShutdownOk ? "success" : "failed") << ";"
        << "proofBoundary=gles_ahb_rgba_import_acquire_fence_wait_close_no_yuv_no_release_fence_no_product;"
        << "lastError=" << (backendLastError.empty() ? "none" : backendLastError);

    const std::string resultStr = oss.str();
    return env->NewStringUTF(resultStr.c_str());
}
