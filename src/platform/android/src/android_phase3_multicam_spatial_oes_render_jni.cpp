// P3-MULTICAM-NODE-GLES-OES-SPATIAL-RENDER: GLES-first spatial multi-texture
// diagnostic render pass OES physical proof JNI bridge.
//
// Android-only translation unit added via CMake target_sources block. Bounded
// extension of the existing RGBA-only spatial route
// (android_phase3_multicam_spatial_render_jni.cpp): reuses the same
// composition-root pattern (vanguard::compositors::ComputeMultiCamLayout()
// top-left/Y-down normalized layout math converted into bottom-left pixel
// rectangles consumed by GlesBackend's diagnostic composite seams) but
// additionally imports two YCBCR_420_888 GPU-sampled AHardwareBuffer
// instances (imported as GL_TEXTURE_EXTERNAL_OES per gles_hardware_buffer_
// imports.cpp) and exercises 2D+OES, OES+2D, and OES+OES spatial lane
// permutations. Neither vanguard_render_gles nor gles_backend.cpp/.h include
// any compositors header; only this JNI translation unit links
// vanguard_compositors and vanguard_render_gles together.
//
// Non-claim: render-only diagnostic proof. No camera open, no Vulkan, no
// recording/export, no product UI, no corner radius, no secondary opacity.
// OES lanes assert render/readback success, resolved texture target
// (0x8D65), and fail-closed cleanup only -- YCBCR buffers are never CPU-
// filled, so no deterministic color-correctness is claimed for their sampled
// content (mirrors the existing gles_mixed_texture_compositor_smoke_jni.cpp
// OES lane precedent). The RGBA baseline buffers remain CPU-filled solid
// red/blue and are checked for deterministic color content wherever they
// appear in a lane.
//
// JNI entry point:
//   runAndroidDagPhase3MultiCamSpatialGlesOesRenderSmoke -> jstring

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
#include <sstream>
#include <string>

#include "vanguard/compositors/multi_cam_compositor_node.h"
#include "vanguard/render/gles_backend.h"
#include "vanguard/render/render_transform.h"

