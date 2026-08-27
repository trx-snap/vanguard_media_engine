// Phase 1 Unit AJ: Android GLES EGL native-fence FD lifecycle physical proof JNI bridge.
//
// Android-only translation unit added via CMake target_sources block.
//
// JNI entry point:
//   runAndroidDagPhase1AJGlesNativeFenceFdSmoke -> jstring

#include <jni.h>
#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES2/gl2.h>
#include <GLES2/gl2ext.h>

#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
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

using FnEGLCreateSyncKHR =
    EGLSyncKHR (*)(EGLDisplay, EGLenum, const EGLint*);
using FnEGLDestroySyncKHR =
    EGLBoolean (*)(EGLDisplay, EGLSyncKHR);
using FnEGLDupNativeFenceFDANDROID =
    EGLint (*)(EGLDisplay, EGLSyncKHR);

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

} // namespace

extern "C" JNIEXPORT jstring JNICALL
Java_com_connects_vanguard_1media_1engine_bridge_VanguardNativeBridge_runAndroidDagPhase1AJGlesNativeFenceFdSmoke(
    JNIEnv* env,
    jobject /* this */) {

    vanguard::render::GlesBackend backend;

    // 1. Initialize GlesBackend
    const bool initOk = backend.initialize();
    const int clientVersion = backend.clientVersion();
    const std::string vendor = SanitizeString(backend.diagnosticVendor());
    const std::string renderer = SanitizeString(backend.diagnosticRenderer());
    const std::string version = SanitizeString(backend.diagnosticVersion());
    const bool initCheckOk = initOk && backend.isInitialized() && (clientVersion >= 2) &&
                             !vendor.empty() && !renderer.empty() && !version.empty();

    // 2. Display and extension function symbol resolution
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

    // 3. Native fence sync creation, glFlush, dup FD, wait/poll, close, destroy
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

    if (symbolsResolved) {
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

    // 4. Backend shutdown and idempotent shutdown
    backend.shutdown();
    const bool shutdownOk = !backend.isInitialized();

    backend.shutdown();
    const bool idempotentShutdownOk = !backend.isInitialized();

    // 5. Evaluate all checks
    const bool allChecksPass = initCheckOk &&
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
                               shutdownOk &&
                               idempotentShutdownOk;

    const std::string backendLastError = SanitizeString(backend.lastError());

    std::ostringstream oss;
    oss << "status=" << (allChecksPass ? "PASS" : "FAIL") << ";"
        << "clientVersion=" << clientVersion << ";"
        << "vendor=" << vendor << ";"
        << "renderer=" << renderer << ";"
        << "version=" << version << ";"
        << "initialize=" << (initCheckOk ? "success" : "failed") << ";"
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
        << "shutdown=" << (shutdownOk ? "success" : "failed") << ";"
        << "idempotentShutdown=" << (idempotentShutdownOk ? "success" : "failed") << ";"
        << "proofBoundary=gles_native_fence_fd_lifecycle_no_release_fence_production_no_import_no_product;"
        << "lastError=" << (backendLastError.empty() ? "none" : backendLastError);

    const std::string resultStr = oss.str();
    return env->NewStringUTF(resultStr.c_str());
}
