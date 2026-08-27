// Phase 1 Unit AS: Android GLES two-texture compositor RGBA blend foundation physical smoke JNI bridge.
//
// Android-only translation unit added via CMake target_sources block.
//
// Non-claim: two-texture GL_TEXTURE_2D composition foundation only;
// no external/OES mixed composition, no timeline DAG integration, no transitions/PiP, no product UI.
//
// JNI entry point:
//   runAndroidDagPhase1ASGlesTwoTextureCompositorSmoke -> jstring

#include <jni.h>
#include <android/hardware_buffer.h>
#include <android/native_window_jni.h>
#include <android/rect.h>
#include <dlfcn.h>
#include <poll.h>
#include <unistd.h>

#include <cmath>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <limits>
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
        << "bufferADescribe=not_run;"
        << "bufferAFormat=0;"
        << "bufferAUsage=0;"
        << "bufferAStride=0;"
        << "bufferAFill=not_run;"
        << "bufferBDescribe=not_run;"
        << "bufferBFormat=0;"
        << "bufferBUsage=0;"
        << "bufferBStride=0;"
        << "bufferBFill=not_run;"
        << "ycbcrBufferDescribe=not_run;"
        << "ycbcrBufferFormat=0;"
        << "ycbcrBufferUsage=0;"
        << "ycbcrFormatIs420888=false;"
        << "preInitDiagnosticComposite=not_run;"
        << "preInitLastError=;"
        << "initialize=not_run;"
        << "attach=not_run;"
        << "hasSurfaceAfterAttach=false;"
        << "surfaceKindAfterAttach=none;"
        << "widthAfterAttach=0;"
        << "heightAfterAttach=0;"
        << "importBufferA=not_run;"
        << "handleA=0;"
        << "targetA=0;"
        << "importBufferB=not_run;"
        << "handleB=0;"
        << "targetB=0;"
        << "distinctHandles=false;"
        << "importYcbcr=not_run;"
        << "handleYcbcr=0;"
        << "targetYcbcr=0;"
        << "unsupportedTargetDiagnosticComposite=not_run;"
        << "unsupportedTargetLastError=;"
        << "releaseYcbcr=not_run;"
        << "releaseYcbcrFence=-1;"
        << "hasYcbcrAfterRelease=false;"
        << "invalidWeightDiagnosticComposite=not_run;"
        << "invalidWeightLastError=;"
        << "weight0DiagnosticComposite=not_run;"
        << "weight0CenterRead=not_run;"
        << "weight0CenterR=0;"
        << "weight0CenterG=0;"
        << "weight0CenterB=0;"
        << "weight0CenterA=0;"
        << "weight0CenterPixelMatches=false;"
        << "weight1DiagnosticComposite=not_run;"
        << "weight1CenterRead=not_run;"
        << "weight1CenterR=0;"
        << "weight1CenterG=0;"
        << "weight1CenterB=0;"
        << "weight1CenterA=0;"
        << "weight1CenterPixelMatches=false;"
        << "weight05DiagnosticComposite=not_run;"
        << "weight05CenterRead=not_run;"
        << "weight05CenterR=0;"
        << "weight05CenterG=0;"
        << "weight05CenterB=0;"
        << "weight05CenterA=0;"
        << "weight05CenterPixelMatches=false;"
        << "presentComposite=not_run;"
        << "presentCompositeLastError=;"
        << "releaseBufferA=not_run;"
        << "releaseBufferAFence=-1;"
        << "hasAAfterRelease=false;"
        << "releaseBufferB=not_run;"
        << "releaseBufferBFence=-1;"
        << "hasBAfterRelease=false;"
        << "postReleaseDiagnosticComposite=not_run;"
        << "postReleaseLastError=;"
        << "detach=not_run;"
        << "surfaceKindAfterDetach=none;"
        << "shutdown=not_run;"
        << "idempotentShutdown=not_run;"
        << "proofBoundary=gles_two_texture_compositor_rgba_blend_foundation_no_oes_mixed_no_product;"
        << "lastError=" << lastErrorReason;
    return oss.str();
}

} // namespace

