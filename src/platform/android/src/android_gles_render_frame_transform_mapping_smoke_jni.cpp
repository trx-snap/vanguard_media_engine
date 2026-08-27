// Phase 1 Unit AD: Android GLES renderFrame asymmetric UV mapping physical smoke JNI bridge.
//
// Android-only translation unit added via CMake target_sources block.
//
// Proves existing GLES renderFrame transform UV mapping with an asymmetric
// RGBA quadrant HardwareBuffer, using Unit AC diagnosticRenderFrameForReadback
// plus Unit AB diagnosticReadPixels.
//
// JNI entry point:
//   runAndroidDagPhase1ADGlesRenderFrameTransformMappingSmoke -> jstring

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

struct RgbaColor {
    int r = 0;
    int g = 0;
    int b = 0;
    int a = 0;
};

const RgbaColor kFillRed    {231,  35,  45, 255};
const RgbaColor kFillGreen  { 39, 191,  84, 255};
const RgbaColor kFillBlue   { 45, 105, 230, 255};
const RgbaColor kFillYellow {245, 196,  48, 255};

bool ColorMatches(const RgbaColor& actual, const RgbaColor& expected, int tol = 10) {
    return (std::abs(actual.r - expected.r) <= tol) &&
           (std::abs(actual.g - expected.g) <= tol) &&
           (std::abs(actual.b - expected.b) <= tol) &&
           (actual.a >= 240) &&
           (std::abs(actual.a - expected.a) <= tol);
}

std::string IdentifyFillColor(const RgbaColor& c, int tol = 10) {
    if (ColorMatches(c, kFillRed, tol)) return "red";
    if (ColorMatches(c, kFillGreen, tol)) return "green";
    if (ColorMatches(c, kFillBlue, tol)) return "blue";
    if (ColorMatches(c, kFillYellow, tol)) return "yellow";
    return "unknown";
}

struct ScreenCorners {
    RgbaColor bl;
    RgbaColor br;
    RgbaColor tl;
    RgbaColor tr;
};

bool ReadScreenCorners(vanguard::render::GlesBackend& backend,
                       uint32_t width,
                       uint32_t height,
                       ScreenCorners& outCorners,
                       std::string& outLastError) {
    const uint32_t xLeft = width / 4;
    const uint32_t xRight = 3 * width / 4;
    const uint32_t yBottom = height / 4;
    const uint32_t yTop = 3 * height / 4;

    uint8_t pBL[4] = {0}, pBR[4] = {0}, pTL[4] = {0}, pTR[4] = {0};

    if (!backend.diagnosticReadPixels(xLeft, yBottom, 1, 1, pBL, 4)) {
        outLastError = backend.lastError();
        return false;
    }
    if (!backend.diagnosticReadPixels(xRight, yBottom, 1, 1, pBR, 4)) {
        outLastError = backend.lastError();
        return false;
    }
    if (!backend.diagnosticReadPixels(xLeft, yTop, 1, 1, pTL, 4)) {
        outLastError = backend.lastError();
        return false;
    }
    if (!backend.diagnosticReadPixels(xRight, yTop, 1, 1, pTR, 4)) {
        outLastError = backend.lastError();
        return false;
    }

    outCorners.bl = {pBL[0], pBL[1], pBL[2], pBL[3]};
    outCorners.br = {pBR[0], pBR[1], pBR[2], pBR[3]};
    outCorners.tl = {pTL[0], pTL[1], pTL[2], pTL[3]};
    outCorners.tr = {pTR[0], pTR[1], pTR[2], pTR[3]};
    outLastError.clear();
    return true;
}

struct TransformTestResult {
    bool renderOk = false;
    std::string diagnosticLastError;
    bool readOk = false;
    bool matchBL = false;
    bool matchBR = false;
    bool matchTL = false;
    bool matchTR = false;
    bool pass = false;
};

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
        << "identityColorsDistinct=false;"
        << "uv00R=0;uv00G=0;uv00B=0;uv00A=0;uv00Label=unknown;"
        << "uv10R=0;uv10G=0;uv10B=0;uv10A=0;uv10Label=unknown;"
        << "uv01R=0;uv01G=0;uv01B=0;uv01A=0;uv01Label=unknown;"
        << "uv11R=0;uv11G=0;uv11B=0;uv11A=0;uv11Label=unknown;"
        << "identityPass=false;"
        << "rot90DiagnosticRender=not_run;"
        << "rot90DiagnosticLastError=;"
        << "rot90Pass=false;"
        << "rot180DiagnosticRender=not_run;"
        << "rot180DiagnosticLastError=;"
        << "rot180Pass=false;"
        << "rot270DiagnosticRender=not_run;"
        << "rot270DiagnosticLastError=;"
        << "rot270Pass=false;"
        << "mirror0DiagnosticRender=not_run;"
        << "mirror0DiagnosticLastError=;"
        << "mirror0Pass=false;"
        << "mirror90DiagnosticRender=not_run;"
        << "mirror90DiagnosticLastError=;"
        << "mirror90Pass=false;"
        << "mirror180DiagnosticRender=not_run;"
        << "mirror180DiagnosticLastError=;"
        << "mirror180Pass=false;"
        << "mirror270DiagnosticRender=not_run;"
        << "mirror270DiagnosticLastError=;"
        << "mirror270Pass=false;"
        << "allTransformsPass=false;"
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
        << "proofBoundary=gles_renderFrame_asymmetric_uv_mapping_rgba_quadrants_no_swap_no_yuv_no_fence_no_product;"
        << "lastError=" << lastErrorReason;
    return oss.str();
}

} // namespace