namespace {

using vanguard::compositors::ComputeMultiCamLayout;
using vanguard::compositors::MultiCamLayout;
using vanguard::compositors::MultiCamLayoutMode;
using vanguard::compositors::MultiCamLayoutResult;
using vanguard::compositors::MultiCamPiPAnchor;
using vanguard::compositors::MultiCamSplitDirection;
using vanguard::compositors::NormalizedRect;
using vanguard::render::GlesBackend;
using vanguard::render::GlesViewportRectPx;
using vanguard::render::HardwareBufferHandle;
using vanguard::render::HardwareBufferImportResult;
using vanguard::render::VideoFrameTransform;

constexpr const char* kProofBoundary =
    "native_multicam_spatial_gles_oes_texture_layout_render_readback_only_no_vulkan_no_camera_no_opacity_no_corner_radius_no_recording_no_product";

constexpr uint32_t kTextureTarget2D = 0x0DE1;
constexpr uint32_t kTextureTargetExternalOes = 0x8D65;

// ---------------------------------------------------------------------------
// AHardwareBuffer native symbol resolution (mirrors the existing pattern in
// android_phase3_multicam_spatial_render_jni.cpp /
// android_gles_mixed_texture_compositor_smoke_jni.cpp).
// ---------------------------------------------------------------------------

using FnAHardwareBuffer_fromHardwareBuffer = AHardwareBuffer* (*)(JNIEnv*, jobject);
using FnAHardwareBuffer_describe = void (*)(const AHardwareBuffer*, AHardwareBuffer_Desc*);
using FnAHardwareBuffer_lock = int32_t (*)(AHardwareBuffer*, uint64_t, int32_t, const ARect*, void**);
using FnAHardwareBuffer_unlock = int32_t (*)(AHardwareBuffer*, int32_t*);

struct NativeHardwareBufferFunctions {
    FnAHardwareBuffer_fromHardwareBuffer fromHardwareBuffer = nullptr;
    FnAHardwareBuffer_describe describe = nullptr;
    FnAHardwareBuffer_lock lock = nullptr;
    FnAHardwareBuffer_unlock unlock = nullptr;
    bool isValid() const { return fromHardwareBuffer && describe && lock && unlock; }
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
    if (!input) return "";
    std::string s(input);
    for (char& c : s) {
        if (c == ';' || c == '\n' || c == '\r') {
            c = '_';
        }
    }
    return s;
}

bool FillBuffer(const NativeHardwareBufferFunctions& fns, AHardwareBuffer* buf,
                const AHardwareBuffer_Desc& desc, uint8_t r, uint8_t g, uint8_t b, uint8_t a) {
    void* writeAddr = nullptr;
    int32_t lockRes = fns.lock(buf, AHARDWAREBUFFER_USAGE_CPU_WRITE_OFTEN, -1, nullptr, &writeAddr);
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
    int32_t unlockRes = fns.unlock(buf, &fence);
    if (unlockRes != 0) {
        return false;
    }
    if (fence >= 0) {
        struct pollfd pfd {};
        pfd.fd = fence;
        pfd.events = POLLIN;
        int pollRes = poll(&pfd, 1, 1000);
        close(fence);
        if (pollRes <= 0 || (pfd.revents & (POLLERR | POLLNVAL))) {
            return false;
        }
    }
    return true;
}

// ---------------------------------------------------------------------------
// Normalized (top-left origin, Y-down) <-> pixel (bottom-left origin,
// Y-up) conversion. Duplicated from android_phase3_multicam_spatial_render_jni.cpp
// (private anonymous-namespace helper in that TU, not shared through a
// header) -- same exact rounding rule: round the left/right (and top/bottom)
// edges independently via std::lround, then take widths/heights as the
// *difference* of the rounded edges. Every field is clamped finite into
// [0,1] first; nonfinite fields, an out-of-bounds rect after clamping, or a
// non-positive rounded width/height all fail closed.
// ---------------------------------------------------------------------------

struct RectConversionResult {
    bool ok = false;
    GlesViewportRectPx rect{};
    std::string error;
};

double ClampUnit(double v) {
    if (v < 0.0) return 0.0;
    if (v > 1.0) return 1.0;
    return v;
}

RectConversionResult ConvertNormalizedRectToPixelRect(const NormalizedRect& rect,
                                                       int32_t canvasWidth,
                                                       int32_t canvasHeight) {
    RectConversionResult result;
    if (!std::isfinite(rect.x) || !std::isfinite(rect.y) ||
        !std::isfinite(rect.width) || !std::isfinite(rect.height)) {
        result.error = "multicam_spatial_oes_rect_nonfinite";
        return result;
    }

    const double x = ClampUnit(rect.x);
    const double y = ClampUnit(rect.y);
    const double w = ClampUnit(rect.width);
    const double h = ClampUnit(rect.height);

    constexpr double kBoundsEpsilon = 1e-6;
    if (x + w > 1.0 + kBoundsEpsilon || y + h > 1.0 + kBoundsEpsilon) {
        result.error = "multicam_spatial_oes_rect_out_of_bounds_after_clamp";
        return result;
    }

    const double canvasW = static_cast<double>(canvasWidth);
    const double canvasH = static_cast<double>(canvasHeight);

    const long left = std::lround(x * canvasW);
    const long right = std::lround((x + w) * canvasW);
    const long top = std::lround(y * canvasH);
    const long bottom = std::lround((y + h) * canvasH);

    const long pixelWidth = right - left;
    const long pixelHeight = bottom - top;
    if (pixelWidth <= 0 || pixelHeight <= 0) {
        result.error = "multicam_spatial_oes_rect_nonpositive_after_round";
        return result;
    }

    result.rect.x = static_cast<int32_t>(left);
    result.rect.yBottom = static_cast<int32_t>(canvasHeight - bottom);
    result.rect.width = static_cast<uint32_t>(pixelWidth);
    result.rect.height = static_cast<uint32_t>(pixelHeight);
    result.ok = true;
    return result;
}

void NormalizedPointToBottomLeftPixel(double normX, double normY, int32_t width, int32_t height,
                                      uint32_t* outX, uint32_t* outY) {
    long xi = std::lround(ClampUnit(normX) * width);
    long yTopLeft = std::lround(ClampUnit(normY) * height);
    if (xi >= width) xi = width - 1;
    if (xi < 0) xi = 0;
    if (yTopLeft >= height) yTopLeft = height - 1;
    if (yTopLeft < 0) yTopLeft = 0;
    *outX = static_cast<uint32_t>(xi);
    *outY = static_cast<uint32_t>(height - 1 - yTopLeft);
}

struct PixelSample {
    bool readOk = false;
    uint8_t rgba[4] = {0, 0, 0, 0};
};

PixelSample SampleNormalizedPoint(GlesBackend& backend, double normX, double normY,
                                  int32_t width, int32_t height) {
    PixelSample sample;
    uint32_t px = 0;
    uint32_t py = 0;
    NormalizedPointToBottomLeftPixel(normX, normY, width, height, &px, &py);
    sample.readOk = backend.diagnosticReadPixels(px, py, 1, 1, sample.rgba, 4);
    return sample;
}

bool IsRedish(const uint8_t rgba[4]) {
    return rgba[0] > 200 && rgba[1] < 50 && rgba[2] < 50 && rgba[3] > 200;
}

bool IsBlueish(const uint8_t rgba[4]) {
    return rgba[0] < 50 && rgba[1] < 50 && rgba[2] > 200 && rgba[3] > 200;
}

MultiCamLayout MakeSplitLayout(double canvasWidth, double canvasHeight,
                               MultiCamSplitDirection direction, double splitRatio) {
    MultiCamLayout layout{};
    layout.mode = MultiCamLayoutMode::kSplitScreen;
    layout.canvasWidth = canvasWidth;
    layout.canvasHeight = canvasHeight;
    layout.pip.anchor = MultiCamPiPAnchor::kFreeFloating;
    layout.pip.centerX = 0.5;
    layout.pip.centerY = 0.5;
    layout.pip.normalizedWidth = 0.35;
    layout.pip.aspectRatio = 9.0 / 16.0;
    layout.pip.marginFraction = 0.05;
    layout.pip.cornerRadiusFractionOfCanvasWidth = 0.0;
    layout.pip.opacity = 1.0;
    layout.split.direction = direction;
    layout.split.splitRatio = splitRatio;
    return layout;
}

std::string BuildFailureString(const char* lastErrorReason) {
    std::ostringstream oss;
    oss << "status=FAIL;"
        << "width=0;height=0;"
        << "clientVersion=0;vendor=;renderer=;version=;"
        << "rgbaADescribe=not_run;rgbaAFill=not_run;"
        << "rgbaBDescribe=not_run;rgbaBFill=not_run;"
        << "ycbcrADescribe=not_run;ycbcrAFormatIs420888=false;"
        << "ycbcrBDescribe=not_run;ycbcrBFormatIs420888=false;"
        << "preInitLane=not_run;preInitLastError=;"
        << "initialize=not_run;attach=not_run;"
        << "importRgbaA=not_run;handleRgbaA=0;targetRgbaA=0;"
        << "importRgbaB=not_run;handleRgbaB=0;targetRgbaB=0;"
        << "importYcbcrA=not_run;handleYcbcrA=0;targetYcbcrA=0;"
        << "importYcbcrB=not_run;handleYcbcrB=0;targetYcbcrB=0;"
        << "invalidHandleLane=not_run;invalidHandleLastError=;"
        << "invalidRectLane=not_run;invalidRectLastError=;"
        << "twoDOesOk=false;twoDOesTargetOk=false;twoDOesLastError=;"
        << "oesTwoDOk=false;oesTwoDTargetOk=false;oesTwoDLastError=;"
        << "oesOesOk=false;oesOesTargetOk=false;oesOesLastError=;"
        << "presentOesOes=not_run;presentOesOesLastError=;"
        << "releaseRgbaA=not_run;releaseRgbaAFence=-1;hasRgbaAAfterRelease=false;"
        << "releaseRgbaB=not_run;releaseRgbaBFence=-1;hasRgbaBAfterRelease=false;"
        << "releaseYcbcrA=not_run;releaseYcbcrAFence=-1;hasYcbcrAAfterRelease=false;"
        << "releaseYcbcrB=not_run;releaseYcbcrBFence=-1;hasYcbcrBAfterRelease=false;"
        << "postReleaseLane=not_run;postReleaseLastError=;"
        << "detach=not_run;shutdown=not_run;idempotentShutdown=not_run;"
        << "proofBoundary=" << kProofBoundary << ";"
        << "lastError=" << lastErrorReason;
    return oss.str();
}

} // namespace

