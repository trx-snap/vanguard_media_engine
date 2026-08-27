// Phase 1 Unit AR: Android GLES external texture YCBCR_420_888 AHardwareBuffer import foundation physical smoke JNI bridge.
//
// Android-only translation unit added via CMake target_sources block.
//
// Non-claim: external texture import foundation for Y8Cb8Cr8_420 only;
// no color-correct YUV->RGB conversion, no Camera2 product wiring, no multi-node DAG composition.
//
// JNI entry point:
//   runAndroidDagPhase1ARGlesExternalTextureSmoke -> jstring

#include <jni.h>
#include <android/hardware_buffer.h>
#include <android/native_window_jni.h>
#include <dlfcn.h>
#include <unistd.h>

#include <cstdint>
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
        << "rgbaBufferDescribe=not_run;"
        << "rgbaBufferFormat=0;"
        << "rgbaBufferUsage=0;"
        << "ycbcrBufferDescribe=not_run;"
        << "ycbcrBufferFormat=0;"
        << "ycbcrBufferUsage=0;"
        << "ycbcrFormatIs420888=false;"
        << "initialize=not_run;"
        << "attach=not_run;"
        << "hasSurfaceAfterAttach=false;"
        << "surfaceKindAfterAttach=none;"
        << "widthAfterAttach=0;"
        << "heightAfterAttach=0;"
        << "ycbcrImport=not_run;"
        << "ycbcrHandle=0;"
        << "ycbcrDescWidth=0;"
        << "ycbcrDescHeight=0;"
        << "ycbcrDescLayers=0;"
        << "ycbcrDescFormat=0;"
        << "ycbcrDescUsageSampled=false;"
        << "hasYcbcrAfterImport=false;"
        << "ycbcrTextureTarget=0;"
        << "diagnosticRender=not_run;"
        << "diagnosticRenderLastError=;"
        << "centerRead=not_run;"
        << "centerReadLastError=;"
        << "renderFrame=not_run;"
        << "renderFrameLastError=;"
        << "releaseYcbcr=not_run;"
        << "releaseYcbcrFence=-1;"
        << "hasYcbcrAfterRelease=false;"
        << "rgbaPostImport=not_run;"
        << "rgbaPostHandle=0;"
        << "rgbaPostDescWidth=0;"
        << "rgbaPostDescHeight=0;"
        << "rgbaPostDescLayers=0;"
        << "rgbaPostDescFormat=0;"
        << "rgbaPostDescUsageSampled=false;"
        << "hasRgbaPostAfterImport=false;"
        << "rgbaPostTextureTarget=0;"
        << "rgbaPostRelease=not_run;"
        << "rgbaPostReleaseFence=-1;"
        << "hasRgbaPostAfterRelease=false;"
        << "detach=not_run;"
        << "surfaceKindAfterDetach=none;"
        << "shutdown=not_run;"
        << "idempotentShutdown=not_run;"
        << "proofBoundary=gles_external_texture_ycbcr_import_foundation_no_color_conversion_no_camera_product_no_multinode;"
        << "lastError=" << lastErrorReason;
    return oss.str();
}

} // namespace

