// P3-MULTICAM-NODE: GLES-first spatial multi-texture diagnostic render pass
// physical proof JNI bridge.
//
// Android-only translation unit added via CMake target_sources block. This
// is the composition root that bridges vanguard::compositors'
// ComputeMultiCamLayout() (pure top-left/Y-down normalized layout math) to
// vanguard::render::GlesBackend's bottom-left pixel-space diagnostic
// composite draw seams (diagnosticRenderMultiCamSpatialCompositeForReadback
// / diagnosticPresentMultiCamSpatialComposite). Neither vanguard_render_gles
// nor gles_backend.cpp/.h include any compositors header; only this JNI
// translation unit links vanguard_compositors and vanguard_render_gles
// together.
//
// Non-claim: render-only diagnostic proof. No camera open, no
// decoded/camera PRIVATE AHardwareBuffer claim, no Vulkan, no
// GL_TEXTURE_EXTERNAL_OES physical proof (structurally accepted by the
// backend, not exercised here), no product descriptors, no recording/
// export, no app/editor UI, no background cutout.
//
// JNI entry point:
//   runAndroidDagPhase3MultiCamSpatialGlesRenderSmoke -> jstring

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
    "native_multicam_spatial_gles_two_texture_layout_render_readback_only_no_vulkan_no_camera_no_oes_proof_no_opacity_no_corner_radius_no_recording_no_product";

// ---------------------------------------------------------------------------
// AHardwareBuffer native symbol resolution (mirrors the existing pattern in
// android_gles_two_texture_compositor_smoke_jni.cpp).
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
// Y-up) conversion. Exact rounding rule: round the left/right (and
// top/bottom) edges independently via std::lround, then take widths/heights
// as the *difference* of the rounded edges -- never round a width/height
// standalone. Every field is clamped finite into [0,1] first; nonfinite
// fields, an out-of-bounds rect after clamping, or a non-positive rounded
// width/height all fail closed.
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
        result.error = "multicam_spatial_rect_nonfinite";
        return result;
    }

    const double x = ClampUnit(rect.x);
    const double y = ClampUnit(rect.y);
    const double w = ClampUnit(rect.width);
    const double h = ClampUnit(rect.height);

    constexpr double kBoundsEpsilon = 1e-6;
    if (x + w > 1.0 + kBoundsEpsilon || y + h > 1.0 + kBoundsEpsilon) {
        result.error = "multicam_spatial_rect_out_of_bounds_after_clamp";
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
        result.error = "multicam_spatial_rect_nonpositive_after_round";
        return result;
    }

    result.rect.x = static_cast<int32_t>(left);
    result.rect.yBottom = static_cast<int32_t>(canvasHeight - bottom);
    result.rect.width = static_cast<uint32_t>(pixelWidth);
    result.rect.height = static_cast<uint32_t>(pixelHeight);
    result.ok = true;
    return result;
}

// Converts a top-left/Y-down normalized sample point into a bottom-left
// pixel coordinate suitable for GlesBackend::diagnosticReadPixels(). Sample
// points passed by callers below are chosen away from any rect's seams/
// edges, so simple clamped rounding is sufficient.
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

bool IsGreenish(const uint8_t rgba[4]) {
    return rgba[0] < 50 && rgba[1] > 200 && rgba[2] < 50 && rgba[3] > 200;
}

// ---------------------------------------------------------------------------
// Layout builders.
// ---------------------------------------------------------------------------

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

MultiCamLayout MakePiPLayout(double canvasWidth, double canvasHeight, MultiCamPiPAnchor anchor,
                             double centerX, double centerY, double normalizedWidth,
                             double aspectRatio, double marginFraction) {
    MultiCamLayout layout{};
    layout.mode = MultiCamLayoutMode::kPictureInPicture;
    layout.canvasWidth = canvasWidth;
    layout.canvasHeight = canvasHeight;
    layout.pip.anchor = anchor;
    layout.pip.centerX = centerX;
    layout.pip.centerY = centerY;
    layout.pip.normalizedWidth = normalizedWidth;
    layout.pip.aspectRatio = aspectRatio;
    layout.pip.marginFraction = marginFraction;
    layout.pip.cornerRadiusFractionOfCanvasWidth = 0.0;
    layout.pip.opacity = 1.0;
    layout.split.direction = MultiCamSplitDirection::kTopBottom;
    layout.split.splitRatio = 0.5;
    return layout;
}

