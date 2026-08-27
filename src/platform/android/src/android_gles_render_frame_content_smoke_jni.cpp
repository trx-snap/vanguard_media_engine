// Phase 1 Unit AC: Android GLES renderFrame texture-content readback physical smoke JNI bridge.
//
// Android-only translation unit added via CMake target_sources block.
//
// Non-claim: solid-color content transport and transform-path execution only;
// not asymmetric rotation/mirror pixel mapping.
//
// JNI entry point:
//   runAndroidDagPhase1ACGlesRenderFrameContentSmoke -> jstring

#include <jni.h>
#include <android/hardware_buffer.h>
#include <android/native_window_jni.h>
#include <android/rect.h>
#include <GLES2/gl2.h>
#include <dlfcn.h>
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

namespace {

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
        << "bufferUsage=0;"
        << "bufferStride=0;"
        << "bufferFill=not_run;"
        << "writeFenceFd=-1;"
        << "writeFenceWait=none;"
        << "preInitDiagnosticRender=not_run;"
        << "preInitLastError=;"
        << "initialize=not_run;"
        << "attach=not_run;"
        << "hasSurfaceAfterAttach=false;"
        << "surfaceKindAfterAttach=none;"
        << "widthAfterAttach=0;"
        << "heightAfterAttach=0;"
        << "importBuffer=not_run;"
        << "handle=0;"
        << "descriptorWidth=0;"
        << "descriptorHeight=0;"
        << "descriptorLayers=0;"
        << "descriptorFormat=0;"
        << "descriptorUsageSampled=false;"
        << "hasAfterImport=false;"
        << "invalidHandleDiagnosticRender=not_run;"
        << "invalidHandleLastError=;"
        << "identityDiagnosticRender=not_run;"
        << "identityDiagnosticLastError=;"
        << "identityCenterRead=not_run;"
        << "identityCenterReadLastError=;"
        << "identityCenterR=0;"
        << "identityCenterG=0;"
        << "identityCenterB=0;"
        << "identityCenterA=0;"
        << "identityCenterPixelMatches=false;"
        << "rot90DiagnosticRender=not_run;"
        << "rot90DiagnosticLastError=;"
        << "rot90CenterRead=not_run;"
        << "rot90CenterReadLastError=;"
        << "rot90CenterR=0;"
        << "rot90CenterG=0;"
        << "rot90CenterB=0;"
        << "rot90CenterA=0;"
        << "rot90CenterPixelMatches=false;"
        << "releaseBuffer=not_run;"
        << "releaseFence=-1;"
        << "hasAfterRelease=false;"
        << "postReleaseDiagnosticRender=not_run;"
        << "postReleaseLastError=;"
        << "detach=not_run;"
        << "surfaceKindAfterDetach=none;"
        << "postDetachRead=not_run;"
        << "postDetachLastError=;"
        << "shutdown=not_run;"
        << "idempotentShutdown=not_run;"
        << "proofBoundary=gles_renderFrame_rgba_texture_content_readback_no_swap_no_yuv_no_fence_no_product;"
        << "lastError=" << lastErrorReason;
    return oss.str();
}

} // namespace

