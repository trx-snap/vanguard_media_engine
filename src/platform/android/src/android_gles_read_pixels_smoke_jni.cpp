// Phase 1 Unit AB: Android GLES diagnostic read-pixels physical smoke JNI bridge.
//
// Android-only translation unit added via CMake target_sources block.
//
// JNI entry point:
//   runAndroidDagPhase1ABGlesReadPixelsSmoke -> jstring

#include <jni.h>
#include <android/native_window_jni.h>
#include <GLES2/gl2.h>

#include <cmath>
#include <cstdint>
#include <cstdlib>
#include <sstream>
#include <string>
#include <vector>

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
Java_com_connects_vanguard_1media_1engine_bridge_VanguardNativeBridge_runAndroidDagPhase1ABGlesReadPixelsSmoke(
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
            << "preInitRead=not_run;"
            << "preInitLastError=;"
            << "initialize=not_run;"
            << "preAttachRead=not_run;"
            << "preAttachLastError=;"
            << "attach=not_run;"
            << "hasSurfaceAfterAttach=false;"
            << "surfaceKindAfterAttach=none;"
            << "widthAfterAttach=0;"
            << "heightAfterAttach=0;"
            << "nullRead=not_run;"
            << "nullReadLastError=;"
            << "zeroRead=not_run;"
            << "zeroReadLastError=;"
            << "smallCapacityRead=not_run;"
            << "smallCapacityLastError=;"
            << "outOfBoundsRead=not_run;"
            << "outOfBoundsLastError=;"
            << "directClearForReadback=not_run;"
            << "centerRead=not_run;"
            << "centerReadLastError=;"
            << "centerR=0;"
            << "centerG=0;"
            << "centerB=0;"
            << "centerA=0;"
            << "centerPixelMatches=false;"
            << "fullRead=not_run;"
            << "fullReadLastError=;"
            << "detach=not_run;"
            << "surfaceKindAfterDetach=none;"
            << "postDetachRead=not_run;"
            << "postDetachLastError=;"
            << "shutdown=not_run;"
            << "idempotentShutdown=not_run;"
            << "proofBoundary=gles_diagnostic_read_pixels_rgba_window_surface_no_yuv_no_fence_no_product;"
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
            << "preInitRead=not_run;"
            << "preInitLastError=;"
            << "initialize=not_run;"
            << "preAttachRead=not_run;"
            << "preAttachLastError=;"
            << "attach=not_run;"
            << "hasSurfaceAfterAttach=false;"
            << "surfaceKindAfterAttach=none;"
            << "widthAfterAttach=0;"
            << "heightAfterAttach=0;"
            << "nullRead=not_run;"
            << "nullReadLastError=;"
            << "zeroRead=not_run;"
            << "zeroReadLastError=;"
            << "smallCapacityRead=not_run;"
            << "smallCapacityLastError=;"
            << "outOfBoundsRead=not_run;"
            << "outOfBoundsLastError=;"
            << "directClearForReadback=not_run;"
            << "centerRead=not_run;"
            << "centerReadLastError=;"
            << "centerR=0;"
            << "centerG=0;"
            << "centerB=0;"
            << "centerA=0;"
            << "centerPixelMatches=false;"
            << "fullRead=not_run;"
            << "fullReadLastError=;"
            << "detach=not_run;"
            << "surfaceKindAfterDetach=none;"
            << "postDetachRead=not_run;"
            << "postDetachLastError=;"
            << "shutdown=not_run;"
            << "idempotentShutdown=not_run;"
            << "proofBoundary=gles_diagnostic_read_pixels_rgba_window_surface_no_yuv_no_fence_no_product;"
            << "lastError=native_window_from_surface_failed";
        return env->NewStringUTF(oss.str().c_str());
    }

    vanguard::render::GlesBackend backend;
    std::vector<uint8_t> dummyBuffer(4, 0);

    // 1. preInitRead: expect false with lastError backend_not_initialized
    const bool preInitReadRes = backend.diagnosticReadPixels(0, 0, 1, 1, dummyBuffer.data(), 4);
    const std::string preInitLastError = SanitizeString(backend.lastError());
    const bool preInitReadOk = (!preInitReadRes && preInitLastError == "backend_not_initialized");

    // 2. initialize: expect true, clientVersion >= 2, non-empty vendor/renderer/version
    const bool initOk = backend.initialize();
    const bool isInitialized = backend.isInitialized();
    const int clientVersion = backend.clientVersion();
    const std::string vendor = SanitizeString(backend.diagnosticVendor());
    const std::string renderer = SanitizeString(backend.diagnosticRenderer());
    const std::string version = SanitizeString(backend.diagnosticVersion());
    const bool initCheckOk = initOk && isInitialized && (clientVersion >= 2) &&
                             !vendor.empty() && !renderer.empty() && !version.empty();

    // 3. preAttachRead: expect false with lastError no_surface_attached
    const bool preAttachReadRes = backend.diagnosticReadPixels(0, 0, 1, 1, dummyBuffer.data(), 4);
    const std::string preAttachLastError = SanitizeString(backend.lastError());
    const bool preAttachReadOk = (!preAttachReadRes && preAttachLastError == "no_surface_attached");

    // 4. attach: convert Surface to ANativeWindow and attachSurface; expect hasSurface true, kind window, dims match
    const bool attachOk = backend.attachSurface(window, static_cast<uint32_t>(width), static_cast<uint32_t>(height));
    const bool hasSurfaceAfterAttach = backend.hasSurface();
    const std::string surfaceKindAfterAttach = SanitizeString(backend.activeSurfaceKind());
    const uint32_t widthAfterAttach = backend.surfaceWidth();
    const uint32_t heightAfterAttach = backend.surfaceHeight();
    const bool attachCheckOk = attachOk && hasSurfaceAfterAttach &&
                               (surfaceKindAfterAttach == "window") &&
                               (widthAfterAttach == static_cast<uint32_t>(width)) &&
                               (heightAfterAttach == static_cast<uint32_t>(height));

    // 5. nullRead: expect false with lastError diagnostic_read_pixels_invalid_argument
    const bool nullReadRes = backend.diagnosticReadPixels(0, 0, 1, 1, nullptr, 4);
    const std::string nullReadLastError = SanitizeString(backend.lastError());
    const bool nullReadOk = (!nullReadRes && nullReadLastError == "diagnostic_read_pixels_invalid_argument");

    // 6. zeroRead: expect false with lastError diagnostic_read_pixels_invalid_dimensions
    const bool zeroReadRes = backend.diagnosticReadPixels(0, 0, 0, 1, dummyBuffer.data(), 4);
    const std::string zeroReadLastError = SanitizeString(backend.lastError());
    const bool zeroReadOk = (!zeroReadRes && zeroReadLastError == "diagnostic_read_pixels_invalid_dimensions");

    // 7. smallCapacityRead: expect false with lastError diagnostic_read_pixels_capacity_too_small
    const bool smallCapRes = backend.diagnosticReadPixels(0, 0, 1, 1, dummyBuffer.data(), 3);
    const std::string smallCapLastError = SanitizeString(backend.lastError());
    const bool smallCapOk = (!smallCapRes && smallCapLastError == "diagnostic_read_pixels_capacity_too_small");

    // 8. outOfBoundsRead: expect false with lastError diagnostic_read_pixels_out_of_bounds
    const bool oobRes = backend.diagnosticReadPixels(
        static_cast<uint32_t>(width),
        static_cast<uint32_t>(height),
        1, 1,
        dummyBuffer.data(),
        4);
    const std::string oobLastError = SanitizeString(backend.lastError());
    const bool oobOk = (!oobRes && oobLastError == "diagnostic_read_pixels_out_of_bounds");

    // 9. directClearForReadback: direct GLES clear to RGBA approx (64,128,191,255) without swapping
    glViewport(0, 0, static_cast<GLsizei>(width), static_cast<GLsizei>(height));
    glClearColor(64.0f / 255.0f, 128.0f / 255.0f, 191.0f / 255.0f, 1.0f);
    glClear(GL_COLOR_BUFFER_BIT);
    const GLenum glErr = glGetError();
    const bool directClearOk = (glErr == GL_NO_ERROR);

    // 10. centerRead: 1x1 read at (width/2, height/2)
    std::vector<uint8_t> centerPixel(4, 0);
    const bool centerReadRes = backend.diagnosticReadPixels(
        static_cast<uint32_t>(width / 2),
        static_cast<uint32_t>(height / 2),
        1, 1,
        centerPixel.data(),
        4);
    const std::string centerReadLastError = SanitizeString(backend.lastError());
    const bool centerReadOk = centerReadRes && centerReadLastError.empty();

    // 11. centerPixel: check tolerance <= 8 for RGB and alpha >= 240
    const int centerR = static_cast<int>(centerPixel[0]);
    const int centerG = static_cast<int>(centerPixel[1]);
    const int centerB = static_cast<int>(centerPixel[2]);
    const int centerA = static_cast<int>(centerPixel[3]);
    const bool centerPixelMatches = (std::abs(centerR - 64) <= 8) &&
                                    (std::abs(centerG - 128) <= 8) &&
                                    (std::abs(centerB - 191) <= 8) &&
                                    (centerA >= 240);

    // 12. fullRead: full surface readback
    std::vector<uint8_t> fullPixels(static_cast<size_t>(width) * static_cast<size_t>(height) * 4, 0);
    const bool fullReadRes = backend.diagnosticReadPixels(
        0, 0,
        static_cast<uint32_t>(width),
        static_cast<uint32_t>(height),
        fullPixels.data(),
        static_cast<uint64_t>(fullPixels.size()));
    const std::string fullReadLastError = SanitizeString(backend.lastError());
    const bool fullReadOk = fullReadRes && fullReadLastError.empty();

    // 13. detach & postDetachRead: detach surface and verify subsequent read fails
    backend.detachSurface();
    const bool hasSurfaceAfterDetach = backend.hasSurface();
    const std::string surfaceKindAfterDetach = SanitizeString(backend.activeSurfaceKind());
    const bool detachOk = !hasSurfaceAfterDetach && (surfaceKindAfterDetach == "offscreen");

    const bool postDetachReadRes = backend.diagnosticReadPixels(0, 0, 1, 1, dummyBuffer.data(), 4);
    const std::string postDetachLastError = SanitizeString(backend.lastError());
    const bool postDetachReadOk = (!postDetachReadRes && postDetachLastError == "no_surface_attached");

    // 14. shutdown & idempotentShutdown
    backend.shutdown();
    const bool shutdownOk = (!backend.isInitialized() &&
                             backend.clientVersion() == 0 &&
                             std::string(backend.activeSurfaceKind()) == "none" &&
                             !backend.hasSurface() &&
                             backend.surfaceWidth() == 0 &&
                             backend.surfaceHeight() == 0);

    backend.shutdown();
    const bool idempotentShutdownOk = (!backend.isInitialized() &&
                                       backend.clientVersion() == 0 &&
                                       std::string(backend.activeSurfaceKind()) == "none" &&
                                       !backend.hasSurface() &&
                                       backend.surfaceWidth() == 0 &&
                                       backend.surfaceHeight() == 0);

    // Release ANativeWindow reference
    ANativeWindow_release(window);

    const bool allChecksPass = preInitReadOk &&
                               initCheckOk &&
                               preAttachReadOk &&
                               attachCheckOk &&
                               nullReadOk &&
                               zeroReadOk &&
                               smallCapOk &&
                               oobOk &&
                               directClearOk &&
                               centerReadOk &&
                               centerPixelMatches &&
                               fullReadOk &&
                               detachOk &&
                               postDetachReadOk &&
                               shutdownOk &&
                               idempotentShutdownOk;

    const std::string backendLastError = SanitizeString(backend.lastError());

    std::ostringstream oss;
    oss << "status=" << (allChecksPass ? "PASS" : "FAIL") << ";"
        << "clientVersion=" << clientVersion << ";"
        << "vendor=" << vendor << ";"
        << "renderer=" << renderer << ";"
        << "version=" << version << ";"
        << "preInitRead=" << (preInitReadOk ? "rejected_as_expected" : "failed") << ";"
        << "preInitLastError=" << preInitLastError << ";"
        << "initialize=" << (initCheckOk ? "success" : "failed") << ";"
        << "preAttachRead=" << (preAttachReadOk ? "rejected_as_expected" : "failed") << ";"
        << "preAttachLastError=" << preAttachLastError << ";"
        << "attach=" << (attachCheckOk ? "success" : "failed") << ";"
        << "hasSurfaceAfterAttach=" << (hasSurfaceAfterAttach ? "true" : "false") << ";"
        << "surfaceKindAfterAttach=" << surfaceKindAfterAttach << ";"
        << "widthAfterAttach=" << widthAfterAttach << ";"
        << "heightAfterAttach=" << heightAfterAttach << ";"
        << "nullRead=" << (nullReadOk ? "rejected_as_expected" : "failed") << ";"
        << "nullReadLastError=" << nullReadLastError << ";"
        << "zeroRead=" << (zeroReadOk ? "rejected_as_expected" : "failed") << ";"
        << "zeroReadLastError=" << zeroReadLastError << ";"
        << "smallCapacityRead=" << (smallCapOk ? "rejected_as_expected" : "failed") << ";"
        << "smallCapacityLastError=" << smallCapLastError << ";"
        << "outOfBoundsRead=" << (oobOk ? "rejected_as_expected" : "failed") << ";"
        << "outOfBoundsLastError=" << oobLastError << ";"
        << "directClearForReadback=" << (directClearOk ? "success" : "failed") << ";"
        << "centerRead=" << (centerReadOk ? "success" : "failed") << ";"
        << "centerReadLastError=" << centerReadLastError << ";"
        << "centerR=" << centerR << ";"
        << "centerG=" << centerG << ";"
        << "centerB=" << centerB << ";"
        << "centerA=" << centerA << ";"
        << "centerPixelMatches=" << (centerPixelMatches ? "true" : "false") << ";"
        << "fullRead=" << (fullReadOk ? "success" : "failed") << ";"
        << "fullReadLastError=" << fullReadLastError << ";"
        << "detach=" << (detachOk ? "success" : "failed") << ";"
        << "surfaceKindAfterDetach=" << surfaceKindAfterDetach << ";"
        << "postDetachRead=" << (postDetachReadOk ? "rejected_as_expected" : "failed") << ";"
        << "postDetachLastError=" << postDetachLastError << ";"
        << "shutdown=" << (shutdownOk ? "success" : "failed") << ";"
        << "idempotentShutdown=" << (idempotentShutdownOk ? "success" : "failed") << ";"
        << "proofBoundary=gles_diagnostic_read_pixels_rgba_window_surface_no_yuv_no_fence_no_product;"
        << "lastError=" << (backendLastError.empty() ? "none" : backendLastError);

    return env->NewStringUTF(oss.str().c_str());
}