// ---------------------------------------------------------------------------
// Lane runners. Each redraws the no-swap layout immediately before its own
// readback, per the frozen contract.
// ---------------------------------------------------------------------------

struct TwoPointLaneResult {
    bool pass = false;
    bool convOk = false;
    bool drawOk = false;
    std::string drawLastError;
};

TwoPointLaneResult RunTwoPointLane(GlesBackend& backend, HardwareBufferHandle handleA,
                                   HardwareBufferHandle handleB, int32_t width, int32_t height,
                                   const MultiCamLayout& layout, double primarySampleX,
                                   double primarySampleY, double secondarySampleX,
                                   double secondarySampleY, bool* sawGreen) {
    TwoPointLaneResult result;
    const MultiCamLayoutResult layoutResult = ComputeMultiCamLayout(layout);
    const RectConversionResult primaryConv =
        ConvertNormalizedRectToPixelRect(layoutResult.primaryViewport, width, height);
    const RectConversionResult secondaryConv =
        ConvertNormalizedRectToPixelRect(layoutResult.secondaryViewport, width, height);
    result.convOk = primaryConv.ok && secondaryConv.ok;
    if (!result.convOk) {
        result.drawLastError = !primaryConv.ok ? primaryConv.error : secondaryConv.error;
        return result;
    }

    result.drawOk = backend.diagnosticRenderMultiCamSpatialCompositeForReadback(
        handleA, handleB, primaryConv.rect, secondaryConv.rect,
        VideoFrameTransform{}, VideoFrameTransform{});
    result.drawLastError = SanitizeString(backend.lastError());
    if (!result.drawOk) {
        return result;
    }

    const PixelSample primary = SampleNormalizedPoint(backend, primarySampleX, primarySampleY, width, height);
    const PixelSample secondary = SampleNormalizedPoint(backend, secondarySampleX, secondarySampleY, width, height);
    if (IsGreenish(primary.rgba) || IsGreenish(secondary.rgba)) {
        *sawGreen = true;
    }
    result.pass = primary.readOk && secondary.readOk &&
                  IsRedish(primary.rgba) && IsBlueish(secondary.rgba);
    return result;
}

struct QuadrantLaneResult {
    bool pass = false;
    bool convOk = false;
    bool drawOk = false;
    std::string drawLastError;
};

QuadrantLaneResult RunPipTopLeftQuadrantLane(GlesBackend& backend, HardwareBufferHandle handleA,
                                             HardwareBufferHandle handleB, int32_t width,
                                             int32_t height, bool* sawGreen) {
    QuadrantLaneResult result;
    const MultiCamLayout layout =
        MakePiPLayout(width, height, MultiCamPiPAnchor::kTopLeft, 0.5, 0.5, 0.3, 1.0, 0.05);
    const MultiCamLayoutResult layoutResult = ComputeMultiCamLayout(layout);
    const RectConversionResult primaryConv =
        ConvertNormalizedRectToPixelRect(layoutResult.primaryViewport, width, height);
    const RectConversionResult secondaryConv =
        ConvertNormalizedRectToPixelRect(layoutResult.secondaryViewport, width, height);
    result.convOk = primaryConv.ok && secondaryConv.ok;
    if (!result.convOk) {
        result.drawLastError = !primaryConv.ok ? primaryConv.error : secondaryConv.error;
        return result;
    }

    result.drawOk = backend.diagnosticRenderMultiCamSpatialCompositeForReadback(
        handleA, handleB, primaryConv.rect, secondaryConv.rect,
        VideoFrameTransform{}, VideoFrameTransform{});
    result.drawLastError = SanitizeString(backend.lastError());
    if (!result.drawOk) {
        return result;
    }

    const PixelSample topLeft = SampleNormalizedPoint(backend, 0.25, 0.25, width, height);
    const PixelSample topRight = SampleNormalizedPoint(backend, 0.75, 0.25, width, height);
    const PixelSample bottomLeft = SampleNormalizedPoint(backend, 0.25, 0.75, width, height);
    const PixelSample bottomRight = SampleNormalizedPoint(backend, 0.75, 0.75, width, height);
    if (IsGreenish(topLeft.rgba) || IsGreenish(topRight.rgba) ||
        IsGreenish(bottomLeft.rgba) || IsGreenish(bottomRight.rgba)) {
        *sawGreen = true;
    }

    result.pass = topLeft.readOk && topRight.readOk && bottomLeft.readOk && bottomRight.readOk &&
                  IsBlueish(topLeft.rgba) && IsRedish(topRight.rgba) &&
                  IsRedish(bottomLeft.rgba) && IsRedish(bottomRight.rgba);
    return result;
}

