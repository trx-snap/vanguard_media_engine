// Unit U: Android GLES backend offscreen EGL lifecycle smoke JNI bridge.
//
// This translation unit is Android-only and must NOT be included in iOS or
// host builds. It is added via the Android-only target_sources block in
// src/CMakeLists.txt.
//
// JNI entry point (matching VanguardNativeBridge.kt Phase 1-Unit U declaration):
//   runAndroidDagPhase1UGlesBackendSmoke -> jstring

#include <jni.h>

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
