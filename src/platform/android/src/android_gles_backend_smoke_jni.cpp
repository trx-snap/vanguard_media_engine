// Unit U/V/W: Android GLES backend offscreen EGL lifecycle, window-surface attach/detach & clear/swap presentation smoke JNI bridge.
//
// This translation unit is Android-only and must NOT be included in iOS or
// host builds. It is added via the Android-only target_sources block in
// src/CMakeLists.txt.
//
// JNI entry points (matching VanguardNativeBridge.kt Phase 1-Unit U/V/W declarations):
//   runAndroidDagPhase1UGlesBackendSmoke -> jstring
//   runAndroidDagPhase1VGlesSurfaceSmoke -> jstring
//   runAndroidDagPhase1WGlesWindowPresentSmoke -> jstring

#include <jni.h>
#include <android/native_window_jni.h>

#include <algorithm>
#include <cstring>
#include <sstream>
#include <string>

#include "vanguard/render/gles_backend.h"

namespace {

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
Java_com_connects_vanguard_1media_1engine_bridge_VanguardNativeBridge_runAndroidDagPhase1UGlesBackendSmoke(
    JNIEnv* env,
    jobject /* this */) {

    vanguard::render::GlesBackend backend;

    // 1. Initial initialize()
    const bool init1Ok = backend.initialize();

    // 2. Idempotent initialize()
    const bool init2Ok = backend.initialize();

    // 3. Capture post-init state
    const bool isInitialized = backend.isInitialized();
    const int clientVersion = backend.clientVersion();
    const bool clearOk = backend.diagnosticClearSucceeded();
    const bool swapOk = backend.diagnosticSwapSucceeded();
    const std::string vendor = SanitizeString(backend.diagnosticVendor());
    const std::string renderer = SanitizeString(backend.diagnosticRenderer());
    const std::string version = SanitizeString(backend.diagnosticVersion());
    const std::string lastErrorAfterInit = SanitizeString(backend.lastError());
    const bool hasSurface = backend.hasSurface();

    // 4. Stubs validation (importHardwareBuffer & renderFrame)
    vanguard::render::HardwareBufferHandle handle = vanguard::render::kInvalidHardwareBufferHandle;
    vanguard::render::HardwareBufferDescriptor desc{};
    const auto importRes = backend.importHardwareBuffer(nullptr, -1, &handle, &desc);
    const bool importUnavailable = (importRes == vanguard::render::HardwareBufferImportResult::kUnavailable);

    const auto renderRes = backend.renderFrame(vanguard::render::kInvalidHardwareBufferHandle);
    const bool renderUnavailable = (renderRes == vanguard::render::RenderFrameResult::kUnavailable);

    // 5. Initial shutdown()
    backend.shutdown();
    const bool postShutdownInit = backend.isInitialized();
    const int postShutdownClientVersion = backend.clientVersion();
    const bool postShutdownClear = backend.diagnosticClearSucceeded();
    const bool postShutdownSwap = backend.diagnosticSwapSucceeded();
    const std::string postShutdownVendor = backend.diagnosticVendor();
    const std::string postShutdownRenderer = backend.diagnosticRenderer();
    const std::string postShutdownVersion = backend.diagnosticVersion();
    const bool shutdown1Ok = (!postShutdownInit &&
                              postShutdownClientVersion == 0 &&
                              !postShutdownClear &&
                              !postShutdownSwap &&
                              postShutdownVendor.empty() &&
                              postShutdownRenderer.empty() &&
                              postShutdownVersion.empty());

    // 6. Idempotent shutdown()
    backend.shutdown();
    const bool idempotentShutdownOk = (!backend.isInitialized() &&
                                       backend.clientVersion() == 0 &&
                                       !backend.diagnosticClearSucceeded() &&
                                       !backend.diagnosticSwapSucceeded() &&
                                       std::string(backend.diagnosticVendor()).empty() &&
                                       std::string(backend.diagnosticRenderer()).empty() &&
                                       std::string(backend.diagnosticVersion()).empty());

    // Evaluate overall pass
    const bool allChecksPass = init1Ok &&
                               init2Ok &&
                               isInitialized &&
                               (clientVersion >= 2) &&
                               clearOk &&
                               swapOk &&
                               !vendor.empty() &&
                               !renderer.empty() &&
                               !version.empty() &&
                               !hasSurface &&
                               importUnavailable &&
                               renderUnavailable &&
                               shutdown1Ok &&
                               idempotentShutdownOk;

    std::ostringstream oss;
    oss << "status=" << (allChecksPass ? "PASS" : "FAIL") << ";"
        << "clientVersion=" << clientVersion << ";"
        << "vendor=" << vendor << ";"
        << "renderer=" << renderer << ";"
        << "version=" << version << ";"
        << "initialize=" << (init1Ok ? "success" : "failed") << ";"
        << "idempotentInitialize=" << (init2Ok ? "success" : "failed") << ";"
        << "clear=" << (clearOk ? "success" : "failed") << ";"
        << "swap=" << (swapOk ? "success" : "failed") << ";"
        << "hasSurface=" << (hasSurface ? "true" : "false") << ";"
        << "import=" << (importUnavailable ? "unavailable" : "unexpected_result") << ";"
        << "renderFrame=" << (renderUnavailable ? "unavailable" : "unexpected_result") << ";"
        << "shutdown=" << (shutdown1Ok ? "success" : "failed") << ";"
        << "idempotentShutdown=" << (idempotentShutdownOk ? "success" : "failed") << ";"
        << "proofBoundary=offscreen_egl_pbuffer_no_window_surface;"
        << "lastError=" << (lastErrorAfterInit.empty() ? "none" : lastErrorAfterInit);

    const std::string resultStr = oss.str();
    return env->NewStringUTF(resultStr.c_str());
}

extern "C" JNIEXPORT jstring JNICALL
Java_com_connects_vanguard_1media_1engine_bridge_VanguardNativeBridge_runAndroidDagPhase1VGlesSurfaceSmoke(
    JNIEnv* env,
    jobject /* this */,
    jobject jsurface,
    jint width,
    jint height) {

    if (!jsurface || width <= 0 || height <= 0) {
        std::ostringstream oss;
        oss << "status=FAIL;"
            << "clientVersion=0;"
            << "vendor=;"
            << "renderer=;"
            << "version=;"
            << "initialSurfaceKind=none;"
            << "firstAttach=not_run;"
            << "hasSurfaceAfterAttach=false;"
            << "widthAfterAttach=0;"
            << "heightAfterAttach=0;"
            << "doubleAttach=not_run;"
            << "doubleAttachLastError=;"
            << "resize=not_run;"
            << "resizeLastError=;"
            << "hasSurfaceAfterResize=false;"
            << "detach=not_run;"
            << "surfaceKindAfterDetach=none;"
            << "widthAfterDetach=0;"
            << "heightAfterDetach=0;"
            << "reattach=not_run;"
            << "finalDetach=not_run;"
            << "shutdown=not_run;"
            << "idempotentShutdown=not_run;"
            << "import=not_run;"
            << "renderFrame=not_run;"
            << "proofBoundary=gles_window_surface_attach_detach_no_render;"
            << "lastError=invalid_arguments";
        return env->NewStringUTF(oss.str().c_str());
    }

    ANativeWindow* window = ANativeWindow_fromSurface(env, jsurface);
    if (!window) {
        std::ostringstream oss;
        oss << "status=FAIL;"
            << "clientVersion=0;"
            << "vendor=;"
            << "renderer=;"
            << "version=;"
            << "initialSurfaceKind=none;"
            << "firstAttach=not_run;"
            << "hasSurfaceAfterAttach=false;"
            << "widthAfterAttach=0;"
            << "heightAfterAttach=0;"
            << "doubleAttach=not_run;"
            << "doubleAttachLastError=;"
            << "resize=not_run;"
            << "resizeLastError=;"
            << "hasSurfaceAfterResize=false;"
            << "detach=not_run;"
            << "surfaceKindAfterDetach=none;"
            << "widthAfterDetach=0;"
            << "heightAfterDetach=0;"
            << "reattach=not_run;"
            << "finalDetach=not_run;"
            << "shutdown=not_run;"
            << "idempotentShutdown=not_run;"
            << "import=not_run;"
            << "renderFrame=not_run;"
            << "proofBoundary=gles_window_surface_attach_detach_no_render;"
            << "lastError=native_window_from_surface_failed";
        return env->NewStringUTF(oss.str().c_str());
    }

    vanguard::render::GlesBackend backend;

    // 1. Initial initialize()
    const bool initOk = backend.initialize();
    const bool isInitializedAfterInit = backend.isInitialized();
    const int clientVersion = backend.clientVersion();
    const std::string vendor = SanitizeString(backend.diagnosticVendor());
    const std::string renderer = SanitizeString(backend.diagnosticRenderer());
    const std::string version = SanitizeString(backend.diagnosticVersion());
    const bool hasSurfaceInitial = backend.hasSurface();
    const std::string initialSurfaceKind = SanitizeString(backend.activeSurfaceKind());
    const bool initCheckOk = initOk && isInitializedAfterInit && !hasSurfaceInitial &&
                             (initialSurfaceKind == "offscreen") && (clientVersion >= 2) &&
                             !vendor.empty() && !renderer.empty() && !version.empty();

    // 2. First attachSurface(window, width, height)
    const bool firstAttachOk = backend.attachSurface(window, static_cast<uint32_t>(width), static_cast<uint32_t>(height));
    const bool hasSurfaceAfterAttach = backend.hasSurface();
    const std::string surfaceKindAfterAttach = SanitizeString(backend.activeSurfaceKind());
    const uint32_t widthAfterAttach = backend.surfaceWidth();
    const uint32_t heightAfterAttach = backend.surfaceHeight();
    const bool firstAttachCheckOk = firstAttachOk && hasSurfaceAfterAttach &&
                                   (surfaceKindAfterAttach == "window") &&
                                   (widthAfterAttach == static_cast<uint32_t>(width)) &&
                                   (heightAfterAttach == static_cast<uint32_t>(height));

    // 3. Double attach while attached returns false; lastError surface_already_attached; original surface remains attached and dimensions unchanged.
    const bool doubleAttachResult = backend.attachSurface(window, static_cast<uint32_t>(width), static_cast<uint32_t>(height));
    const std::string doubleAttachLastError = SanitizeString(backend.lastError());
    const bool hasSurfaceAfterDoubleAttach = backend.hasSurface();
    const uint32_t widthAfterDoubleAttach = backend.surfaceWidth();
    const uint32_t heightAfterDoubleAttach = backend.surfaceHeight();
    const bool doubleAttachCheckOk = !doubleAttachResult &&
                                    (doubleAttachLastError == "surface_already_attached") &&
                                    hasSurfaceAfterDoubleAttach &&
                                    (widthAfterDoubleAttach == static_cast<uint32_t>(width)) &&
                                    (heightAfterDoubleAttach == static_cast<uint32_t>(height));

    // 4. resizeSurface(width+16, height+16) returns false; lastError resize_requires_reattach; original surface remains attached and dimensions unchanged.
    const bool resizeResult = backend.resizeSurface(static_cast<uint32_t>(width + 16), static_cast<uint32_t>(height + 16));
    const std::string resizeLastError = SanitizeString(backend.lastError());
    const bool hasSurfaceAfterResize = backend.hasSurface();
    const uint32_t widthAfterResize = backend.surfaceWidth();
    const uint32_t heightAfterResize = backend.surfaceHeight();
    const bool resizeCheckOk = !resizeResult &&
                               (resizeLastError == "resize_requires_reattach") &&
                               hasSurfaceAfterResize &&
                               (widthAfterResize == static_cast<uint32_t>(width)) &&
                               (heightAfterResize == static_cast<uint32_t>(height));

    // 5. detachSurface() makes hasSurface false, activeSurfaceKind offscreen, dimensions 0, isInitialized true.
    backend.detachSurface();
    const bool hasSurfaceAfterDetach = backend.hasSurface();
    const std::string surfaceKindAfterDetach = SanitizeString(backend.activeSurfaceKind());
    const uint32_t widthAfterDetach = backend.surfaceWidth();
    const uint32_t heightAfterDetach = backend.surfaceHeight();
    const bool isInitAfterDetach = backend.isInitialized();
    const bool detachCheckOk = !hasSurfaceAfterDetach &&
                               (surfaceKindAfterDetach == "offscreen") &&
                               (widthAfterDetach == 0) &&
                               (heightAfterDetach == 0) &&
                               isInitAfterDetach;

    // 6. Reattach after detach succeeds
    const bool reattachOk = backend.attachSurface(window, static_cast<uint32_t>(width), static_cast<uint32_t>(height));
    const bool hasSurfaceAfterReattach = backend.hasSurface();
    const std::string surfaceKindAfterReattach = SanitizeString(backend.activeSurfaceKind());
    const uint32_t widthAfterReattach = backend.surfaceWidth();
    const uint32_t heightAfterReattach = backend.surfaceHeight();
    const bool reattachCheckOk = reattachOk &&
                                 hasSurfaceAfterReattach &&
                                 (surfaceKindAfterReattach == "window") &&
                                 (widthAfterReattach == static_cast<uint32_t>(width)) &&
                                 (heightAfterReattach == static_cast<uint32_t>(height));

    // 7. Final detach succeeds
    backend.detachSurface();
    const bool hasSurfaceAfterFinalDetach = backend.hasSurface();
    const std::string surfaceKindAfterFinalDetach = SanitizeString(backend.activeSurfaceKind());
    const uint32_t widthAfterFinalDetach = backend.surfaceWidth();
    const uint32_t heightAfterFinalDetach = backend.surfaceHeight();
    const bool finalDetachCheckOk = !hasSurfaceAfterFinalDetach &&
                                    (surfaceKindAfterFinalDetach == "offscreen") &&
                                    (widthAfterFinalDetach == 0) &&
                                    (heightAfterFinalDetach == 0);

    // 8. Shutdown clears initialized state and activeSurfaceKind none; second shutdown safe.
    backend.shutdown();
    const bool postShutdownInit = backend.isInitialized();
    const std::string postShutdownSurfaceKind = SanitizeString(backend.activeSurfaceKind());
    const bool postShutdownHasSurface = backend.hasSurface();
    const uint32_t postShutdownWidth = backend.surfaceWidth();
    const uint32_t postShutdownHeight = backend.surfaceHeight();
    const bool shutdown1Ok = !postShutdownInit &&
                             (postShutdownSurfaceKind == "none") &&
                             !postShutdownHasSurface &&
                             (postShutdownWidth == 0) &&
                             (postShutdownHeight == 0);

    backend.shutdown();
    const bool idempotentShutdownOk = !backend.isInitialized() &&
                                       (std::string(backend.activeSurfaceKind()) == "none") &&
                                       !backend.hasSurface() &&
                                       (backend.surfaceWidth() == 0) &&
                                       (backend.surfaceHeight() == 0);

    // 9. Stubs validation: renderFrame(kInvalidHardwareBufferHandle) remains kUnavailable and importHardwareBuffer(nullptr,-1,...) remains kUnavailable.
    vanguard::render::HardwareBufferHandle handle = vanguard::render::kInvalidHardwareBufferHandle;
    vanguard::render::HardwareBufferDescriptor desc{};
    const auto importRes = backend.importHardwareBuffer(nullptr, -1, &handle, &desc);
    const bool importUnavailable = (importRes == vanguard::render::HardwareBufferImportResult::kUnavailable);

    const auto renderRes = backend.renderFrame(vanguard::render::kInvalidHardwareBufferHandle);
    const bool renderUnavailable = (renderRes == vanguard::render::RenderFrameResult::kUnavailable);

    // Release ANativeWindow reference owned by JNI harness
    ANativeWindow_release(window);

    const bool allChecksPass = initCheckOk &&
                               firstAttachCheckOk &&
                               doubleAttachCheckOk &&
                               resizeCheckOk &&
                               detachCheckOk &&
                               reattachCheckOk &&
                               finalDetachCheckOk &&
                               shutdown1Ok &&
                               idempotentShutdownOk &&
                               importUnavailable &&
                               renderUnavailable;

    const std::string backendLastError = SanitizeString(backend.lastError());

    std::ostringstream oss;
    oss << "status=" << (allChecksPass ? "PASS" : "FAIL") << ";"
        << "clientVersion=" << clientVersion << ";"
        << "vendor=" << vendor << ";"
        << "renderer=" << renderer << ";"
        << "version=" << version << ";"
        << "initialSurfaceKind=" << initialSurfaceKind << ";"
        << "firstAttach=" << (firstAttachOk ? "success" : "failed") << ";"
        << "hasSurfaceAfterAttach=" << (hasSurfaceAfterAttach ? "true" : "false") << ";"
        << "widthAfterAttach=" << widthAfterAttach << ";"
        << "heightAfterAttach=" << heightAfterAttach << ";"
        << "doubleAttach=" << (doubleAttachResult ? "unexpected_success" : "rejected_as_expected") << ";"
        << "doubleAttachLastError=" << doubleAttachLastError << ";"
        << "resize=" << (resizeResult ? "unexpected_success" : "rejected_as_expected") << ";"
        << "resizeLastError=" << resizeLastError << ";"
        << "hasSurfaceAfterResize=" << (hasSurfaceAfterResize ? "true" : "false") << ";"
        << "detach=" << (detachCheckOk ? "success" : "failed") << ";"
        << "surfaceKindAfterDetach=" << surfaceKindAfterDetach << ";"
        << "widthAfterDetach=" << widthAfterDetach << ";"
        << "heightAfterDetach=" << heightAfterDetach << ";"
        << "reattach=" << (reattachOk ? "success" : "failed") << ";"
        << "finalDetach=" << (finalDetachCheckOk ? "success" : "failed") << ";"
        << "shutdown=" << (shutdown1Ok ? "success" : "failed") << ";"
        << "idempotentShutdown=" << (idempotentShutdownOk ? "success" : "failed") << ";"
        << "import=" << (importUnavailable ? "unavailable" : "unexpected_result") << ";"
        << "renderFrame=" << (renderUnavailable ? "unavailable" : "unexpected_result") << ";"
        << "proofBoundary=gles_window_surface_attach_detach_no_render;"
        << "lastError=" << (backendLastError.empty() ? "none" : backendLastError);

    const std::string resultStr = oss.str();
    return env->NewStringUTF(resultStr.c_str());
}

extern "C" JNIEXPORT jstring JNICALL
Java_com_connects_vanguard_1media_1engine_bridge_VanguardNativeBridge_runAndroidDagPhase1WGlesWindowPresentSmoke(
    JNIEnv* env,
    jobject /* this */,
    jobject jsurface,
    jint width,
    jint height) {

    if (!jsurface || width <= 0 || height <= 0) {
        std::ostringstream oss;
        oss << "status=FAIL;"
            << "clientVersion=0;"
            << "vendor=;"
            << "renderer=;"
            << "version=;"
            << "preAttachPresent=not_run;"
            << "preAttachLastError=;"
            << "attach=not_run;"
            << "firstPresent=not_run;"
            << "secondPresent=not_run;"
            << "invalidColorPresent=not_run;"
            << "invalidColorLastError=;"
            << "hasSurfaceAfterPresent=false;"
            << "surfaceKindAfterPresent=none;"
            << "widthAfterPresent=0;"
            << "heightAfterPresent=0;"
            << "detach=not_run;"
            << "surfaceKindAfterDetach=none;"
            << "shutdown=not_run;"
            << "idempotentShutdown=not_run;"
            << "import=not_run;"
            << "renderFrame=not_run;"
            << "proofBoundary=gles_window_clear_swap_no_import_no_renderFrame;"
            << "lastError=invalid_arguments";
        return env->NewStringUTF(oss.str().c_str());
    }

    ANativeWindow* window = ANativeWindow_fromSurface(env, jsurface);
    if (!window) {
        std::ostringstream oss;
        oss << "status=FAIL;"
            << "clientVersion=0;"
            << "vendor=;"
            << "renderer=;"
            << "version=;"
            << "preAttachPresent=not_run;"
            << "preAttachLastError=;"
            << "attach=not_run;"
            << "firstPresent=not_run;"
            << "secondPresent=not_run;"
            << "invalidColorPresent=not_run;"
            << "invalidColorLastError=;"
            << "hasSurfaceAfterPresent=false;"
            << "surfaceKindAfterPresent=none;"
            << "widthAfterPresent=0;"
            << "heightAfterPresent=0;"
            << "detach=not_run;"
            << "surfaceKindAfterDetach=none;"
            << "shutdown=not_run;"
            << "idempotentShutdown=not_run;"
            << "import=not_run;"
            << "renderFrame=not_run;"
            << "proofBoundary=gles_window_clear_swap_no_import_no_renderFrame;"
            << "lastError=native_window_from_surface_failed";
        return env->NewStringUTF(oss.str().c_str());
    }

    vanguard::render::GlesBackend backend;

    // 1. Initial initialize()
    const bool initOk = backend.initialize();
    const bool isInitializedAfterInit = backend.isInitialized();
    const int clientVersion = backend.clientVersion();
    const std::string vendor = SanitizeString(backend.diagnosticVendor());
    const std::string renderer = SanitizeString(backend.diagnosticRenderer());
    const std::string version = SanitizeString(backend.diagnosticVersion());

    // 2. Pre-attach diagnosticPresentWindowClear(0, 0, 0, 1) returns false with lastError "no_surface_attached"
    const bool preAttachPresent = backend.diagnosticPresentWindowClear(0.0f, 0.0f, 0.0f, 1.0f);
    const std::string preAttachLastError = SanitizeString(backend.lastError());
    const bool preAttachCheckOk = !preAttachPresent && (preAttachLastError == "no_surface_attached");

    // 3. attachSurface(window, width, height) succeeds; surface kind "window", hasSurface true, dimensions match
    const bool attachOk = backend.attachSurface(window, static_cast<uint32_t>(width), static_cast<uint32_t>(height));
    const bool hasSurfaceAfterAttach = backend.hasSurface();
    const std::string surfaceKindAfterAttach = SanitizeString(backend.activeSurfaceKind());
    const uint32_t widthAfterAttach = backend.surfaceWidth();
    const uint32_t heightAfterAttach = backend.surfaceHeight();
    const bool attachCheckOk = attachOk && hasSurfaceAfterAttach &&
                               (surfaceKindAfterAttach == "window") &&
                               (widthAfterAttach == static_cast<uint32_t>(width)) &&
                               (heightAfterAttach == static_cast<uint32_t>(height));

    // 4. First diagnosticPresentWindowClear(0, 0, 0, 1) succeeds; surface remains attached, kind "window", dimensions match, lastError none
    const bool firstPresentOk = backend.diagnosticPresentWindowClear(0.0f, 0.0f, 0.0f, 1.0f);
    const std::string firstPresentLastError = SanitizeString(backend.lastError());
    const bool hasSurfaceAfterFirstPresent = backend.hasSurface();
    const std::string surfaceKindAfterFirstPresent = SanitizeString(backend.activeSurfaceKind());
    const uint32_t widthAfterFirstPresent = backend.surfaceWidth();
    const uint32_t heightAfterFirstPresent = backend.surfaceHeight();
    const bool firstPresentCheckOk = firstPresentOk &&
                                     (firstPresentLastError.empty() || firstPresentLastError == "none") &&
                                     hasSurfaceAfterFirstPresent &&
                                     (surfaceKindAfterFirstPresent == "window") &&
                                     (widthAfterFirstPresent == static_cast<uint32_t>(width)) &&
                                     (heightAfterFirstPresent == static_cast<uint32_t>(height));

    // 5. Second diagnosticPresentWindowClear(0.15, 0.35, 0.65, 1) succeeds; surface remains attached, dimensions match
    const bool secondPresentOk = backend.diagnosticPresentWindowClear(0.15f, 0.35f, 0.65f, 1.0f);
    const std::string secondPresentLastError = SanitizeString(backend.lastError());
    const bool hasSurfaceAfterSecondPresent = backend.hasSurface();
    const std::string surfaceKindAfterSecondPresent = SanitizeString(backend.activeSurfaceKind());
    const uint32_t widthAfterSecondPresent = backend.surfaceWidth();
    const uint32_t heightAfterSecondPresent = backend.surfaceHeight();
    const bool secondPresentCheckOk = secondPresentOk &&
                                      (secondPresentLastError.empty() || secondPresentLastError == "none") &&
                                      hasSurfaceAfterSecondPresent &&
                                      (surfaceKindAfterSecondPresent == "window") &&
                                      (widthAfterSecondPresent == static_cast<uint32_t>(width)) &&
                                      (heightAfterSecondPresent == static_cast<uint32_t>(height));

    // 6. Invalid color diagnosticPresentWindowClear(-1, 0, 0, 1) returns false with lastError "invalid_clear_color"; surface remains attached
    const bool invalidColorPresent = backend.diagnosticPresentWindowClear(-1.0f, 0.0f, 0.0f, 1.0f);
    const std::string invalidColorLastError = SanitizeString(backend.lastError());
    const bool hasSurfaceAfterInvalid = backend.hasSurface();
    const std::string surfaceKindAfterInvalid = SanitizeString(backend.activeSurfaceKind());
    const uint32_t widthAfterInvalid = backend.surfaceWidth();
    const uint32_t heightAfterInvalid = backend.surfaceHeight();
    const bool invalidColorCheckOk = !invalidColorPresent &&
                                     (invalidColorLastError == "invalid_clear_color") &&
                                     hasSurfaceAfterInvalid &&
                                     (surfaceKindAfterInvalid == "window") &&
                                     (widthAfterInvalid == static_cast<uint32_t>(width)) &&
                                     (heightAfterInvalid == static_cast<uint32_t>(height));

    // 7. detachSurface() makes hasSurface false, activeSurfaceKind offscreen, dimensions 0, isInitialized true
    backend.detachSurface();
    const bool hasSurfaceAfterDetach = backend.hasSurface();
    const std::string surfaceKindAfterDetach = SanitizeString(backend.activeSurfaceKind());
    const uint32_t widthAfterDetach = backend.surfaceWidth();
    const uint32_t heightAfterDetach = backend.surfaceHeight();
    const bool isInitAfterDetach = backend.isInitialized();
    const bool detachCheckOk = !hasSurfaceAfterDetach &&
                               (surfaceKindAfterDetach == "offscreen") &&
                               (widthAfterDetach == 0) &&
                               (heightAfterDetach == 0) &&
                               isInitAfterDetach;

    // 8. Shutdown clears initialized state and activeSurfaceKind "none"; idempotent shutdown safe
    backend.shutdown();
    const bool postShutdownInit = backend.isInitialized();
    const std::string postShutdownSurfaceKind = SanitizeString(backend.activeSurfaceKind());
    const bool postShutdownHasSurface = backend.hasSurface();
    const uint32_t postShutdownWidth = backend.surfaceWidth();
    const uint32_t postShutdownHeight = backend.surfaceHeight();
    const bool shutdown1Ok = !postShutdownInit &&
                             (postShutdownSurfaceKind == "none") &&
                             !postShutdownHasSurface &&
                             (postShutdownWidth == 0) &&
                             (postShutdownHeight == 0);

    backend.shutdown();
    const bool idempotentShutdownOk = !backend.isInitialized() &&
                                       (std::string(backend.activeSurfaceKind()) == "none") &&
                                       !backend.hasSurface() &&
                                       (backend.surfaceWidth() == 0) &&
                                       (backend.surfaceHeight() == 0);

    // 9. Stubs validation: importHardwareBuffer(nullptr, -1, ...) and renderFrame(kInvalidHardwareBufferHandle) remain kUnavailable
    vanguard::render::HardwareBufferHandle handle = vanguard::render::kInvalidHardwareBufferHandle;
    vanguard::render::HardwareBufferDescriptor desc{};
    const auto importRes = backend.importHardwareBuffer(nullptr, -1, &handle, &desc);
    const bool importUnavailable = (importRes == vanguard::render::HardwareBufferImportResult::kUnavailable);

    const auto renderRes = backend.renderFrame(vanguard::render::kInvalidHardwareBufferHandle);
    const bool renderUnavailable = (renderRes == vanguard::render::RenderFrameResult::kUnavailable);

    // Release ANativeWindow reference owned by JNI harness
    ANativeWindow_release(window);

    const bool allChecksPass = initOk &&
                               isInitializedAfterInit &&
                               (clientVersion >= 2) &&
                               !vendor.empty() &&
                               !renderer.empty() &&
                               !version.empty() &&
                               preAttachCheckOk &&
                               attachCheckOk &&
                               firstPresentCheckOk &&
                               secondPresentCheckOk &&
                               invalidColorCheckOk &&
                               detachCheckOk &&
                               shutdown1Ok &&
                               idempotentShutdownOk &&
                               importUnavailable &&
                               renderUnavailable;

    const std::string backendLastError = SanitizeString(backend.lastError());

    std::ostringstream oss;
    oss << "status=" << (allChecksPass ? "PASS" : "FAIL") << ";"
        << "clientVersion=" << clientVersion << ";"
        << "vendor=" << vendor << ";"
        << "renderer=" << renderer << ";"
        << "version=" << version << ";"
        << "preAttachPresent=" << (preAttachPresent ? "unexpected_success" : "rejected_as_expected") << ";"
        << "preAttachLastError=" << preAttachLastError << ";"
        << "attach=" << (attachOk ? "success" : "failed") << ";"
        << "firstPresent=" << (firstPresentOk ? "success" : "failed") << ";"
        << "secondPresent=" << (secondPresentOk ? "success" : "failed") << ";"
        << "invalidColorPresent=" << (invalidColorPresent ? "unexpected_success" : "rejected_as_expected") << ";"
        << "invalidColorLastError=" << invalidColorLastError << ";"
        << "hasSurfaceAfterPresent=" << (hasSurfaceAfterSecondPresent ? "true" : "false") << ";"
        << "surfaceKindAfterPresent=" << surfaceKindAfterSecondPresent << ";"
        << "widthAfterPresent=" << widthAfterSecondPresent << ";"
        << "heightAfterPresent=" << heightAfterSecondPresent << ";"
        << "detach=" << (detachCheckOk ? "success" : "failed") << ";"
        << "surfaceKindAfterDetach=" << surfaceKindAfterDetach << ";"
        << "shutdown=" << (shutdown1Ok ? "success" : "failed") << ";"
        << "idempotentShutdown=" << (idempotentShutdownOk ? "success" : "failed") << ";"
        << "import=" << (importUnavailable ? "unavailable" : "unexpected_result") << ";"
        << "renderFrame=" << (renderUnavailable ? "unavailable" : "unexpected_result") << ";"
        << "proofBoundary=gles_window_clear_swap_no_import_no_renderFrame;"
        << "lastError=" << (backendLastError.empty() ? "none" : backendLastError);

    const std::string resultStr = oss.str();
    return env->NewStringUTF(resultStr.c_str());
}