std::string BuildFailureString(const char* lastErrorReason) {
    std::ostringstream oss;
    oss << "status=FAIL;"
        << "clientVersion=0;vendor=;renderer=;version=;"
        << "bufferADescribe=not_run;bufferAFill=not_run;bufferBDescribe=not_run;bufferBFill=not_run;"
        << "preInitLane=not_run;preInitLastError=;"
        << "initialize=not_run;attach=not_run;"
        << "importBufferA=not_run;handleA=0;targetA=0;importBufferB=not_run;handleB=0;targetB=0;"
        << "invalidHandleLane=not_run;invalidHandleLastError=;"
        << "invalidRectLane=not_run;invalidRectLastError=;"
        << "topBottomSplitOk=false;topBottomSplitLastError=;"
        << "leftRightSplitOk=false;leftRightSplitLastError=;"
        << "pipTopLeftOk=false;pipTopLeftLastError=;"
        << "pipFreeFloatingOk=false;pipFreeFloatingLastError=;"
        << "sentinelClearOk=false;"
        << "presentComposite=not_run;presentCompositeLastError=;"
        << "releaseBufferA=not_run;releaseBufferAFence=-1;hasAAfterRelease=false;"
        << "releaseBufferB=not_run;releaseBufferBFence=-1;hasBAfterRelease=false;"
        << "postReleaseLane=not_run;postReleaseLastError=;"
        << "detach=not_run;shutdown=not_run;idempotentShutdown=not_run;"
        << "proofBoundary=" << kProofBoundary << ";"
        << "lastError=" << lastErrorReason;
    return oss.str();
}

} // namespace