extern "C" JNIEXPORT jstring JNICALL
Java_com_connects_vanguard_1media_1engine_bridge_VanguardNativeBridge_runAndroidDagPhase1ASGlesTwoTextureCompositorSmoke(
    JNIEnv* env,
    jobject /* this */,
    jobject jSurface,
    jobject jBufferA,
    jobject jBufferB,
    jobject jYcbcrBuffer,
    jint width,
    jint height) {

    if (!jSurface || !jBufferA || !jBufferB || !jYcbcrBuffer || width <= 0 || height <= 0) {
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

    AHardwareBuffer* ahbA = ahbFns.fromHardwareBuffer(env, jBufferA);
    AHardwareBuffer* ahbB = ahbFns.fromHardwareBuffer(env, jBufferB);
    AHardwareBuffer* ahbYcbcr = ahbFns.fromHardwareBuffer(env, jYcbcrBuffer);

    if (!ahbA || !ahbB || !ahbYcbcr) {
        ANativeWindow_release(window);
        return env->NewStringUTF(BuildFailureString("hardware_buffer_from_jobject_failed").c_str());
    }

    // 1. Validate descriptors
    AHardwareBuffer_Desc descA{};
    ahbFns.describe(ahbA, &descA);
    const bool bufferADescribeOk = (descA.width == static_cast<uint32_t>(width)) &&
                                   (descA.height == static_cast<uint32_t>(height)) &&
                                   (descA.layers == 1) &&
                                   (descA.format == AHARDWAREBUFFER_FORMAT_R8G8B8A8_UNORM) &&
                                   ((descA.usage & AHARDWAREBUFFER_USAGE_GPU_SAMPLED_IMAGE) != 0) &&
                                   ((descA.usage & AHARDWAREBUFFER_USAGE_CPU_WRITE_OFTEN) != 0) &&
                                   (descA.stride >= descA.width);

    AHardwareBuffer_Desc descB{};
    ahbFns.describe(ahbB, &descB);
    const bool bufferBDescribeOk = (descB.width == static_cast<uint32_t>(width)) &&
                                   (descB.height == static_cast<uint32_t>(height)) &&
                                   (descB.layers == 1) &&
                                   (descB.format == AHARDWAREBUFFER_FORMAT_R8G8B8A8_UNORM) &&
                                   ((descB.usage & AHARDWAREBUFFER_USAGE_GPU_SAMPLED_IMAGE) != 0) &&
                                   ((descB.usage & AHARDWAREBUFFER_USAGE_CPU_WRITE_OFTEN) != 0) &&
                                   (descB.stride >= descB.width);

    AHardwareBuffer_Desc descYcbcrBuf{};
    ahbFns.describe(ahbYcbcr, &descYcbcrBuf);
    const bool ycbcrFormatIs420888 = (descYcbcrBuf.format == AHARDWAREBUFFER_FORMAT_Y8Cb8Cr8_420);
    const bool ycbcrBufferDescribeOk = (descYcbcrBuf.width == static_cast<uint32_t>(width)) &&
                                       (descYcbcrBuf.height == static_cast<uint32_t>(height)) &&
                                       (descYcbcrBuf.layers == 1) &&
                                       ycbcrFormatIs420888 &&
                                       ((descYcbcrBuf.usage & AHARDWAREBUFFER_USAGE_GPU_SAMPLED_IMAGE) != 0);

    if (!bufferADescribeOk || !bufferBDescribeOk || !ycbcrBufferDescribeOk) {
        ANativeWindow_release(window);
        return env->NewStringUTF(BuildFailureString("hardware_buffer_descriptor_mismatch").c_str());
    }

    // 2. CPU-fill bufferA solid red [255, 0, 0, 255] and bufferB solid blue [0, 0, 255, 255]
    auto fillBuffer = [&](AHardwareBuffer* buf, const AHardwareBuffer_Desc& desc, uint8_t r, uint8_t g, uint8_t b, uint8_t a) -> bool {
        void* writeAddr = nullptr;
        int32_t lockRes = ahbFns.lock(buf, AHARDWAREBUFFER_USAGE_CPU_WRITE_OFTEN, -1, nullptr, &writeAddr);
        if (lockRes != 0 || !writeAddr) {
            return false;
        }
        uint8_t* base = static_cast<uint8_t*>(writeAddr);
        for (uint32_t y = 0; y < desc.height; ++y) {
            uint8_t* row = base + y * desc.stride * 4;
            for (uint32_t x = 0; x < desc.width; ++x) {
                uint8_t* pixel = row + x * 4;
                pixel[0] = r;
                pixel[1] = g;
                pixel[2] = b;
                pixel[3] = a;
            }
        }
        int32_t fence = -1;
        int32_t unlockRes = ahbFns.unlock(buf, &fence);
        if (unlockRes != 0) {
            return false;
        }
        if (fence >= 0) {
            struct pollfd pfd{};
            pfd.fd = fence;
            pfd.events = POLLIN;
            int pollRes = poll(&pfd, 1, 1000);
            close(fence);
            if (pollRes <= 0 || (pfd.revents & (POLLERR | POLLNVAL))) {
                return false;
            }
        }
        return true;
    };

    const bool bufferAFillOk = fillBuffer(ahbA, descA, 255, 0, 0, 255);
    const bool bufferBFillOk = fillBuffer(ahbB, descB, 0, 0, 255, 255);

    if (!bufferAFillOk || !bufferBFillOk) {
        ANativeWindow_release(window);
        return env->NewStringUTF(BuildFailureString("hardware_buffer_fill_failed").c_str());
    }

    vanguard::render::GlesBackend backend;

    // 3. Pre-init lane: diagnosticCompositeFramesForReadback fails with backend_not_initialized
    const bool preInitRes = backend.diagnosticCompositeFramesForReadback(
        vanguard::render::kInvalidHardwareBufferHandle,
        vanguard::render::kInvalidHardwareBufferHandle,
        0.5f,
        vanguard::render::VideoFrameTransform{},
        vanguard::render::VideoFrameTransform{});
    const std::string preInitLastError = SanitizeString(backend.lastError());
    const bool preInitDiagnosticCompositeOk = (!preInitRes && preInitLastError == "backend_not_initialized");

    // 4. Initialize backend and attach surface
    const bool initOk = backend.initialize();
    const bool isInitialized = backend.isInitialized();
    const int clientVersion = backend.clientVersion();
    const std::string vendor = SanitizeString(backend.diagnosticVendor());
    const std::string renderer = SanitizeString(backend.diagnosticRenderer());
    const std::string version = SanitizeString(backend.diagnosticVersion());
    const bool initCheckOk = initOk && isInitialized && (clientVersion >= 2) &&
                             !vendor.empty() && !renderer.empty() && !version.empty();

    const bool attachOk = backend.attachSurface(window, static_cast<uint32_t>(width), static_cast<uint32_t>(height));
    const bool hasSurfaceAfterAttach = backend.hasSurface();
    const std::string surfaceKindAfterAttach = SanitizeString(backend.activeSurfaceKind());
    const uint32_t widthAfterAttach = backend.surfaceWidth();
    const uint32_t heightAfterAttach = backend.surfaceHeight();
    const bool attachCheckOk = attachOk && hasSurfaceAfterAttach &&
                               (surfaceKindAfterAttach == "window") &&
                               (widthAfterAttach == static_cast<uint32_t>(width)) &&
                               (heightAfterAttach == static_cast<uint32_t>(height));

    // 5. Import bufferA and bufferB; assert handles valid, distinct, target 0x0DE1 for each
    vanguard::render::HardwareBufferHandle handleA = vanguard::render::kInvalidHardwareBufferHandle;
    vanguard::render::HardwareBufferDescriptor descImportA{};
    const auto resImportA = backend.importHardwareBuffer(ahbA, -1, &handleA, &descImportA);
    const bool hasAAfterImport = backend.hasHardwareBuffer(handleA);
    const uint32_t targetA = backend.diagnosticTextureTargetForHardwareBuffer(handleA);
    const bool importBufferAOk = (resImportA == vanguard::render::HardwareBufferImportResult::kSuccess) &&
                                 (handleA != vanguard::render::kInvalidHardwareBufferHandle) &&
                                 hasAAfterImport &&
                                 (targetA == 0x0DE1);

    vanguard::render::HardwareBufferHandle handleB = vanguard::render::kInvalidHardwareBufferHandle;
    vanguard::render::HardwareBufferDescriptor descImportB{};
    const auto resImportB = backend.importHardwareBuffer(ahbB, -1, &handleB, &descImportB);
    const bool hasBAfterImport = backend.hasHardwareBuffer(handleB);
    const uint32_t targetB = backend.diagnosticTextureTargetForHardwareBuffer(handleB);
    const bool importBufferBOk = (resImportB == vanguard::render::HardwareBufferImportResult::kSuccess) &&
                                 (handleB != vanguard::render::kInvalidHardwareBufferHandle) &&
                                 hasBAfterImport &&
                                 (targetB == 0x0DE1);

    const bool distinctHandles = (handleA != handleB);

    // 6. Import ycbcrBuffer; assert target 0x8D65, then test unsupported target fail-closed lane, then release ycbcr
    vanguard::render::HardwareBufferHandle handleYcbcr = vanguard::render::kInvalidHardwareBufferHandle;
    vanguard::render::HardwareBufferDescriptor descImportYcbcr{};
    const auto resImportYcbcr = backend.importHardwareBuffer(ahbYcbcr, -1, &handleYcbcr, &descImportYcbcr);
    const bool hasYcbcrAfterImport = backend.hasHardwareBuffer(handleYcbcr);
    const uint32_t targetYcbcr = backend.diagnosticTextureTargetForHardwareBuffer(handleYcbcr);
    const bool importYcbcrOk = (resImportYcbcr == vanguard::render::HardwareBufferImportResult::kSuccess) &&
                               (handleYcbcr != vanguard::render::kInvalidHardwareBufferHandle) &&
                               hasYcbcrAfterImport &&
                               (targetYcbcr == 0x8D65);

    const bool unsupportedTargetRes = backend.diagnosticCompositeFramesForReadback(
        handleA, handleYcbcr, 0.5f,
        vanguard::render::VideoFrameTransform{},
        vanguard::render::VideoFrameTransform{});
    const std::string unsupportedTargetLastError = SanitizeString(backend.lastError());
    const bool unsupportedTargetOk = (!unsupportedTargetRes &&
        unsupportedTargetLastError == "gles_two_texture_compositor_unsupported_texture_target");

    int releaseFenceYcbcr = -999;
    const auto resReleaseYcbcr = backend.releaseHardwareBuffer(handleYcbcr, &releaseFenceYcbcr);
    const bool hasYcbcrAfterRelease = backend.hasHardwareBuffer(handleYcbcr);
    const bool releaseYcbcrOk = (resReleaseYcbcr == vanguard::render::HardwareBufferImportResult::kSuccess) &&
                                (releaseFenceYcbcr >= -1) &&
                                !hasYcbcrAfterRelease;
    if (releaseFenceYcbcr >= 0) {
        close(releaseFenceYcbcr);
    }

    // 7. Invalid weight lane: NaN weight fails with gles_two_texture_compositor_invalid_weight
    const float nanWeight = std::numeric_limits<float>::quiet_NaN();
    const bool invalidWeightRes = backend.diagnosticCompositeFramesForReadback(
        handleA, handleB, nanWeight,
        vanguard::render::VideoFrameTransform{},
        vanguard::render::VideoFrameTransform{});
    const std::string invalidWeightLastError = SanitizeString(backend.lastError());
    const bool invalidWeightOk = (!invalidWeightRes &&
        invalidWeightLastError == "gles_two_texture_compositor_invalid_weight");

    // 8. Weight lanes using two RGBA handles
    // weight 0.0: red > 200, green < 50, blue < 50, alpha > 200
    const bool weight0Res = backend.diagnosticCompositeFramesForReadback(
        handleA, handleB, 0.0f,
        vanguard::render::VideoFrameTransform{},
        vanguard::render::VideoFrameTransform{});
    std::vector<uint8_t> pixelWeight0(4, 0);
    const bool weight0ReadRes = backend.diagnosticReadPixels(
        static_cast<uint32_t>(width / 2),
        static_cast<uint32_t>(height / 2),
        1, 1,
        pixelWeight0.data(),
        4);
    const int weight0CenterR = static_cast<int>(pixelWeight0[0]);
    const int weight0CenterG = static_cast<int>(pixelWeight0[1]);
    const int weight0CenterB = static_cast<int>(pixelWeight0[2]);
    const int weight0CenterA = static_cast<int>(pixelWeight0[3]);
    const bool weight0PixelMatches = (weight0CenterR > 200) &&
                                     (weight0CenterG < 50) &&
                                     (weight0CenterB < 50) &&
                                     (weight0CenterA > 200);
    const bool laneWeight0Ok = weight0Res && weight0ReadRes && weight0PixelMatches;

    // weight 1.0: red < 50, green < 50, blue > 200, alpha > 200
    const bool weight1Res = backend.diagnosticCompositeFramesForReadback(
        handleA, handleB, 1.0f,
        vanguard::render::VideoFrameTransform{},
        vanguard::render::VideoFrameTransform{});
    std::vector<uint8_t> pixelWeight1(4, 0);
    const bool weight1ReadRes = backend.diagnosticReadPixels(
        static_cast<uint32_t>(width / 2),
        static_cast<uint32_t>(height / 2),
        1, 1,
        pixelWeight1.data(),
        4);
    const int weight1CenterR = static_cast<int>(pixelWeight1[0]);
    const int weight1CenterG = static_cast<int>(pixelWeight1[1]);
    const int weight1CenterB = static_cast<int>(pixelWeight1[2]);
    const int weight1CenterA = static_cast<int>(pixelWeight1[3]);
    const bool weight1PixelMatches = (weight1CenterR < 50) &&
                                     (weight1CenterG < 50) &&
                                     (weight1CenterB > 200) &&
                                     (weight1CenterA > 200);
    const bool laneWeight1Ok = weight1Res && weight1ReadRes && weight1PixelMatches;

    // weight 0.5: red in [100, 155], green < 50, blue in [100, 155], alpha > 200
    const bool weight05Res = backend.diagnosticCompositeFramesForReadback(
        handleA, handleB, 0.5f,
        vanguard::render::VideoFrameTransform{},
        vanguard::render::VideoFrameTransform{});
    std::vector<uint8_t> pixelWeight05(4, 0);
    const bool weight05ReadRes = backend.diagnosticReadPixels(
        static_cast<uint32_t>(width / 2),
        static_cast<uint32_t>(height / 2),
        1, 1,
        pixelWeight05.data(),
        4);
    const int weight05CenterR = static_cast<int>(pixelWeight05[0]);
    const int weight05CenterG = static_cast<int>(pixelWeight05[1]);
    const int weight05CenterB = static_cast<int>(pixelWeight05[2]);
    const int weight05CenterA = static_cast<int>(pixelWeight05[3]);
    const bool weight05PixelMatches = (weight05CenterR >= 100 && weight05CenterR <= 155) &&
                                      (weight05CenterG < 50) &&
                                      (weight05CenterB >= 100 && weight05CenterB <= 155) &&
                                      (weight05CenterA > 200);
    const bool laneWeight05Ok = weight05Res && weight05ReadRes && weight05PixelMatches;

    // 9. Present lane: diagnosticPresentCompositeFrames returns true
    const bool presentCompositeRes = backend.diagnosticPresentCompositeFrames(
        handleA, handleB, 0.5f,
        vanguard::render::VideoFrameTransform{},
        vanguard::render::VideoFrameTransform{});
    const std::string presentCompositeLastError = SanitizeString(backend.lastError());
    const bool presentCompositeOk = presentCompositeRes &&
        (presentCompositeLastError.empty() || presentCompositeLastError == "none");

    // 10. Release A and B buffers
    int releaseFenceA = -999;
    const auto resReleaseA = backend.releaseHardwareBuffer(handleA, &releaseFenceA);
    const bool hasAAfterRelease = backend.hasHardwareBuffer(handleA);
    const bool releaseAOk = (resReleaseA == vanguard::render::HardwareBufferImportResult::kSuccess) &&
                            (releaseFenceA >= -1) &&
                            !hasAAfterRelease;
    if (releaseFenceA >= 0) {
        close(releaseFenceA);
    }

    int releaseFenceB = -999;
    const auto resReleaseB = backend.releaseHardwareBuffer(handleB, &releaseFenceB);
    const bool hasBAfterRelease = backend.hasHardwareBuffer(handleB);
    const bool releaseBOk = (resReleaseB == vanguard::render::HardwareBufferImportResult::kSuccess) &&
                            (releaseFenceB >= -1) &&
                            !hasBAfterRelease;
    if (releaseFenceB >= 0) {
        close(releaseFenceB);
    }

    // 11. Post-release lane: readback seam fails with invalid_buffer_handle
    const bool postReleaseRes = backend.diagnosticCompositeFramesForReadback(
        handleA, handleB, 0.5f,
        vanguard::render::VideoFrameTransform{},
        vanguard::render::VideoFrameTransform{});
    const std::string postReleaseLastError = SanitizeString(backend.lastError());
    const bool postReleaseOk = (!postReleaseRes && postReleaseLastError == "invalid_buffer_handle");

    // 12. Detach, shutdown, idempotent shutdown
    backend.detachSurface();
    const bool hasSurfaceAfterDetach = backend.hasSurface();
    const std::string surfaceKindAfterDetach = SanitizeString(backend.activeSurfaceKind());
    const bool detachOk = !hasSurfaceAfterDetach && (surfaceKindAfterDetach == "offscreen");

    backend.shutdown();
    const bool shutdownOk = !backend.isInitialized();

    backend.shutdown();
    const bool idempotentShutdownOk = !backend.isInitialized();

    ANativeWindow_release(window);

    const bool allChecksPass = bufferADescribeOk &&
                               bufferBDescribeOk &&
                               ycbcrBufferDescribeOk &&
                               bufferAFillOk &&
                               bufferBFillOk &&
                               preInitDiagnosticCompositeOk &&
                               initCheckOk &&
                               attachCheckOk &&
                               importBufferAOk &&
                               importBufferBOk &&
                               distinctHandles &&
                               importYcbcrOk &&
                               unsupportedTargetOk &&
                               releaseYcbcrOk &&
                               invalidWeightOk &&
                               laneWeight0Ok &&
                               laneWeight1Ok &&
                               laneWeight05Ok &&
                               presentCompositeOk &&
                               releaseAOk &&
                               releaseBOk &&
                               postReleaseOk &&
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
        << "bufferADescribe=" << (bufferADescribeOk ? "success" : "failed") << ";"
        << "bufferAFormat=" << descA.format << ";"
        << "bufferAUsage=" << descA.usage << ";"
        << "bufferAStride=" << descA.stride << ";"
        << "bufferAFill=" << (bufferAFillOk ? "success" : "failed") << ";"
        << "bufferBDescribe=" << (bufferBDescribeOk ? "success" : "failed") << ";"
        << "bufferBFormat=" << descB.format << ";"
        << "bufferBUsage=" << descB.usage << ";"
        << "bufferBStride=" << descB.stride << ";"
        << "bufferBFill=" << (bufferBFillOk ? "success" : "failed") << ";"
        << "ycbcrBufferDescribe=" << (ycbcrBufferDescribeOk ? "success" : "failed") << ";"
        << "ycbcrBufferFormat=" << descYcbcrBuf.format << ";"
        << "ycbcrBufferUsage=" << descYcbcrBuf.usage << ";"
        << "ycbcrFormatIs420888=" << (ycbcrFormatIs420888 ? "true" : "false") << ";"
        << "preInitDiagnosticComposite=" << (preInitDiagnosticCompositeOk ? "rejected_as_expected" : "failed") << ";"
        << "preInitLastError=" << preInitLastError << ";"
        << "initialize=" << (initCheckOk ? "success" : "failed") << ";"
        << "attach=" << (attachCheckOk ? "success" : "failed") << ";"
        << "hasSurfaceAfterAttach=" << (hasSurfaceAfterAttach ? "true" : "false") << ";"
        << "surfaceKindAfterAttach=" << surfaceKindAfterAttach << ";"
        << "widthAfterAttach=" << widthAfterAttach << ";"
        << "heightAfterAttach=" << heightAfterAttach << ";"
        << "importBufferA=" << (importBufferAOk ? "success" : "failed") << ";"
        << "handleA=" << handleA << ";"
        << "targetA=" << targetA << ";"
        << "importBufferB=" << (importBufferBOk ? "success" : "failed") << ";"
        << "handleB=" << handleB << ";"
        << "targetB=" << targetB << ";"
        << "distinctHandles=" << (distinctHandles ? "true" : "false") << ";"
        << "importYcbcr=" << (importYcbcrOk ? "success" : "failed") << ";"
        << "handleYcbcr=" << handleYcbcr << ";"
        << "targetYcbcr=" << targetYcbcr << ";"
        << "unsupportedTargetDiagnosticComposite=" << (unsupportedTargetOk ? "rejected_as_expected" : "failed") << ";"
        << "unsupportedTargetLastError=" << unsupportedTargetLastError << ";"
        << "releaseYcbcr=" << (releaseYcbcrOk ? "success" : "failed") << ";"
        << "releaseYcbcrFence=" << releaseFenceYcbcr << ";"
        << "hasYcbcrAfterRelease=" << (hasYcbcrAfterRelease ? "true" : "false") << ";"
        << "invalidWeightDiagnosticComposite=" << (invalidWeightOk ? "rejected_as_expected" : "failed") << ";"
        << "invalidWeightLastError=" << invalidWeightLastError << ";"
        << "weight0DiagnosticComposite=" << (weight0Res ? "success" : "failed") << ";"
        << "weight0CenterRead=" << (weight0ReadRes ? "success" : "failed") << ";"
        << "weight0CenterR=" << weight0CenterR << ";"
        << "weight0CenterG=" << weight0CenterG << ";"
        << "weight0CenterB=" << weight0CenterB << ";"
        << "weight0CenterA=" << weight0CenterA << ";"
        << "weight0CenterPixelMatches=" << (weight0PixelMatches ? "true" : "false") << ";"
        << "weight1DiagnosticComposite=" << (weight1Res ? "success" : "failed") << ";"
        << "weight1CenterRead=" << (weight1ReadRes ? "success" : "failed") << ";"
        << "weight1CenterR=" << weight1CenterR << ";"
        << "weight1CenterG=" << weight1CenterG << ";"
        << "weight1CenterB=" << weight1CenterB << ";"
        << "weight1CenterA=" << weight1CenterA << ";"
        << "weight1CenterPixelMatches=" << (weight1PixelMatches ? "true" : "false") << ";"
        << "weight05DiagnosticComposite=" << (weight05Res ? "success" : "failed") << ";"
        << "weight05CenterRead=" << (weight05ReadRes ? "success" : "failed") << ";"
        << "weight05CenterR=" << weight05CenterR << ";"
        << "weight05CenterG=" << weight05CenterG << ";"
        << "weight05CenterB=" << weight05CenterB << ";"
        << "weight05CenterA=" << weight05CenterA << ";"
        << "weight05CenterPixelMatches=" << (weight05PixelMatches ? "true" : "false") << ";"
        << "presentComposite=" << (presentCompositeOk ? "success" : "failed") << ";"
        << "presentCompositeLastError=" << (presentCompositeLastError.empty() ? "none" : presentCompositeLastError) << ";"
        << "releaseBufferA=" << (releaseAOk ? "success" : "failed") << ";"
        << "releaseBufferAFence=" << releaseFenceA << ";"
        << "hasAAfterRelease=" << (hasAAfterRelease ? "true" : "false") << ";"
        << "releaseBufferB=" << (releaseBOk ? "success" : "failed") << ";"
        << "releaseBufferBFence=" << releaseFenceB << ";"
        << "hasBAfterRelease=" << (hasBAfterRelease ? "true" : "false") << ";"
        << "postReleaseDiagnosticComposite=" << (postReleaseOk ? "rejected_as_expected" : "failed") << ";"
        << "postReleaseLastError=" << postReleaseLastError << ";"
        << "detach=" << (detachOk ? "success" : "failed") << ";"
        << "surfaceKindAfterDetach=" << surfaceKindAfterDetach << ";"
        << "shutdown=" << (shutdownOk ? "success" : "failed") << ";"
        << "idempotentShutdown=" << (idempotentShutdownOk ? "success" : "failed") << ";"
        << "proofBoundary=gles_two_texture_compositor_rgba_blend_foundation_no_oes_mixed_no_product;"
        << "lastError=" << (backendLastError.empty() ? "none" : backendLastError);

    return env->NewStringUTF(oss.str().c_str());
}