extern "C" JNIEXPORT jstring JNICALL
Java_com_connects_vanguard_1media_1engine_bridge_VanguardNativeBridge_runAndroidDagPhase3MultiCamSpatialGlesOesRenderSmoke(
    JNIEnv* env,
    jobject /* this */,
    jobject jSurface,
    jobject jRgbaBufferA,
    jobject jRgbaBufferB,
    jobject jYcbcrBufferA,
    jobject jYcbcrBufferB,
    jint width,
    jint height) {

    if (!jSurface || !jRgbaBufferA || !jRgbaBufferB || !jYcbcrBufferA || !jYcbcrBufferB ||
        width <= 0 || height <= 0) {
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

    AHardwareBuffer* ahbRgbaA = ahbFns.fromHardwareBuffer(env, jRgbaBufferA);
    AHardwareBuffer* ahbRgbaB = ahbFns.fromHardwareBuffer(env, jRgbaBufferB);
    AHardwareBuffer* ahbYcbcrA = ahbFns.fromHardwareBuffer(env, jYcbcrBufferA);
    AHardwareBuffer* ahbYcbcrB = ahbFns.fromHardwareBuffer(env, jYcbcrBufferB);
    if (!ahbRgbaA || !ahbRgbaB || !ahbYcbcrA || !ahbYcbcrB) {
        ANativeWindow_release(window);
        return env->NewStringUTF(BuildFailureString("hardware_buffer_from_jobject_failed").c_str());
    }

    AHardwareBuffer_Desc descRgbaA{};
    ahbFns.describe(ahbRgbaA, &descRgbaA);
    const bool rgbaADescribeOk = (descRgbaA.width == static_cast<uint32_t>(width)) &&
                                 (descRgbaA.height == static_cast<uint32_t>(height)) &&
                                 (descRgbaA.layers == 1) &&
                                 (descRgbaA.format == AHARDWAREBUFFER_FORMAT_R8G8B8A8_UNORM) &&
                                 ((descRgbaA.usage & AHARDWAREBUFFER_USAGE_GPU_SAMPLED_IMAGE) != 0) &&
                                 ((descRgbaA.usage & AHARDWAREBUFFER_USAGE_CPU_WRITE_OFTEN) != 0) &&
                                 (descRgbaA.stride >= descRgbaA.width);

    AHardwareBuffer_Desc descRgbaB{};
    ahbFns.describe(ahbRgbaB, &descRgbaB);
    const bool rgbaBDescribeOk = (descRgbaB.width == static_cast<uint32_t>(width)) &&
                                 (descRgbaB.height == static_cast<uint32_t>(height)) &&
                                 (descRgbaB.layers == 1) &&
                                 (descRgbaB.format == AHARDWAREBUFFER_FORMAT_R8G8B8A8_UNORM) &&
                                 ((descRgbaB.usage & AHARDWAREBUFFER_USAGE_GPU_SAMPLED_IMAGE) != 0) &&
                                 ((descRgbaB.usage & AHARDWAREBUFFER_USAGE_CPU_WRITE_OFTEN) != 0) &&
                                 (descRgbaB.stride >= descRgbaB.width);

    AHardwareBuffer_Desc descYcbcrA{};
    ahbFns.describe(ahbYcbcrA, &descYcbcrA);
    const bool ycbcrAFormatIs420888 = (descYcbcrA.format == AHARDWAREBUFFER_FORMAT_Y8Cb8Cr8_420);
    const bool ycbcrADescribeOk = (descYcbcrA.width == static_cast<uint32_t>(width)) &&
                                  (descYcbcrA.height == static_cast<uint32_t>(height)) &&
                                  (descYcbcrA.layers == 1) &&
                                  ycbcrAFormatIs420888 &&
                                  ((descYcbcrA.usage & AHARDWAREBUFFER_USAGE_GPU_SAMPLED_IMAGE) != 0);

    AHardwareBuffer_Desc descYcbcrB{};
    ahbFns.describe(ahbYcbcrB, &descYcbcrB);
    const bool ycbcrBFormatIs420888 = (descYcbcrB.format == AHARDWAREBUFFER_FORMAT_Y8Cb8Cr8_420);
    const bool ycbcrBDescribeOk = (descYcbcrB.width == static_cast<uint32_t>(width)) &&
                                  (descYcbcrB.height == static_cast<uint32_t>(height)) &&
                                  (descYcbcrB.layers == 1) &&
                                  ycbcrBFormatIs420888 &&
                                  ((descYcbcrB.usage & AHARDWAREBUFFER_USAGE_GPU_SAMPLED_IMAGE) != 0);

    if (!rgbaADescribeOk || !rgbaBDescribeOk || !ycbcrADescribeOk || !ycbcrBDescribeOk) {
        ANativeWindow_release(window);
        return env->NewStringUTF(BuildFailureString("hardware_buffer_descriptor_mismatch").c_str());
    }

    // Native fills rgbaBufferA solid opaque red and rgbaBufferB solid opaque
    // blue; the YCBCR buffers are never CPU-filled (matches the existing
    // gles_mixed_texture_compositor_smoke_jni.cpp OES precedent -- no
    // evidence that CPU-locking a GPU_SAMPLED_IMAGE-only YCBCR_420_888
    // buffer is safe), so OES lanes assert render/readback success and
    // resolved texture target only, never deterministic color content.
    const bool rgbaAFillOk = FillBuffer(ahbFns, ahbRgbaA, descRgbaA, 255, 0, 0, 255);
    const bool rgbaBFillOk = FillBuffer(ahbFns, ahbRgbaB, descRgbaB, 0, 0, 255, 255);
    if (!rgbaAFillOk || !rgbaBFillOk) {
        ANativeWindow_release(window);
        return env->NewStringUTF(BuildFailureString("hardware_buffer_fill_failed").c_str());
    }

    GlesBackend backend;

    // Pre-init lane: the composite readback seam fails closed with
    // backend_not_initialized before initialize() has been called.
    GlesViewportRectPx zeroRect{0, 0, 1, 1};
    const bool preInitRes = backend.diagnosticRenderMultiCamSpatialCompositeForReadback(
        vanguard::render::kInvalidHardwareBufferHandle,
        vanguard::render::kInvalidHardwareBufferHandle,
        zeroRect, zeroRect, VideoFrameTransform{}, VideoFrameTransform{});
    const std::string preInitLastError = SanitizeString(backend.lastError());
    const bool preInitLaneOk = (!preInitRes && preInitLastError == "backend_not_initialized");

    const bool initOk = backend.initialize();
    const int clientVersion = backend.clientVersion();
    const std::string vendor = SanitizeString(backend.diagnosticVendor());
    const std::string renderer = SanitizeString(backend.diagnosticRenderer());
    const std::string version = SanitizeString(backend.diagnosticVersion());
    const bool initCheckOk = initOk && backend.isInitialized() && (clientVersion >= 2) &&
                             !vendor.empty() && !renderer.empty() && !version.empty();

    const bool attachOk = backend.attachSurface(window, static_cast<uint32_t>(width), static_cast<uint32_t>(height));
    const bool attachCheckOk = attachOk && backend.hasSurface() &&
                               (backend.surfaceWidth() == static_cast<uint32_t>(width)) &&
                               (backend.surfaceHeight() == static_cast<uint32_t>(height));

    HardwareBufferHandle handleRgbaA = vanguard::render::kInvalidHardwareBufferHandle;
    vanguard::render::HardwareBufferDescriptor descImportRgbaA{};
    const auto resImportRgbaA = backend.importHardwareBuffer(ahbRgbaA, -1, &handleRgbaA, &descImportRgbaA);
    const uint32_t targetRgbaA = backend.diagnosticTextureTargetForHardwareBuffer(handleRgbaA);
    const bool importRgbaAOk = (resImportRgbaA == HardwareBufferImportResult::kSuccess) &&
                               (handleRgbaA != vanguard::render::kInvalidHardwareBufferHandle) &&
                               backend.hasHardwareBuffer(handleRgbaA) && (targetRgbaA == kTextureTarget2D);

    HardwareBufferHandle handleRgbaB = vanguard::render::kInvalidHardwareBufferHandle;
    vanguard::render::HardwareBufferDescriptor descImportRgbaB{};
    const auto resImportRgbaB = backend.importHardwareBuffer(ahbRgbaB, -1, &handleRgbaB, &descImportRgbaB);
    const uint32_t targetRgbaB = backend.diagnosticTextureTargetForHardwareBuffer(handleRgbaB);
    const bool importRgbaBOk = (resImportRgbaB == HardwareBufferImportResult::kSuccess) &&
                               (handleRgbaB != vanguard::render::kInvalidHardwareBufferHandle) &&
                               backend.hasHardwareBuffer(handleRgbaB) && (targetRgbaB == kTextureTarget2D);

    HardwareBufferHandle handleYcbcrA = vanguard::render::kInvalidHardwareBufferHandle;
    vanguard::render::HardwareBufferDescriptor descImportYcbcrA{};
    const auto resImportYcbcrA = backend.importHardwareBuffer(ahbYcbcrA, -1, &handleYcbcrA, &descImportYcbcrA);
    const uint32_t targetYcbcrA = backend.diagnosticTextureTargetForHardwareBuffer(handleYcbcrA);
    const bool importYcbcrAOk = (resImportYcbcrA == HardwareBufferImportResult::kSuccess) &&
                                (handleYcbcrA != vanguard::render::kInvalidHardwareBufferHandle) &&
                                backend.hasHardwareBuffer(handleYcbcrA) && (targetYcbcrA == kTextureTargetExternalOes);

    HardwareBufferHandle handleYcbcrB = vanguard::render::kInvalidHardwareBufferHandle;
    vanguard::render::HardwareBufferDescriptor descImportYcbcrB{};
    const auto resImportYcbcrB = backend.importHardwareBuffer(ahbYcbcrB, -1, &handleYcbcrB, &descImportYcbcrB);
    const uint32_t targetYcbcrB = backend.diagnosticTextureTargetForHardwareBuffer(handleYcbcrB);
    const bool importYcbcrBOk = (resImportYcbcrB == HardwareBufferImportResult::kSuccess) &&
                                (handleYcbcrB != vanguard::render::kInvalidHardwareBufferHandle) &&
                                backend.hasHardwareBuffer(handleYcbcrB) && (targetYcbcrB == kTextureTargetExternalOes);

    // Invalid-handle lane: one valid + one invalid handle fails closed with
    // invalid_buffer_handle, using an otherwise-valid full-canvas rect pair
    // so the failure is isolated to the handle, not the rect.
    const GlesViewportRectPx fullCanvasRect{0, 0, static_cast<uint32_t>(width), static_cast<uint32_t>(height)};
    const bool invalidHandleRes = backend.diagnosticRenderMultiCamSpatialCompositeForReadback(
        handleRgbaA, vanguard::render::kInvalidHardwareBufferHandle,
        fullCanvasRect, fullCanvasRect, VideoFrameTransform{}, VideoFrameTransform{});
    const std::string invalidHandleLastError = SanitizeString(backend.lastError());
    const bool invalidHandleLaneOk = (!invalidHandleRes && invalidHandleLastError == "invalid_buffer_handle");

    // Invalid-rect lane: an OES+OES handle pair with a secondary rect whose
    // right edge (x+width) exceeds the surface width fails closed with the
    // compositor's bounds-validation error, proving rect validation applies
    // regardless of texture target.
    const GlesViewportRectPx outOfBoundsRect{static_cast<int32_t>(width), 0, 10, 10};
    const bool invalidRectRes = backend.diagnosticRenderMultiCamSpatialCompositeForReadback(
        handleYcbcrA, handleYcbcrB, fullCanvasRect, outOfBoundsRect, VideoFrameTransform{}, VideoFrameTransform{});
    const std::string invalidRectLastError = SanitizeString(backend.lastError());
    const bool invalidRectLaneOk = (!invalidRectRes &&
        invalidRectLastError == "gles_multicam_spatial_compositor_invalid_rect");

    // Shared top/bottom split layout (splitRatio 0.3, primary on top,
    // secondary on bottom) reused across all three OES lane permutations --
    // each lane redraws the no-swap composite immediately before its own
    // readback, per the frozen contract.
    const MultiCamLayoutResult layoutResult = ComputeMultiCamLayout(
        MakeSplitLayout(width, height, MultiCamSplitDirection::kTopBottom, 0.3));
    const RectConversionResult primaryConv =
        ConvertNormalizedRectToPixelRect(layoutResult.primaryViewport, width, height);
    const RectConversionResult secondaryConv =
        ConvertNormalizedRectToPixelRect(layoutResult.secondaryViewport, width, height);
    const bool layoutConvOk = primaryConv.ok && secondaryConv.ok;

    // Lane: 2D primary (rgbaA, deterministic red) + OES secondary (ycbcrB,
    // non-deterministic content).
    bool twoDOesDrawOk = false;
    std::string twoDOesLastError = layoutConvOk ? "" : (!primaryConv.ok ? primaryConv.error : secondaryConv.error);
    bool twoDOesTargetOk = false;
    bool twoDOesOk = false;
    if (layoutConvOk) {
        twoDOesDrawOk = backend.diagnosticRenderMultiCamSpatialCompositeForReadback(
            handleRgbaA, handleYcbcrB, primaryConv.rect, secondaryConv.rect,
            VideoFrameTransform{}, VideoFrameTransform{});
        // GlesBackend::lastError() is sticky (never cleared on success), so
        // only capture it on failure -- otherwise it leaks a stale error
        // from an earlier lane into this lane's reported last error.
        twoDOesLastError = twoDOesDrawOk ? "" : SanitizeString(backend.lastError());
        const uint32_t twoDOesSecondaryTarget = backend.diagnosticTextureTargetForHardwareBuffer(handleYcbcrB);
        twoDOesTargetOk = (twoDOesSecondaryTarget == kTextureTargetExternalOes);
        const PixelSample twoDOesPrimarySample = SampleNormalizedPoint(backend, 0.5, 0.15, width, height);
        const PixelSample twoDOesSecondarySample = SampleNormalizedPoint(backend, 0.5, 0.65, width, height);
        twoDOesOk = twoDOesDrawOk && twoDOesTargetOk &&
            twoDOesPrimarySample.readOk && IsRedish(twoDOesPrimarySample.rgba) &&
            twoDOesSecondarySample.readOk;
    }

    // Lane: OES primary (ycbcrA, non-deterministic content) + 2D secondary
    // (rgbaB, deterministic blue).
    bool oesTwoDDrawOk = false;
    std::string oesTwoDLastError = layoutConvOk ? "" : (!primaryConv.ok ? primaryConv.error : secondaryConv.error);
    bool oesTwoDTargetOk = false;
    bool oesTwoDOk = false;
    if (layoutConvOk) {
        oesTwoDDrawOk = backend.diagnosticRenderMultiCamSpatialCompositeForReadback(
            handleYcbcrA, handleRgbaB, primaryConv.rect, secondaryConv.rect,
            VideoFrameTransform{}, VideoFrameTransform{});
        // See twoDOesLastError above: only capture on failure to avoid a
        // stale sticky backend error leaking into a successful lane.
        oesTwoDLastError = oesTwoDDrawOk ? "" : SanitizeString(backend.lastError());
        const uint32_t oesTwoDPrimaryTarget = backend.diagnosticTextureTargetForHardwareBuffer(handleYcbcrA);
        oesTwoDTargetOk = (oesTwoDPrimaryTarget == kTextureTargetExternalOes);
        const PixelSample oesTwoDPrimarySample = SampleNormalizedPoint(backend, 0.5, 0.15, width, height);
        const PixelSample oesTwoDSecondarySample = SampleNormalizedPoint(backend, 0.5, 0.65, width, height);
        oesTwoDOk = oesTwoDDrawOk && oesTwoDTargetOk &&
            oesTwoDPrimarySample.readOk &&
            oesTwoDSecondarySample.readOk && IsBlueish(oesTwoDSecondarySample.rgba);
    }

    // Lane: OES primary (ycbcrA) + OES secondary (ycbcrB), both
    // non-deterministic content.
    bool oesOesDrawOk = false;
    std::string oesOesLastError = layoutConvOk ? "" : (!primaryConv.ok ? primaryConv.error : secondaryConv.error);
    bool oesOesTargetOk = false;
    bool oesOesOk = false;
    if (layoutConvOk) {
        oesOesDrawOk = backend.diagnosticRenderMultiCamSpatialCompositeForReadback(
            handleYcbcrA, handleYcbcrB, primaryConv.rect, secondaryConv.rect,
            VideoFrameTransform{}, VideoFrameTransform{});
        // See twoDOesLastError above: only capture on failure to avoid a
        // stale sticky backend error leaking into a successful lane.
        oesOesLastError = oesOesDrawOk ? "" : SanitizeString(backend.lastError());
        const uint32_t oesOesPrimaryTarget = backend.diagnosticTextureTargetForHardwareBuffer(handleYcbcrA);
        const uint32_t oesOesSecondaryTarget = backend.diagnosticTextureTargetForHardwareBuffer(handleYcbcrB);
        oesOesTargetOk = (oesOesPrimaryTarget == kTextureTargetExternalOes) &&
            (oesOesSecondaryTarget == kTextureTargetExternalOes);
        const PixelSample oesOesPrimarySample = SampleNormalizedPoint(backend, 0.5, 0.15, width, height);
        const PixelSample oesOesSecondarySample = SampleNormalizedPoint(backend, 0.5, 0.65, width, height);
        oesOesOk = oesOesDrawOk && oesOesTargetOk &&
            oesOesPrimarySample.readOk && oesOesSecondarySample.readOk;
    }

    // Present lane: final OES+OES draw+swap only, not paired with a
    // readback -- proves the full-OES spatial composite reaches the
    // attached window surface end to end.
    bool presentOesOesOk = false;
    std::string presentOesOesLastError = layoutConvOk ? "" : (!primaryConv.ok ? primaryConv.error : secondaryConv.error);
    if (layoutConvOk) {
        presentOesOesOk = backend.diagnosticPresentMultiCamSpatialComposite(
            handleYcbcrA, handleYcbcrB, primaryConv.rect, secondaryConv.rect,
            VideoFrameTransform{}, VideoFrameTransform{});
        // See twoDOesLastError above: only capture on failure to avoid a
        // stale sticky backend error leaking into a successful lane.
        presentOesOesLastError = presentOesOesOk ? "" : SanitizeString(backend.lastError());
    }

    int releaseFenceRgbaA = -999;
    const auto resReleaseRgbaA = backend.releaseHardwareBuffer(handleRgbaA, &releaseFenceRgbaA);
    const bool hasRgbaAAfterRelease = backend.hasHardwareBuffer(handleRgbaA);
    const bool releaseRgbaAOk = (resReleaseRgbaA == HardwareBufferImportResult::kSuccess) &&
                                (releaseFenceRgbaA >= -1) && !hasRgbaAAfterRelease;
    if (releaseFenceRgbaA >= 0) {
        close(releaseFenceRgbaA);
    }

    int releaseFenceRgbaB = -999;
    const auto resReleaseRgbaB = backend.releaseHardwareBuffer(handleRgbaB, &releaseFenceRgbaB);
    const bool hasRgbaBAfterRelease = backend.hasHardwareBuffer(handleRgbaB);
    const bool releaseRgbaBOk = (resReleaseRgbaB == HardwareBufferImportResult::kSuccess) &&
                                (releaseFenceRgbaB >= -1) && !hasRgbaBAfterRelease;
    if (releaseFenceRgbaB >= 0) {
        close(releaseFenceRgbaB);
    }

    int releaseFenceYcbcrA = -999;
    const auto resReleaseYcbcrA = backend.releaseHardwareBuffer(handleYcbcrA, &releaseFenceYcbcrA);
    const bool hasYcbcrAAfterRelease = backend.hasHardwareBuffer(handleYcbcrA);
    const bool releaseYcbcrAOk = (resReleaseYcbcrA == HardwareBufferImportResult::kSuccess) &&
                                 (releaseFenceYcbcrA >= -1) && !hasYcbcrAAfterRelease;
    if (releaseFenceYcbcrA >= 0) {
        close(releaseFenceYcbcrA);
    }

    int releaseFenceYcbcrB = -999;
    const auto resReleaseYcbcrB = backend.releaseHardwareBuffer(handleYcbcrB, &releaseFenceYcbcrB);
    const bool hasYcbcrBAfterRelease = backend.hasHardwareBuffer(handleYcbcrB);
    const bool releaseYcbcrBOk = (resReleaseYcbcrB == HardwareBufferImportResult::kSuccess) &&
                                 (releaseFenceYcbcrB >= -1) && !hasYcbcrBAfterRelease;
    if (releaseFenceYcbcrB >= 0) {
        close(releaseFenceYcbcrB);
    }

    // Post-release lane: released handles fail closed with
    // invalid_buffer_handle.
    const bool postReleaseRes = backend.diagnosticRenderMultiCamSpatialCompositeForReadback(
        handleRgbaA, handleRgbaB, fullCanvasRect, fullCanvasRect, VideoFrameTransform{}, VideoFrameTransform{});
    const std::string postReleaseLastError = SanitizeString(backend.lastError());
    const bool postReleaseLaneOk = (!postReleaseRes && postReleaseLastError == "invalid_buffer_handle");

    backend.detachSurface();
    const bool detachOk = !backend.hasSurface() &&
        (std::string(backend.activeSurfaceKind()) == "offscreen");

    backend.shutdown();
    const bool shutdownOk = !backend.isInitialized();

    backend.shutdown();
    const bool idempotentShutdownOk = !backend.isInitialized();

    ANativeWindow_release(window);

    const bool allChecksPass = rgbaADescribeOk && rgbaBDescribeOk &&
                               ycbcrADescribeOk && ycbcrBDescribeOk &&
                               rgbaAFillOk && rgbaBFillOk &&
                               preInitLaneOk && initCheckOk && attachCheckOk &&
                               importRgbaAOk && importRgbaBOk &&
                               importYcbcrAOk && importYcbcrBOk &&
                               invalidHandleLaneOk && invalidRectLaneOk &&
                               twoDOesOk && oesTwoDOk && oesOesOk &&
                               presentOesOesOk &&
                               releaseRgbaAOk && releaseRgbaBOk &&
                               releaseYcbcrAOk && releaseYcbcrBOk &&
                               postReleaseLaneOk &&
                               detachOk && shutdownOk && idempotentShutdownOk;

    // GlesBackend::lastError() is sticky (never cleared on success), so by
    // this point it still holds the intentional postReleaseLane failure
    // (invalid_buffer_handle) even when every check passed. The final
    // lastError must reflect overall pass/fail, not a stale per-lane
    // rejection: none on full pass, otherwise the sanitized backend error
    // if one is present, else a synthesized reason so FAIL never reports an
    // empty lastError.
    const std::string backendLastError = SanitizeString(backend.lastError());
    const std::string finalLastError = allChecksPass
        ? std::string()
        : (!backendLastError.empty()
               ? backendLastError
               : std::string("multicam_spatial_oes_checks_failed_no_backend_error"));

    std::ostringstream oss;
    oss << "status=" << (allChecksPass ? "PASS" : "FAIL") << ";"
        << "width=" << width << ";"
        << "height=" << height << ";"
        << "clientVersion=" << clientVersion << ";"
        << "vendor=" << vendor << ";"
        << "renderer=" << renderer << ";"
        << "version=" << version << ";"
        << "rgbaADescribe=" << (rgbaADescribeOk ? "success" : "failed") << ";"
        << "rgbaAFill=" << (rgbaAFillOk ? "success" : "failed") << ";"
        << "rgbaBDescribe=" << (rgbaBDescribeOk ? "success" : "failed") << ";"
        << "rgbaBFill=" << (rgbaBFillOk ? "success" : "failed") << ";"
        << "ycbcrADescribe=" << (ycbcrADescribeOk ? "success" : "failed") << ";"
        << "ycbcrAFormatIs420888=" << (ycbcrAFormatIs420888 ? "true" : "false") << ";"
        << "ycbcrBDescribe=" << (ycbcrBDescribeOk ? "success" : "failed") << ";"
        << "ycbcrBFormatIs420888=" << (ycbcrBFormatIs420888 ? "true" : "false") << ";"
        << "preInitLane=" << (preInitLaneOk ? "rejected_as_expected" : "failed") << ";"
        << "preInitLastError=" << preInitLastError << ";"
        << "initialize=" << (initCheckOk ? "success" : "failed") << ";"
        << "attach=" << (attachCheckOk ? "success" : "failed") << ";"
        << "importRgbaA=" << (importRgbaAOk ? "success" : "failed") << ";"
        << "handleRgbaA=" << handleRgbaA << ";"
        << "targetRgbaA=" << targetRgbaA << ";"
        << "importRgbaB=" << (importRgbaBOk ? "success" : "failed") << ";"
        << "handleRgbaB=" << handleRgbaB << ";"
        << "targetRgbaB=" << targetRgbaB << ";"
        << "importYcbcrA=" << (importYcbcrAOk ? "success" : "failed") << ";"
        << "handleYcbcrA=" << handleYcbcrA << ";"
        << "targetYcbcrA=" << targetYcbcrA << ";"
        << "importYcbcrB=" << (importYcbcrBOk ? "success" : "failed") << ";"
        << "handleYcbcrB=" << handleYcbcrB << ";"
        << "targetYcbcrB=" << targetYcbcrB << ";"
        << "invalidHandleLane=" << (invalidHandleLaneOk ? "rejected_as_expected" : "failed") << ";"
        << "invalidHandleLastError=" << invalidHandleLastError << ";"
        << "invalidRectLane=" << (invalidRectLaneOk ? "rejected_as_expected" : "failed") << ";"
        << "invalidRectLastError=" << invalidRectLastError << ";"
        << "twoDOesOk=" << (twoDOesOk ? "true" : "false") << ";"
        << "twoDOesTargetOk=" << (twoDOesTargetOk ? "true" : "false") << ";"
        << "twoDOesLastError=" << (twoDOesLastError.empty() ? "none" : twoDOesLastError) << ";"
        << "oesTwoDOk=" << (oesTwoDOk ? "true" : "false") << ";"
        << "oesTwoDTargetOk=" << (oesTwoDTargetOk ? "true" : "false") << ";"
        << "oesTwoDLastError=" << (oesTwoDLastError.empty() ? "none" : oesTwoDLastError) << ";"
        << "oesOesOk=" << (oesOesOk ? "true" : "false") << ";"
        << "oesOesTargetOk=" << (oesOesTargetOk ? "true" : "false") << ";"
        << "oesOesLastError=" << (oesOesLastError.empty() ? "none" : oesOesLastError) << ";"
        << "presentOesOes=" << (presentOesOesOk ? "success" : "failed") << ";"
        << "presentOesOesLastError=" << (presentOesOesLastError.empty() ? "none" : presentOesOesLastError) << ";"
        << "releaseRgbaA=" << (releaseRgbaAOk ? "success" : "failed") << ";"
        << "releaseRgbaAFence=" << releaseFenceRgbaA << ";"
        << "hasRgbaAAfterRelease=" << (hasRgbaAAfterRelease ? "true" : "false") << ";"
        << "releaseRgbaB=" << (releaseRgbaBOk ? "success" : "failed") << ";"
        << "releaseRgbaBFence=" << releaseFenceRgbaB << ";"
        << "hasRgbaBAfterRelease=" << (hasRgbaBAfterRelease ? "true" : "false") << ";"
        << "releaseYcbcrA=" << (releaseYcbcrAOk ? "success" : "failed") << ";"
        << "releaseYcbcrAFence=" << releaseFenceYcbcrA << ";"
        << "hasYcbcrAAfterRelease=" << (hasYcbcrAAfterRelease ? "true" : "false") << ";"
        << "releaseYcbcrB=" << (releaseYcbcrBOk ? "success" : "failed") << ";"
        << "releaseYcbcrBFence=" << releaseFenceYcbcrB << ";"
        << "hasYcbcrBAfterRelease=" << (hasYcbcrBAfterRelease ? "true" : "false") << ";"
        << "postReleaseLane=" << (postReleaseLaneOk ? "rejected_as_expected" : "failed") << ";"
        << "postReleaseLastError=" << postReleaseLastError << ";"
        << "detach=" << (detachOk ? "success" : "failed") << ";"
        << "shutdown=" << (shutdownOk ? "success" : "failed") << ";"
        << "idempotentShutdown=" << (idempotentShutdownOk ? "success" : "failed") << ";"
        << "proofBoundary=" << kProofBoundary << ";"
        << "lastError=" << (finalLastError.empty() ? "none" : finalLastError);

    return env->NewStringUTF(oss.str().c_str());
}