extern "C" JNIEXPORT jstring JNICALL
Java_com_connects_vanguard_1media_1engine_bridge_VanguardNativeBridge_runAndroidDagPhase1ARGlesExternalTextureSmoke(
    JNIEnv* env,
    jobject /* this */,
    jobject jSurface,
    jobject jRgbaBuffer,
    jobject jYcbcrBuffer,
    jint width,
    jint height) {

    if (!jSurface || !jRgbaBuffer || !jYcbcrBuffer || width <= 0 || height <= 0) {
        return env->NewStringUTF(BuildFailureString("invalid_arguments").c_str());
    }

    NativeHardwareBufferFunctions ahbFns = ResolveNativeHardwareBufferFunctions();
    if (!ahbFns.isValid()) {
        return env->NewStringUTF(BuildFailureString("hardware_buffer_symbols_unavailable").c_str());
    }

    ANativeWindow* window = ANativeWindow_fromSurface(env, jSurface);
    if (!window) {
        return env->NewStringUTF(BuildFailureString("native_window_from_surface_failed").c_str());
    }

    AHardwareBuffer* ahbRgba = ahbFns.fromHardwareBuffer(env, jRgbaBuffer);
    AHardwareBuffer* ahbYcbcr = ahbFns.fromHardwareBuffer(env, jYcbcrBuffer);

    if (!ahbRgba || !ahbYcbcr) {
        ANativeWindow_release(window);
        return env->NewStringUTF(BuildFailureString("hardware_buffer_from_jobject_failed").c_str());
    }

    // 1. Buffer description validations
    AHardwareBuffer_Desc descRgbaBuf{};
    ahbFns.describe(ahbRgba, &descRgbaBuf);
    const bool rgbaBufferDescribeOk = (descRgbaBuf.width == static_cast<uint32_t>(width)) &&
                                      (descRgbaBuf.height == static_cast<uint32_t>(height)) &&
                                      (descRgbaBuf.layers == 1) &&
                                      (descRgbaBuf.format == AHARDWAREBUFFER_FORMAT_R8G8B8A8_UNORM) &&
                                      ((descRgbaBuf.usage & AHARDWAREBUFFER_USAGE_GPU_SAMPLED_IMAGE) != 0);

    AHardwareBuffer_Desc descYcbcrBuf{};
    ahbFns.describe(ahbYcbcr, &descYcbcrBuf);
    const bool ycbcrFormatIs420888 = (descYcbcrBuf.format == AHARDWAREBUFFER_FORMAT_Y8Cb8Cr8_420);
    const bool ycbcrBufferDescribeOk = (descYcbcrBuf.width == static_cast<uint32_t>(width)) &&
                                       (descYcbcrBuf.height == static_cast<uint32_t>(height)) &&
                                       (descYcbcrBuf.layers == 1) &&
                                       ycbcrFormatIs420888 &&
                                       ((descYcbcrBuf.usage & AHARDWAREBUFFER_USAGE_GPU_SAMPLED_IMAGE) != 0);

    vanguard::render::GlesBackend backend;

    // 2. Initialize backend
    const bool initOk = backend.initialize();
    const bool isInitialized = backend.isInitialized();
    const int clientVersion = backend.clientVersion();
    const std::string vendor = SanitizeString(backend.diagnosticVendor());
    const std::string renderer = SanitizeString(backend.diagnosticRenderer());
    const std::string version = SanitizeString(backend.diagnosticVersion());
    const bool initCheckOk = initOk && isInitialized && (clientVersion >= 2) &&
                             !vendor.empty() && !renderer.empty() && !version.empty();

    // 3. Attach surface
    const bool attachOk = backend.attachSurface(window, static_cast<uint32_t>(width), static_cast<uint32_t>(height));
    const bool hasSurfaceAfterAttach = backend.hasSurface();
    const std::string surfaceKindAfterAttach = SanitizeString(backend.activeSurfaceKind());
    const uint32_t widthAfterAttach = backend.surfaceWidth();
    const uint32_t heightAfterAttach = backend.surfaceHeight();
    const bool attachCheckOk = attachOk && hasSurfaceAfterAttach &&
                               (surfaceKindAfterAttach == "window") &&
                               (widthAfterAttach == static_cast<uint32_t>(width)) &&
                               (heightAfterAttach == static_cast<uint32_t>(height));

    // 4. Import YCBCR buffer
    vanguard::render::HardwareBufferHandle hYcbcr = vanguard::render::kInvalidHardwareBufferHandle;
    vanguard::render::HardwareBufferDescriptor descYcbcr{};
    const auto resYcbcr = backend.importHardwareBuffer(ahbYcbcr, -1, &hYcbcr, &descYcbcr);
    const bool hasYcbcrAfterImport = backend.hasHardwareBuffer(hYcbcr);
    const bool ycbcrDescOk = (descYcbcr.width == static_cast<uint32_t>(width)) &&
                             (descYcbcr.height == static_cast<uint32_t>(height)) &&
                             (descYcbcr.layers == 1) &&
                             (descYcbcr.format == AHARDWAREBUFFER_FORMAT_Y8Cb8Cr8_420) &&
                             ((descYcbcr.usage & AHARDWAREBUFFER_USAGE_GPU_SAMPLED_IMAGE) != 0);
    const bool ycbcrImportOk = (resYcbcr == vanguard::render::HardwareBufferImportResult::kSuccess) &&
                               (hYcbcr != vanguard::render::kInvalidHardwareBufferHandle) &&
                               ycbcrDescOk &&
                               hasYcbcrAfterImport;

    // 5. Texture target check for YCBCR (GL_TEXTURE_EXTERNAL_OES = 0x8D65)
    const uint32_t ycbcrTextureTarget = backend.diagnosticTextureTargetForHardwareBuffer(hYcbcr);
    const bool ycbcrTargetOk = (ycbcrTextureTarget == 0x8D65);

    // 6. Diagnostic render frame for readback (identity)
    const bool diagRenderRes = backend.diagnosticRenderFrameForReadback(
        hYcbcr,
        vanguard::render::VideoFrameTransform{0, false});
    const std::string diagRenderLastError = SanitizeString(backend.lastError());
    const bool diagRenderOk = diagRenderRes &&
                              (diagRenderLastError.empty() || diagRenderLastError == "none");

    // 7. Diagnostic read pixels center 1x1 (assert read succeeds; do not assert color/luminance)
    std::vector<uint8_t> centerPixel(4, 0);
    const bool centerReadRes = backend.diagnosticReadPixels(
        static_cast<uint32_t>(width / 2),
        static_cast<uint32_t>(height / 2),
        1, 1,
        centerPixel.data(),
        4);
    const std::string centerReadLastError = SanitizeString(backend.lastError());
    const bool centerReadOk = centerReadRes &&
                              (centerReadLastError.empty() || centerReadLastError == "none");

    // 8. renderFrame(handle)
    const auto renderFrameRes = backend.renderFrame(hYcbcr);
    const std::string renderFrameLastError = SanitizeString(backend.lastError());
    const bool renderFrameOk = (renderFrameRes == vanguard::render::RenderFrameResult::kSuccess) &&
                               (renderFrameLastError.empty() || renderFrameLastError == "none");

    // 9. Release YCBCR buffer
    int releaseFenceYcbcr = -999;
    const auto releaseYcbcrRes = backend.releaseHardwareBuffer(hYcbcr, &releaseFenceYcbcr);
    const bool hasYcbcrAfterRelease = backend.hasHardwareBuffer(hYcbcr);
    const bool releaseYcbcrOk = (releaseYcbcrRes == vanguard::render::HardwareBufferImportResult::kSuccess) &&
                                (releaseFenceYcbcr >= -1) &&
                                !hasYcbcrAfterRelease;
    if (releaseFenceYcbcr >= 0) {
        ::close(releaseFenceYcbcr);
    }

    // 10. Import RGBA buffer after YCBCR release
    vanguard::render::HardwareBufferHandle hRgbaPost = vanguard::render::kInvalidHardwareBufferHandle;
    vanguard::render::HardwareBufferDescriptor descRgbaPost{};
    const auto resRgbaPost = backend.importHardwareBuffer(ahbRgba, -1, &hRgbaPost, &descRgbaPost);
    const bool hasRgbaPostAfterImport = backend.hasHardwareBuffer(hRgbaPost);
    const bool rgbaPostDescOk = (descRgbaPost.width == static_cast<uint32_t>(width)) &&
                                (descRgbaPost.height == static_cast<uint32_t>(height)) &&
                                (descRgbaPost.layers == 1) &&
                                (descRgbaPost.format == AHARDWAREBUFFER_FORMAT_R8G8B8A8_UNORM) &&
                                ((descRgbaPost.usage & AHARDWAREBUFFER_USAGE_GPU_SAMPLED_IMAGE) != 0);
    const bool rgbaPostImportOk = (resRgbaPost == vanguard::render::HardwareBufferImportResult::kSuccess) &&
                                  (hRgbaPost != vanguard::render::kInvalidHardwareBufferHandle) &&
                                  rgbaPostDescOk &&
                                  hasRgbaPostAfterImport;

    // 11. Texture target check for RGBA (GL_TEXTURE_2D = 0x0DE1)
    const uint32_t rgbaPostTextureTarget = backend.diagnosticTextureTargetForHardwareBuffer(hRgbaPost);
    const bool rgbaPostTargetOk = (rgbaPostTextureTarget == 0x0DE1);

    // 12. Release RGBA buffer
    int releaseFenceRgba = -999;
    const auto releaseRgbaRes = backend.releaseHardwareBuffer(hRgbaPost, &releaseFenceRgba);
    const bool hasRgbaPostAfterRelease = backend.hasHardwareBuffer(hRgbaPost);
    const bool rgbaPostReleaseOk = (releaseRgbaRes == vanguard::render::HardwareBufferImportResult::kSuccess) &&
                                   (releaseFenceRgba >= -1) &&
                                   !hasRgbaPostAfterRelease;
    if (releaseFenceRgba >= 0) {
        ::close(releaseFenceRgba);
    }

    // 13. Detach surface
    backend.detachSurface();
    const bool hasSurfaceAfterDetach = backend.hasSurface();
    const std::string surfaceKindAfterDetach = SanitizeString(backend.activeSurfaceKind());
    const bool detachOk = !hasSurfaceAfterDetach && (surfaceKindAfterDetach == "offscreen");

    // 14. Shutdown and idempotent shutdown
    backend.shutdown();
    const bool shutdownOk = !backend.isInitialized();
    backend.shutdown();
    const bool idempotentShutdownOk = !backend.isInitialized();

    // Release ANativeWindow
    ANativeWindow_release(window);

    const bool allChecksPass = rgbaBufferDescribeOk &&
                               ycbcrBufferDescribeOk &&
                               initCheckOk &&
                               attachCheckOk &&
                               ycbcrImportOk &&
                               ycbcrTargetOk &&
                               diagRenderOk &&
                               centerReadOk &&
                               renderFrameOk &&
                               releaseYcbcrOk &&
                               rgbaPostImportOk &&
                               rgbaPostTargetOk &&
                               rgbaPostReleaseOk &&
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
        << "rgbaBufferDescribe=" << (rgbaBufferDescribeOk ? "success" : "failed") << ";"
        << "rgbaBufferFormat=" << descRgbaBuf.format << ";"
        << "rgbaBufferUsage=" << descRgbaBuf.usage << ";"
        << "ycbcrBufferDescribe=" << (ycbcrBufferDescribeOk ? "success" : "failed") << ";"
        << "ycbcrBufferFormat=" << descYcbcrBuf.format << ";"
        << "ycbcrBufferUsage=" << descYcbcrBuf.usage << ";"
        << "ycbcrFormatIs420888=" << (ycbcrFormatIs420888 ? "true" : "false") << ";"
        << "initialize=" << (initCheckOk ? "success" : "failed") << ";"
        << "attach=" << (attachCheckOk ? "success" : "failed") << ";"
        << "hasSurfaceAfterAttach=" << (hasSurfaceAfterAttach ? "true" : "false") << ";"
        << "surfaceKindAfterAttach=" << surfaceKindAfterAttach << ";"
        << "widthAfterAttach=" << widthAfterAttach << ";"
        << "heightAfterAttach=" << heightAfterAttach << ";"
        << "ycbcrImport=" << (ycbcrImportOk ? "success" : "failed") << ";"
        << "ycbcrHandle=" << hYcbcr << ";"
        << "ycbcrDescWidth=" << descYcbcr.width << ";"
        << "ycbcrDescHeight=" << descYcbcr.height << ";"
        << "ycbcrDescLayers=" << descYcbcr.layers << ";"
        << "ycbcrDescFormat=" << descYcbcr.format << ";"
        << "ycbcrDescUsageSampled=" << (((descYcbcr.usage & AHARDWAREBUFFER_USAGE_GPU_SAMPLED_IMAGE) != 0) ? "true" : "false") << ";"
        << "hasYcbcrAfterImport=" << (hasYcbcrAfterImport ? "true" : "false") << ";"
        << "ycbcrTextureTarget=" << ycbcrTextureTarget << ";"
        << "diagnosticRender=" << (diagRenderOk ? "success" : "failed") << ";"
        << "diagnosticRenderLastError=" << (diagRenderLastError.empty() ? "none" : diagRenderLastError) << ";"
        << "centerRead=" << (centerReadOk ? "success" : "failed") << ";"
        << "centerReadLastError=" << (centerReadLastError.empty() ? "none" : centerReadLastError) << ";"
        << "renderFrame=" << (renderFrameOk ? "success" : "failed") << ";"
        << "renderFrameLastError=" << (renderFrameLastError.empty() ? "none" : renderFrameLastError) << ";"
        << "releaseYcbcr=" << (releaseYcbcrOk ? "success" : "failed") << ";"
        << "releaseYcbcrFence=" << releaseFenceYcbcr << ";"
        << "hasYcbcrAfterRelease=" << (hasYcbcrAfterRelease ? "true" : "false") << ";"
        << "rgbaPostImport=" << (rgbaPostImportOk ? "success" : "failed") << ";"
        << "rgbaPostHandle=" << hRgbaPost << ";"
        << "rgbaPostDescWidth=" << descRgbaPost.width << ";"
        << "rgbaPostDescHeight=" << descRgbaPost.height << ";"
        << "rgbaPostDescLayers=" << descRgbaPost.layers << ";"
        << "rgbaPostDescFormat=" << descRgbaPost.format << ";"
        << "rgbaPostDescUsageSampled=" << (((descRgbaPost.usage & AHARDWAREBUFFER_USAGE_GPU_SAMPLED_IMAGE) != 0) ? "true" : "false") << ";"
        << "hasRgbaPostAfterImport=" << (hasRgbaPostAfterImport ? "true" : "false") << ";"
        << "rgbaPostTextureTarget=" << rgbaPostTextureTarget << ";"
        << "rgbaPostRelease=" << (rgbaPostReleaseOk ? "success" : "failed") << ";"
        << "rgbaPostReleaseFence=" << releaseFenceRgba << ";"
        << "hasRgbaPostAfterRelease=" << (hasRgbaPostAfterRelease ? "true" : "false") << ";"
        << "detach=" << (detachOk ? "success" : "failed") << ";"
        << "surfaceKindAfterDetach=" << surfaceKindAfterDetach << ";"
        << "shutdown=" << (shutdownOk ? "success" : "failed") << ";"
        << "idempotentShutdown=" << (idempotentShutdownOk ? "success" : "failed") << ";"
        << "proofBoundary=gles_external_texture_ycbcr_import_foundation_no_color_conversion_no_camera_product_no_multinode;"
        << "lastError=" << (backendLastError.empty() ? "none" : backendLastError);

    return env->NewStringUTF(oss.str().c_str());
}