extern "C" JNIEXPORT jstring JNICALL
Java_com_connects_vanguard_1media_1engine_bridge_VanguardNativeBridge_runAndroidDagPhase1ACGlesRenderFrameContentSmoke(
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
    const bool bufferDescribeOk = (desc.width == static_cast<uint32_t>(width)) &&
                                  (desc.height == static_cast<uint32_t>(height)) &&
                                  (desc.layers == 1) &&
                                  (desc.format == AHARDWAREBUFFER_FORMAT_R8G8B8A8_UNORM) &&
                                  ((desc.usage & AHARDWAREBUFFER_USAGE_GPU_SAMPLED_IMAGE) != 0) &&
                                  ((desc.usage & AHARDWAREBUFFER_USAGE_CPU_WRITE_OFTEN) != 0) &&
                                  (desc.stride >= desc.width);

    if (!bufferDescribeOk) {
        ANativeWindow_release(window);
        return env->NewStringUTF(BuildFailureString("hardware_buffer_descriptor_mismatch").c_str());
    }

    // Lock buffer for CPU write and fill every pixel with solid color (R=37, G=111, B=203, A=255)
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

    // 1. preInitDiagnosticRender: before initialize, expect false with lastError "backend_not_initialized"
    const bool preInitRes = backend.diagnosticRenderFrameForReadback(
        vanguard::render::kInvalidHardwareBufferHandle,
        vanguard::render::VideoFrameTransform{});
    const std::string preInitLastError = SanitizeString(backend.lastError());
    const bool preInitDiagnosticRenderOk = (!preInitRes && preInitLastError == "backend_not_initialized");

    // 2. initialize: expect true, clientVersion >= 2, non-empty vendor/renderer/version
    const bool initOk = backend.initialize();
    const bool isInitialized = backend.isInitialized();
    const int clientVersion = backend.clientVersion();
    const std::string vendor = SanitizeString(backend.diagnosticVendor());
    const std::string renderer = SanitizeString(backend.diagnosticRenderer());
    const std::string version = SanitizeString(backend.diagnosticVersion());
    const bool initCheckOk = initOk && isInitialized && (clientVersion >= 2) &&
                             !vendor.empty() && !renderer.empty() && !version.empty();

    // 3. attach surface: expect hasSurface true, kind window, dimensions match
    const bool attachOk = backend.attachSurface(window, static_cast<uint32_t>(width), static_cast<uint32_t>(height));
    const bool hasSurfaceAfterAttach = backend.hasSurface();
    const std::string surfaceKindAfterAttach = SanitizeString(backend.activeSurfaceKind());
    const uint32_t widthAfterAttach = backend.surfaceWidth();
    const uint32_t heightAfterAttach = backend.surfaceHeight();
    const bool attachCheckOk = attachOk && hasSurfaceAfterAttach &&
                               (surfaceKindAfterAttach == "window") &&
                               (widthAfterAttach == static_cast<uint32_t>(width)) &&
                               (heightAfterAttach == static_cast<uint32_t>(height));

    // 4. importBuffer: expect handle > 0, descriptor matches, has true
    vanguard::render::HardwareBufferHandle handle = vanguard::render::kInvalidHardwareBufferHandle;
    vanguard::render::HardwareBufferDescriptor descImport{};
    const auto importRes = backend.importHardwareBuffer(ahb, -1, &handle, &descImport);
    const bool hasAfterImport = backend.hasHardwareBuffer(handle);
    const bool importCheckOk = (importRes == vanguard::render::HardwareBufferImportResult::kSuccess) &&
                               (handle != vanguard::render::kInvalidHardwareBufferHandle) &&
                               (descImport.width == static_cast<uint32_t>(width)) &&
                               (descImport.height == static_cast<uint32_t>(height)) &&
                               (descImport.layers == 1) &&
                               ((descImport.usage & AHARDWAREBUFFER_USAGE_GPU_SAMPLED_IMAGE) != 0) &&
                               (descImport.format != 0) &&
                               hasAfterImport;

    // 5. invalidHandleDiagnosticRender after attach: expect false with lastError "invalid_buffer_handle"
    const bool invalidHandleRes = backend.diagnosticRenderFrameForReadback(
        999999,
        vanguard::render::VideoFrameTransform{0, false});
    const std::string invalidHandleLastError = SanitizeString(backend.lastError());
    const bool invalidHandleOk = (!invalidHandleRes && invalidHandleLastError == "invalid_buffer_handle");

    // 6. identityDiagnosticRender: expect true with empty/none lastError
    const bool identityDiagnosticRes = backend.diagnosticRenderFrameForReadback(
        handle,
        vanguard::render::VideoFrameTransform{0, false});
    const std::string identityDiagnosticLastError = SanitizeString(backend.lastError());
    const bool identityDiagnosticOk = identityDiagnosticRes &&
        (identityDiagnosticLastError.empty() || identityDiagnosticLastError == "none");

    // 7. identityCenterRead: center pixel readback matching R=37, G=111, B=203, A>=240 with tol <= 8
    std::vector<uint8_t> identityCenterPixel(4, 0);
    const bool identityCenterReadRes = backend.diagnosticReadPixels(
        static_cast<uint32_t>(width / 2),
        static_cast<uint32_t>(height / 2),
        1, 1,
        identityCenterPixel.data(),
        4);
    const std::string identityCenterReadLastError = SanitizeString(backend.lastError());
    const int identityCenterR = static_cast<int>(identityCenterPixel[0]);
    const int identityCenterG = static_cast<int>(identityCenterPixel[1]);
    const int identityCenterB = static_cast<int>(identityCenterPixel[2]);
    const int identityCenterA = static_cast<int>(identityCenterPixel[3]);
    const bool identityCenterPixelMatches = (std::abs(identityCenterR - 37) <= 8) &&
                                            (std::abs(identityCenterG - 111) <= 8) &&
                                            (std::abs(identityCenterB - 203) <= 8) &&
                                            (identityCenterA >= 240);
    const bool identityCenterReadOk = identityCenterReadRes &&
        (identityCenterReadLastError.empty() || identityCenterReadLastError == "none") &&
        identityCenterPixelMatches;

    // 8. rot90DiagnosticRender: transform with rotationDegrees=90, expect true with empty/none lastError
    const bool rot90DiagnosticRes = backend.diagnosticRenderFrameForReadback(
        handle,
        vanguard::render::VideoFrameTransform{90, false});
    const std::string rot90DiagnosticLastError = SanitizeString(backend.lastError());
    const bool rot90DiagnosticOk = rot90DiagnosticRes &&
        (rot90DiagnosticLastError.empty() || rot90DiagnosticLastError == "none");

    // 9. rot90CenterRead: read center pixel again; expect same solid color match
    std::vector<uint8_t> rot90CenterPixel(4, 0);
    const bool rot90CenterReadRes = backend.diagnosticReadPixels(
        static_cast<uint32_t>(width / 2),
        static_cast<uint32_t>(height / 2),
        1, 1,
        rot90CenterPixel.data(),
        4);
    const std::string rot90CenterReadLastError = SanitizeString(backend.lastError());
    const int rot90CenterR = static_cast<int>(rot90CenterPixel[0]);
    const int rot90CenterG = static_cast<int>(rot90CenterPixel[1]);
    const int rot90CenterB = static_cast<int>(rot90CenterPixel[2]);
    const int rot90CenterA = static_cast<int>(rot90CenterPixel[3]);
    const bool rot90CenterPixelMatches = (std::abs(rot90CenterR - 37) <= 8) &&
                                         (std::abs(rot90CenterG - 111) <= 8) &&
                                         (std::abs(rot90CenterB - 203) <= 8) &&
                                         (rot90CenterA >= 240);
    const bool rot90CenterReadOk = rot90CenterReadRes &&
        (rot90CenterReadLastError.empty() || rot90CenterReadLastError == "none") &&
        rot90CenterPixelMatches;

    // 10. releaseBuffer: expect releaseFence >= -1, has false
    int releaseFence = -999;
    const auto releaseRes = backend.releaseHardwareBuffer(handle, &releaseFence);
    const bool hasAfterRelease = backend.hasHardwareBuffer(handle);
    const bool releaseCheckOk = (releaseRes == vanguard::render::HardwareBufferImportResult::kSuccess) &&
                                (releaseFence >= -1) &&
                                !hasAfterRelease;

    // 11. postReleaseDiagnosticRender: expect false with lastError "invalid_buffer_handle"
    const bool postReleaseRes = backend.diagnosticRenderFrameForReadback(
        handle,
        vanguard::render::VideoFrameTransform{0, false});
    const std::string postReleaseLastError = SanitizeString(backend.lastError());
    const bool postReleaseDiagnosticOk = (!postReleaseRes && postReleaseLastError == "invalid_buffer_handle");

    // 12. detach and postDetachRead: expect offscreen kind and subsequent read fails with "no_surface_attached"
    backend.detachSurface();
    const bool hasSurfaceAfterDetach = backend.hasSurface();
    const std::string surfaceKindAfterDetach = SanitizeString(backend.activeSurfaceKind());
    const bool detachOk = !hasSurfaceAfterDetach && (surfaceKindAfterDetach == "offscreen");

    std::vector<uint8_t> dummyBuffer(4, 0);
    const bool postDetachReadRes = backend.diagnosticReadPixels(0, 0, 1, 1, dummyBuffer.data(), 4);
    const std::string postDetachLastError = SanitizeString(backend.lastError());
    const bool postDetachReadOk = (!postDetachReadRes && postDetachLastError == "no_surface_attached");

    // 13. shutdown and idempotent shutdown
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

    // Release ANativeWindow acquired from JNI Surface
    ANativeWindow_release(window);

    // Close any non-negative fds returned by releaseHardwareBuffer exactly once after capturing
    if (releaseFence >= 0) {
        ::close(releaseFence);
    }

    const bool allChecksPass = bufferDescribeOk &&
                               bufferFillOk &&
                               writeFenceOk &&
                               preInitDiagnosticRenderOk &&
                               initCheckOk &&
                               attachCheckOk &&
                               importCheckOk &&
                               invalidHandleOk &&
                               identityDiagnosticOk &&
                               identityCenterReadOk &&
                               rot90DiagnosticOk &&
                               rot90CenterReadOk &&
                               releaseCheckOk &&
                               postReleaseDiagnosticOk &&
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
        << "bufferDescribe=" << (bufferDescribeOk ? "success" : "failed") << ";"
        << "bufferWidth=" << desc.width << ";"
        << "bufferHeight=" << desc.height << ";"
        << "bufferLayers=" << desc.layers << ";"
        << "bufferFormat=" << desc.format << ";"
        << "bufferUsage=" << desc.usage << ";"
        << "bufferStride=" << desc.stride << ";"
        << "bufferFill=" << (bufferFillOk ? "success" : "failed") << ";"
        << "writeFenceFd=" << writeFenceFd << ";"
        << "writeFenceWait=" << writeFenceWait << ";"
        << "preInitDiagnosticRender=" << (preInitDiagnosticRenderOk ? "rejected_as_expected" : "failed") << ";"
        << "preInitLastError=" << preInitLastError << ";"
        << "initialize=" << (initCheckOk ? "success" : "failed") << ";"
        << "attach=" << (attachCheckOk ? "success" : "failed") << ";"
        << "hasSurfaceAfterAttach=" << (hasSurfaceAfterAttach ? "true" : "false") << ";"
        << "surfaceKindAfterAttach=" << surfaceKindAfterAttach << ";"
        << "widthAfterAttach=" << widthAfterAttach << ";"
        << "heightAfterAttach=" << heightAfterAttach << ";"
        << "importBuffer=" << (importCheckOk ? "success" : "failed") << ";"
        << "handle=" << handle << ";"
        << "descriptorWidth=" << descImport.width << ";"
        << "descriptorHeight=" << descImport.height << ";"
        << "descriptorLayers=" << descImport.layers << ";"
        << "descriptorFormat=" << descImport.format << ";"
        << "descriptorUsageSampled=" << (((descImport.usage & AHARDWAREBUFFER_USAGE_GPU_SAMPLED_IMAGE) != 0) ? "true" : "false") << ";"
        << "hasAfterImport=" << (hasAfterImport ? "true" : "false") << ";"
        << "invalidHandleDiagnosticRender=" << (invalidHandleOk ? "rejected_as_expected" : "failed") << ";"
        << "invalidHandleLastError=" << invalidHandleLastError << ";"
        << "identityDiagnosticRender=" << (identityDiagnosticOk ? "success" : "failed") << ";"
        << "identityDiagnosticLastError=" << identityDiagnosticLastError << ";"
        << "identityCenterRead=" << (identityCenterReadOk ? "success" : "failed") << ";"
        << "identityCenterReadLastError=" << identityCenterReadLastError << ";"
        << "identityCenterR=" << identityCenterR << ";"
        << "identityCenterG=" << identityCenterG << ";"
        << "identityCenterB=" << identityCenterB << ";"
        << "identityCenterA=" << identityCenterA << ";"
        << "identityCenterPixelMatches=" << (identityCenterPixelMatches ? "true" : "false") << ";"
        << "rot90DiagnosticRender=" << (rot90DiagnosticOk ? "success" : "failed") << ";"
        << "rot90DiagnosticLastError=" << rot90DiagnosticLastError << ";"
        << "rot90CenterRead=" << (rot90CenterReadOk ? "success" : "failed") << ";"
        << "rot90CenterReadLastError=" << rot90CenterReadLastError << ";"
        << "rot90CenterR=" << rot90CenterR << ";"
        << "rot90CenterG=" << rot90CenterG << ";"
        << "rot90CenterB=" << rot90CenterB << ";"
        << "rot90CenterA=" << rot90CenterA << ";"
        << "rot90CenterPixelMatches=" << (rot90CenterPixelMatches ? "true" : "false") << ";"
        << "releaseBuffer=" << (releaseCheckOk ? "success" : "failed") << ";"
        << "releaseFence=" << releaseFence << ";"
        << "hasAfterRelease=" << (hasAfterRelease ? "true" : "false") << ";"
        << "postReleaseDiagnosticRender=" << (postReleaseDiagnosticOk ? "rejected_as_expected" : "failed") << ";"
        << "postReleaseLastError=" << postReleaseLastError << ";"
        << "detach=" << (detachOk ? "success" : "failed") << ";"
        << "surfaceKindAfterDetach=" << surfaceKindAfterDetach << ";"
        << "postDetachRead=" << (postDetachReadOk ? "rejected_as_expected" : "failed") << ";"
        << "postDetachLastError=" << postDetachLastError << ";"
        << "shutdown=" << (shutdownOk ? "success" : "failed") << ";"
        << "idempotentShutdown=" << (idempotentShutdownOk ? "success" : "failed") << ";"
        << "proofBoundary=gles_renderFrame_rgba_texture_content_readback_no_swap_no_yuv_no_fence_no_product;"
        << "lastError=" << (backendLastError.empty() ? "none" : backendLastError);

    return env->NewStringUTF(oss.str().c_str());
}