extern "C" JNIEXPORT jstring JNICALL
Java_com_connects_vanguard_1media_1engine_bridge_VanguardNativeBridge_runAndroidDagPhase1ADGlesRenderFrameTransformMappingSmoke(
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

    // Lock buffer for CPU write and fill four quadrants with distinct colors:
    // Top-Left: Red, Top-Right: Green, Bottom-Left: Blue, Bottom-Right: Yellow
    void* writeAddr = nullptr;
    int32_t lockRes = ahbFns.lock(ahb, AHARDWAREBUFFER_USAGE_CPU_WRITE_OFTEN, -1, nullptr, &writeAddr);
    bool bufferFillOk = false;
    int writeFenceFd = -1;
    std::string writeFenceWait = "none";
    bool writeFenceOk = false;

    if (lockRes == 0 && writeAddr != nullptr) {
        uint8_t* base = static_cast<uint8_t*>(writeAddr);
        const uint32_t halfW = desc.width / 2;
        const uint32_t halfH = desc.height / 2;

        for (uint32_t y = 0; y < desc.height; ++y) {
            uint8_t* row = base + y * desc.stride * 4;
            const bool topHalf = (y < halfH);
            for (uint32_t x = 0; x < desc.width; ++x) {
                uint8_t* pixel = row + x * 4;
                const bool leftHalf = (x < halfW);
                const RgbaColor& col = (topHalf && leftHalf)   ? kFillRed
                                     : (topHalf && !leftHalf)  ? kFillGreen
                                     : (!topHalf && leftHalf)  ? kFillBlue
                                     :                           kFillYellow;
                pixel[0] = static_cast<uint8_t>(col.r);
                pixel[1] = static_cast<uint8_t>(col.g);
                pixel[2] = static_cast<uint8_t>(col.b);
                pixel[3] = static_cast<uint8_t>(col.a);
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

    // 6. Identity render and UV corner calibration
    ScreenCorners identityCorners{};
    std::string identityReadErr;
    const bool identityRenderRes = backend.diagnosticRenderFrameForReadback(
        handle, vanguard::render::VideoFrameTransform{0, false});
    const std::string identityDiagnosticLastError = SanitizeString(backend.lastError());
    const bool identityRenderOk = identityRenderRes &&
        (identityDiagnosticLastError.empty() || identityDiagnosticLastError == "none");

    const bool identityReadOk = identityRenderOk &&
        ReadScreenCorners(backend, static_cast<uint32_t>(width), static_cast<uint32_t>(height),
                          identityCorners, identityReadErr);

    const RgbaColor uv00 = identityCorners.bl;
    const RgbaColor uv10 = identityCorners.br;
    const RgbaColor uv01 = identityCorners.tl;
    const RgbaColor uv11 = identityCorners.tr;

    const std::string uv00Label = IdentifyFillColor(uv00, 10);
    const std::string uv10Label = IdentifyFillColor(uv10, 10);
    const std::string uv01Label = IdentifyFillColor(uv01, 10);
    const std::string uv11Label = IdentifyFillColor(uv11, 10);

    const bool identityColorsDistinct =
        (uv00Label != "unknown" && uv10Label != "unknown" &&
         uv01Label != "unknown" && uv11Label != "unknown" &&
         uv00Label != uv10Label && uv00Label != uv01Label && uv00Label != uv11Label &&
         uv10Label != uv01Label && uv10Label != uv11Label &&
         uv01Label != uv11Label);

    const bool identityPass = identityRenderOk && identityReadOk && identityColorsDistinct;

    // 7. Validate remaining 7 transforms against identity-derived UV corners:
    auto testTransform = [&](uint32_t rotationDegrees,
                             bool mirrorHorizontal,
                             const RgbaColor& expectedBL,
                             const RgbaColor& expectedBR,
                             const RgbaColor& expectedTL,
                             const RgbaColor& expectedTR) -> TransformTestResult {
        TransformTestResult res;
        if (!identityPass) {
            return res;
        }
        const bool renderRes = backend.diagnosticRenderFrameForReadback(
            handle, vanguard::render::VideoFrameTransform{rotationDegrees, mirrorHorizontal});
        res.diagnosticLastError = SanitizeString(backend.lastError());
        res.renderOk = renderRes && (res.diagnosticLastError.empty() || res.diagnosticLastError == "none");
        if (!res.renderOk) {
            return res;
        }
        ScreenCorners corners{};
        std::string readErr;
        res.readOk = ReadScreenCorners(backend, static_cast<uint32_t>(width), static_cast<uint32_t>(height),
                                       corners, readErr);
        if (!res.readOk) {
            return res;
        }
        res.matchBL = ColorMatches(corners.bl, expectedBL, 10);
        res.matchBR = ColorMatches(corners.br, expectedBR, 10);
        res.matchTL = ColorMatches(corners.tl, expectedTL, 10);
        res.matchTR = ColorMatches(corners.tr, expectedTR, 10);
        res.pass = res.renderOk && res.readOk && res.matchBL && res.matchBR && res.matchTL && res.matchTR;
        return res;
    };

    // rot90: BL->uv01, BR->uv00, TL->uv11, TR->uv10
    const TransformTestResult resRot90 = testTransform(90, false, uv01, uv00, uv11, uv10);

    // rot180: BL->uv11, BR->uv01, TL->uv10, TR->uv00
    const TransformTestResult resRot180 = testTransform(180, false, uv11, uv01, uv10, uv00);

    // rot270: BL->uv10, BR->uv11, TL->uv00, TR->uv01
    const TransformTestResult resRot270 = testTransform(270, false, uv10, uv11, uv00, uv01);

    // mirror0: BL->uv10, BR->uv00, TL->uv11, TR->uv01
    const TransformTestResult resMirror0 = testTransform(0, true, uv10, uv00, uv11, uv01);

    // mirror90: BL->uv00, BR->uv01, TL->uv10, TR->uv11
    const TransformTestResult resMirror90 = testTransform(90, true, uv00, uv01, uv10, uv11);

    // mirror180: BL->uv01, BR->uv11, TL->uv00, TR->uv10
    const TransformTestResult resMirror180 = testTransform(180, true, uv01, uv11, uv00, uv10);

    // mirror270: BL->uv11, BR->uv10, TL->uv01, TR->uv00
    const TransformTestResult resMirror270 = testTransform(270, true, uv11, uv10, uv01, uv00);

    const bool allTransformsPass = identityPass &&
                                   resRot90.pass &&
                                   resRot180.pass &&
                                   resRot270.pass &&
                                   resMirror0.pass &&
                                   resMirror90.pass &&
                                   resMirror180.pass &&
                                   resMirror270.pass;

    // 8. releaseBuffer: expect releaseFence == -1, has false
    int releaseFence = -999;
    const auto releaseRes = backend.releaseHardwareBuffer(handle, &releaseFence);
    const bool hasAfterRelease = backend.hasHardwareBuffer(handle);
    const bool releaseCheckOk = (releaseRes == vanguard::render::HardwareBufferImportResult::kSuccess) &&
                                (releaseFence == -1) &&
                                !hasAfterRelease;

    // 9. postReleaseDiagnosticRender: expect false with lastError "invalid_buffer_handle"
    const bool postReleaseRes = backend.diagnosticRenderFrameForReadback(
        handle,
        vanguard::render::VideoFrameTransform{0, false});
    const std::string postReleaseLastError = SanitizeString(backend.lastError());
    const bool postReleaseDiagnosticOk = (!postReleaseRes && postReleaseLastError == "invalid_buffer_handle");

    // 10. detach and postDetachRead: expect offscreen kind and subsequent read fails with "no_surface_attached"
    backend.detachSurface();
    const bool hasSurfaceAfterDetach = backend.hasSurface();
    const std::string surfaceKindAfterDetach = SanitizeString(backend.activeSurfaceKind());
    const bool detachOk = !hasSurfaceAfterDetach && (surfaceKindAfterDetach == "offscreen");

    std::vector<uint8_t> dummyBuffer(4, 0);
    const bool postDetachReadRes = backend.diagnosticReadPixels(0, 0, 1, 1, dummyBuffer.data(), 4);
    const std::string postDetachLastError = SanitizeString(backend.lastError());
    const bool postDetachReadOk = (!postDetachReadRes && postDetachLastError == "no_surface_attached");

    // 11. shutdown and idempotent shutdown
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

    const bool allChecksPass = bufferDescribeOk &&
                               bufferFillOk &&
                               writeFenceOk &&
                               preInitDiagnosticRenderOk &&
                               initCheckOk &&
                               attachCheckOk &&
                               importCheckOk &&
                               invalidHandleOk &&
                               allTransformsPass &&
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
        << "identityDiagnosticRender=" << (identityRenderOk ? "success" : "failed") << ";"
        << "identityDiagnosticLastError=" << (identityDiagnosticLastError.empty() ? "none" : identityDiagnosticLastError) << ";"
        << "identityColorsDistinct=" << (identityColorsDistinct ? "true" : "false") << ";"
        << "uv00R=" << uv00.r << ";"
        << "uv00G=" << uv00.g << ";"
        << "uv00B=" << uv00.b << ";"
        << "uv00A=" << uv00.a << ";"
        << "uv00Label=" << uv00Label << ";"
        << "uv10R=" << uv10.r << ";"
        << "uv10G=" << uv10.g << ";"
        << "uv10B=" << uv10.b << ";"
        << "uv10A=" << uv10.a << ";"
        << "uv10Label=" << uv10Label << ";"
        << "uv01R=" << uv01.r << ";"
        << "uv01G=" << uv01.g << ";"
        << "uv01B=" << uv01.b << ";"
        << "uv01A=" << uv01.a << ";"
        << "uv01Label=" << uv01Label << ";"
        << "uv11R=" << uv11.r << ";"
        << "uv11G=" << uv11.g << ";"
        << "uv11B=" << uv11.b << ";"
        << "uv11A=" << uv11.a << ";"
        << "uv11Label=" << uv11Label << ";"
        << "identityPass=" << (identityPass ? "true" : "false") << ";"
        << "rot90DiagnosticRender=" << (resRot90.renderOk ? "success" : "failed") << ";"
        << "rot90DiagnosticLastError=" << (resRot90.diagnosticLastError.empty() ? "none" : resRot90.diagnosticLastError) << ";"
        << "rot90Pass=" << (resRot90.pass ? "true" : "false") << ";"
        << "rot180DiagnosticRender=" << (resRot180.renderOk ? "success" : "failed") << ";"
        << "rot180DiagnosticLastError=" << (resRot180.diagnosticLastError.empty() ? "none" : resRot180.diagnosticLastError) << ";"
        << "rot180Pass=" << (resRot180.pass ? "true" : "false") << ";"
        << "rot270DiagnosticRender=" << (resRot270.renderOk ? "success" : "failed") << ";"
        << "rot270DiagnosticLastError=" << (resRot270.diagnosticLastError.empty() ? "none" : resRot270.diagnosticLastError) << ";"
        << "rot270Pass=" << (resRot270.pass ? "true" : "false") << ";"
        << "mirror0DiagnosticRender=" << (resMirror0.renderOk ? "success" : "failed") << ";"
        << "mirror0DiagnosticLastError=" << (resMirror0.diagnosticLastError.empty() ? "none" : resMirror0.diagnosticLastError) << ";"
        << "mirror0Pass=" << (resMirror0.pass ? "true" : "false") << ";"
        << "mirror90DiagnosticRender=" << (resMirror90.renderOk ? "success" : "failed") << ";"
        << "mirror90DiagnosticLastError=" << (resMirror90.diagnosticLastError.empty() ? "none" : resMirror90.diagnosticLastError) << ";"
        << "mirror90Pass=" << (resMirror90.pass ? "true" : "false") << ";"
        << "mirror180DiagnosticRender=" << (resMirror180.renderOk ? "success" : "failed") << ";"
        << "mirror180DiagnosticLastError=" << (resMirror180.diagnosticLastError.empty() ? "none" : resMirror180.diagnosticLastError) << ";"
        << "mirror180Pass=" << (resMirror180.pass ? "true" : "false") << ";"
        << "mirror270DiagnosticRender=" << (resMirror270.renderOk ? "success" : "failed") << ";"
        << "mirror270DiagnosticLastError=" << (resMirror270.diagnosticLastError.empty() ? "none" : resMirror270.diagnosticLastError) << ";"
        << "mirror270Pass=" << (resMirror270.pass ? "true" : "false") << ";"
        << "allTransformsPass=" << (allTransformsPass ? "true" : "false") << ";"
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
        << "proofBoundary=gles_renderFrame_asymmetric_uv_mapping_rgba_quadrants_no_swap_no_yuv_no_fence_no_product;"
        << "lastError=" << (backendLastError.empty() ? "none" : backendLastError);

    return env->NewStringUTF(oss.str().c_str());
}