extern "C" JNIEXPORT jstring JNICALL
Java_com_connects_vanguard_1media_1engine_bridge_VanguardNativeBridge_runAndroidDagPhase3MultiCamSpatialGlesRenderSmoke(
    JNIEnv* env,
    jobject /* this */,
    jobject jSurface,
    jobject jBufferA,
    jobject jBufferB,
    jint width,
    jint height) {

    if (!jSurface || !jBufferA || !jBufferB || width <= 0 || height <= 0) {
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
    if (!ahbA || !ahbB) {
        ANativeWindow_release(window);
        return env->NewStringUTF(BuildFailureString("hardware_buffer_from_jobject_failed").c_str());
    }

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

    if (!bufferADescribeOk || !bufferBDescribeOk) {
        ANativeWindow_release(window);
        return env->NewStringUTF(BuildFailureString("hardware_buffer_descriptor_mismatch").c_str());
    }

    // Native fills bufferA solid opaque red (the primary lane color) and
    // bufferB solid opaque blue (the secondary lane color); Kotlin allocates
    // both buffers uninitialized.
    const bool bufferAFillOk = FillBuffer(ahbFns, ahbA, descA, 255, 0, 0, 255);
    const bool bufferBFillOk = FillBuffer(ahbFns, ahbB, descB, 0, 0, 255, 255);
    if (!bufferAFillOk || !bufferBFillOk) {
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

    HardwareBufferHandle handleA = vanguard::render::kInvalidHardwareBufferHandle;
    vanguard::render::HardwareBufferDescriptor descImportA{};
    const auto resImportA = backend.importHardwareBuffer(ahbA, -1, &handleA, &descImportA);
    const uint32_t targetA = backend.diagnosticTextureTargetForHardwareBuffer(handleA);
    const bool importBufferAOk = (resImportA == HardwareBufferImportResult::kSuccess) &&
                                 (handleA != vanguard::render::kInvalidHardwareBufferHandle) &&
                                 backend.hasHardwareBuffer(handleA) && (targetA == 0x0DE1);

    HardwareBufferHandle handleB = vanguard::render::kInvalidHardwareBufferHandle;
    vanguard::render::HardwareBufferDescriptor descImportB{};
    const auto resImportB = backend.importHardwareBuffer(ahbB, -1, &handleB, &descImportB);
    const uint32_t targetB = backend.diagnosticTextureTargetForHardwareBuffer(handleB);
    const bool importBufferBOk = (resImportB == HardwareBufferImportResult::kSuccess) &&
                                 (handleB != vanguard::render::kInvalidHardwareBufferHandle) &&
                                 backend.hasHardwareBuffer(handleB) && (targetB == 0x0DE1);

    // Invalid-handle lane: one valid + one invalid handle fails closed with
    // invalid_buffer_handle, using an otherwise-valid full-canvas rect pair
    // so the failure is isolated to the handle, not the rect.
    const GlesViewportRectPx fullCanvasRect{0, 0, static_cast<uint32_t>(width), static_cast<uint32_t>(height)};
    const bool invalidHandleRes = backend.diagnosticRenderMultiCamSpatialCompositeForReadback(
        handleA, vanguard::render::kInvalidHardwareBufferHandle,
        fullCanvasRect, fullCanvasRect, VideoFrameTransform{}, VideoFrameTransform{});
    const std::string invalidHandleLastError = SanitizeString(backend.lastError());
    const bool invalidHandleLaneOk = (!invalidHandleRes && invalidHandleLastError == "invalid_buffer_handle");

    // Invalid-rect lane: one valid imported handle pair with a secondary
    // rect whose right edge (x+width) exceeds the surface width fails
    // closed with the compositor's bounds-validation error, proving
    // backend-side fail-closed rect validation rather than only JNI-side
    // conversion of already-valid layout rects.
    const GlesViewportRectPx outOfBoundsRect{
        static_cast<int32_t>(width), 0, 10, 10};
    const bool invalidRectRes = backend.diagnosticRenderMultiCamSpatialCompositeForReadback(
        handleA, handleB, fullCanvasRect, outOfBoundsRect, VideoFrameTransform{}, VideoFrameTransform{});
    const std::string invalidRectLastError = SanitizeString(backend.lastError());
    const bool invalidRectLaneOk = (!invalidRectRes &&
        invalidRectLastError == "gles_multicam_spatial_compositor_invalid_rect");

    bool sawGreen = false;

    // topBottomSplitOk: splitRatio 0.3, primary (red) on top, secondary
    // (blue) on bottom.
    const TwoPointLaneResult topBottomLane = RunTwoPointLane(
        backend, handleA, handleB, width, height,
        MakeSplitLayout(width, height, MultiCamSplitDirection::kTopBottom, 0.3),
        0.5, 0.15, 0.5, 0.65, &sawGreen);

    // leftRightSplitOk: splitRatio 0.3, primary (red) on the left, secondary
    // (blue) on the right.
    const TwoPointLaneResult leftRightLane = RunTwoPointLane(
        backend, handleA, handleB, width, height,
        MakeSplitLayout(width, height, MultiCamSplitDirection::kLeftRight, 0.3),
        0.15, 0.5, 0.65, 0.5, &sawGreen);

    // pipTopLeftOk: primary (red) covers the full canvas; secondary (blue)
    // is confined to the top-left corner. All four quadrant centers are
    // sampled to prove blue appears only in the top-left quadrant.
    const QuadrantLaneResult pipTopLeftLane =
        RunPipTopLeftQuadrantLane(backend, handleA, handleB, width, height, &sawGreen);

    // pipFreeFloatingOk: a non-centered free-floating secondary placement,
    // proving the PiP path is not hardcoded to a corner anchor.
    const TwoPointLaneResult pipFreeFloatingLane = RunTwoPointLane(
        backend, handleA, handleB, width, height,
        MakePiPLayout(width, height, MultiCamPiPAnchor::kFreeFloating, 0.7, 0.75, 0.2, 1.0, 0.05),
        0.15, 0.15, 0.7, 0.75, &sawGreen);

    const bool sentinelClearOk = !sawGreen &&
        topBottomLane.pass && leftRightLane.pass && pipTopLeftLane.pass && pipFreeFloatingLane.pass;

    // Present lane: final draw only, not paired with a readback.
    const MultiCamLayoutResult presentLayoutResult = ComputeMultiCamLayout(
        MakeSplitLayout(width, height, MultiCamSplitDirection::kTopBottom, 0.3));
    const RectConversionResult presentPrimaryConv =
        ConvertNormalizedRectToPixelRect(presentLayoutResult.primaryViewport, width, height);
    const RectConversionResult presentSecondaryConv =
        ConvertNormalizedRectToPixelRect(presentLayoutResult.secondaryViewport, width, height);
    bool presentCompositeOk = false;
    std::string presentCompositeLastError;
    if (presentPrimaryConv.ok && presentSecondaryConv.ok) {
        presentCompositeOk = backend.diagnosticPresentMultiCamSpatialComposite(
            handleA, handleB, presentPrimaryConv.rect, presentSecondaryConv.rect,
            VideoFrameTransform{}, VideoFrameTransform{});
        presentCompositeLastError = SanitizeString(backend.lastError());
    } else {
        presentCompositeLastError = !presentPrimaryConv.ok ? presentPrimaryConv.error : presentSecondaryConv.error;
    }

    int releaseFenceA = -999;
    const auto resReleaseA = backend.releaseHardwareBuffer(handleA, &releaseFenceA);
    const bool hasAAfterRelease = backend.hasHardwareBuffer(handleA);
    const bool releaseAOk = (resReleaseA == HardwareBufferImportResult::kSuccess) &&
                            (releaseFenceA >= -1) && !hasAAfterRelease;
    if (releaseFenceA >= 0) {
        close(releaseFenceA);
    }

    int releaseFenceB = -999;
    const auto resReleaseB = backend.releaseHardwareBuffer(handleB, &releaseFenceB);
    const bool hasBAfterRelease = backend.hasHardwareBuffer(handleB);
    const bool releaseBOk = (resReleaseB == HardwareBufferImportResult::kSuccess) &&
                            (releaseFenceB >= -1) && !hasBAfterRelease;
    if (releaseFenceB >= 0) {
        close(releaseFenceB);
    }

    // Post-release lane: released handles fail closed with
    // invalid_buffer_handle.
    const bool postReleaseRes = backend.diagnosticRenderMultiCamSpatialCompositeForReadback(
        handleA, handleB, fullCanvasRect, fullCanvasRect, VideoFrameTransform{}, VideoFrameTransform{});
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

    const bool allChecksPass = bufferADescribeOk && bufferBDescribeOk &&
                               bufferAFillOk && bufferBFillOk &&
                               preInitLaneOk && initCheckOk && attachCheckOk &&
                               importBufferAOk && importBufferBOk &&
                               invalidHandleLaneOk && invalidRectLaneOk &&
                               topBottomLane.pass && leftRightLane.pass &&
                               pipTopLeftLane.pass && pipFreeFloatingLane.pass &&
                               sentinelClearOk &&
                               presentCompositeOk &&
                               releaseAOk && releaseBOk &&
                               postReleaseLaneOk &&
                               detachOk && shutdownOk && idempotentShutdownOk;

    const std::string backendLastError = SanitizeString(backend.lastError());

    std::ostringstream oss;
    oss << "status=" << (allChecksPass ? "PASS" : "FAIL") << ";"
        << "clientVersion=" << clientVersion << ";"
        << "vendor=" << vendor << ";"
        << "renderer=" << renderer << ";"
        << "version=" << version << ";"
        << "bufferADescribe=" << (bufferADescribeOk ? "success" : "failed") << ";"
        << "bufferAFill=" << (bufferAFillOk ? "success" : "failed") << ";"
        << "bufferBDescribe=" << (bufferBDescribeOk ? "success" : "failed") << ";"
        << "bufferBFill=" << (bufferBFillOk ? "success" : "failed") << ";"
        << "preInitLane=" << (preInitLaneOk ? "rejected_as_expected" : "failed") << ";"
        << "preInitLastError=" << preInitLastError << ";"
        << "initialize=" << (initCheckOk ? "success" : "failed") << ";"
        << "attach=" << (attachCheckOk ? "success" : "failed") << ";"
        << "importBufferA=" << (importBufferAOk ? "success" : "failed") << ";"
        << "handleA=" << handleA << ";"
        << "targetA=" << targetA << ";"
        << "importBufferB=" << (importBufferBOk ? "success" : "failed") << ";"
        << "handleB=" << handleB << ";"
        << "targetB=" << targetB << ";"
        << "invalidHandleLane=" << (invalidHandleLaneOk ? "rejected_as_expected" : "failed") << ";"
        << "invalidHandleLastError=" << invalidHandleLastError << ";"
        << "invalidRectLane=" << (invalidRectLaneOk ? "rejected_as_expected" : "failed") << ";"
        << "invalidRectLastError=" << invalidRectLastError << ";"
        << "topBottomSplitOk=" << (topBottomLane.pass ? "true" : "false") << ";"
        << "topBottomSplitLastError=" << (topBottomLane.drawLastError.empty() ? "none" : topBottomLane.drawLastError) << ";"
        << "leftRightSplitOk=" << (leftRightLane.pass ? "true" : "false") << ";"
        << "leftRightSplitLastError=" << (leftRightLane.drawLastError.empty() ? "none" : leftRightLane.drawLastError) << ";"
        << "pipTopLeftOk=" << (pipTopLeftLane.pass ? "true" : "false") << ";"
        << "pipTopLeftLastError=" << (pipTopLeftLane.drawLastError.empty() ? "none" : pipTopLeftLane.drawLastError) << ";"
        << "pipFreeFloatingOk=" << (pipFreeFloatingLane.pass ? "true" : "false") << ";"
        << "pipFreeFloatingLastError=" << (pipFreeFloatingLane.drawLastError.empty() ? "none" : pipFreeFloatingLane.drawLastError) << ";"
        << "sentinelClearOk=" << (sentinelClearOk ? "true" : "false") << ";"
        << "presentComposite=" << (presentCompositeOk ? "success" : "failed") << ";"
        << "presentCompositeLastError=" << (presentCompositeLastError.empty() ? "none" : presentCompositeLastError) << ";"
        << "releaseBufferA=" << (releaseAOk ? "success" : "failed") << ";"
        << "releaseBufferAFence=" << releaseFenceA << ";"
        << "hasAAfterRelease=" << (hasAAfterRelease ? "true" : "false") << ";"
        << "releaseBufferB=" << (releaseBOk ? "success" : "failed") << ";"
        << "releaseBufferBFence=" << releaseFenceB << ";"
        << "hasBAfterRelease=" << (hasBAfterRelease ? "true" : "false") << ";"
        << "postReleaseLane=" << (postReleaseLaneOk ? "rejected_as_expected" : "failed") << ";"
        << "postReleaseLastError=" << postReleaseLastError << ";"
        << "detach=" << (detachOk ? "success" : "failed") << ";"
        << "shutdown=" << (shutdownOk ? "success" : "failed") << ";"
        << "idempotentShutdown=" << (idempotentShutdownOk ? "success" : "failed") << ";"
        << "proofBoundary=" << kProofBoundary << ";"
        << "lastError=" << (backendLastError.empty() ? "none" : backendLastError);

    return env->NewStringUTF(oss.str().c_str());
}
