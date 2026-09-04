// P3-MULTICAM-NODE-DYNAMIC-DESCRIPTOR-SPATIAL-RENDER: proves that a caller-
// supplied Dart layout descriptor map (parsed into primitive fields by the
// Kotlin transport layer) drives native GLES/OES spatial rendering end to
// end: Dart descriptor -> Kotlin parse-only transport ->
// vanguard::compositors::ComputeMultiCamLayout() -> normalized-to-pixel rect
// conversion -> GlesBackend spatial composite render/readback, exactly like
// android_phase3_multicam_spatial_oes_render_jni.cpp's render pipeline, but
// with the layout mode/anchor/direction/geometry driven by the caller
// instead of a single hard-coded synthetic layout.
//
// Native is the sole layout authority: this translation unit maps the exact
// Dart descriptor strings (layoutMode: pip/splitScreen; pipAnchor:
// freeFloating/topLeft/topRight/bottomLeft/bottomRight; splitDirection:
// topBottom/leftRight) to the matching vanguard::compositors::MultiCam*
// enum, and an unrecognized string FAILS CLOSED with an explicit reason
// before any AHardwareBuffer import or GLES work begins -- it never
// defaults to a fallback enum value (this deliberately diverges from the
// existing dart_layout_map_to_native_multicam_layout_diagnostic bridge in
// android_phase3_multicam_compositor_jni.cpp, whose unknown-value fallbacks
// mirror Dart's own *Extension.fromValue() defaulting behavior for a purely
// in-memory diagnostic; this route instead performs real GPU rendering, so a
// silently-defaulted layout would render the wrong descriptor's geometry
// without any signal).
//
// Render lane semantics selected by the resolved layoutMode: kPictureInPicture
// renders the RGBA primary buffer (deterministic solid red) as primary and
// the never-CPU-filled YCBCR/OES secondary buffer as secondary; kSplitScreen
// renders the OES primary buffer as primary and the RGBA secondary buffer
// (deterministic solid blue) as secondary. Both lanes exercise any caller
// anchor/direction value, so the same native pipeline proves the specific
// freeFloating-PiP and leftRight-split descriptors this slice's Dart/Kotlin
// callers exercise. cornerRadiusFractionOfCanvasWidth and opacity are
// hard-set to 0.0/1.0 in the native MultiCamLayout regardless of any Dart
// value -- this route accepts no cornerRadius/opacity parameters at all.
//
// Readback sample points are derived, never hardcoded: the secondary sample
// is the computed secondary pixel rect's own center; the primary sample
// prefers the computed primary pixel rect's own center and falls back to an
// inset canvas corner only when that center would fall inside the secondary
// rect (the PiP case, whose primary is the full canvas), so the primary
// sample point is always provably outside the secondary rect. OES-side
// samples assert render/readback success and the resolved
// GL_TEXTURE_EXTERNAL_OES target (0x8D65) only -- never color content, since
// the YCBCR buffers are never CPU-filled (mirrors the existing
// android_phase3_multicam_spatial_oes_render_jni.cpp precedent). RGBA-side
// samples additionally assert deterministic red/blue content.
//
// Non-claim: render-only diagnostic proof. No camera open, no Vulkan, no
// recording/export, no product UI, no corner radius, no secondary opacity,
// no YCBCR color-correctness claim.
//
// JNI entry point:
//   runAndroidDagPhase3MultiCamDynamicDescriptorSpatialRenderSmoke -> jstring

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
    "native_multicam_dynamic_descriptor_spatial_gles_oes_render_readback_only_no_vulkan_no_camera_no_opacity_no_corner_radius_no_ycbcr_color_claim_no_recording_no_product";

constexpr uint32_t kTextureTarget2D = 0x0DE1;
constexpr uint32_t kTextureTargetExternalOes = 0x8D65;

// ---------------------------------------------------------------------------
// AHardwareBuffer native symbol resolution (mirrors the existing pattern in
// android_phase3_multicam_spatial_oes_render_jni.cpp).
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

std::string JStringToStdString(JNIEnv* env, jstring value) {
    if (!value) return std::string();
    const char* chars = env->GetStringUTFChars(value, nullptr);
    if (!chars) return std::string();
    std::string result(chars);
    env->ReleaseStringUTFChars(value, chars);
    return result;
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
// Strict Dart-descriptor-string -> native MultiCam* enum resolution. Unlike
// android_phase3_multicam_compositor_jni.cpp's ResolveLayoutMode/
// ResolveAnchor/ResolveSplitDirection (which mirror Dart's *Extension.
// fromValue() unknown-value fallback defaulting for a purely in-memory
// diagnostic), every resolver here reports ok=false for any string outside
// the exact accepted set instead of silently substituting a default, since
// this route performs real GPU rendering that must never proceed on a
// silently-reinterpreted layout.
// ---------------------------------------------------------------------------

struct LayoutModeResolution {
    bool ok = false;
    MultiCamLayoutMode mode = MultiCamLayoutMode::kPictureInPicture;
};

LayoutModeResolution ResolveLayoutModeStrict(const std::string& raw) {
    if (raw == "pip") return {true, MultiCamLayoutMode::kPictureInPicture};
    if (raw == "splitScreen") return {true, MultiCamLayoutMode::kSplitScreen};
    return {false, MultiCamLayoutMode::kPictureInPicture};
}

struct AnchorResolution {
    bool ok = false;
    MultiCamPiPAnchor anchor = MultiCamPiPAnchor::kFreeFloating;
};

AnchorResolution ResolveAnchorStrict(const std::string& raw) {
    if (raw == "freeFloating") return {true, MultiCamPiPAnchor::kFreeFloating};
    if (raw == "topLeft") return {true, MultiCamPiPAnchor::kTopLeft};
    if (raw == "topRight") return {true, MultiCamPiPAnchor::kTopRight};
    if (raw == "bottomLeft") return {true, MultiCamPiPAnchor::kBottomLeft};
    if (raw == "bottomRight") return {true, MultiCamPiPAnchor::kBottomRight};
    return {false, MultiCamPiPAnchor::kFreeFloating};
}

struct SplitDirectionResolution {
    bool ok = false;
    MultiCamSplitDirection direction = MultiCamSplitDirection::kTopBottom;
};

SplitDirectionResolution ResolveSplitDirectionStrict(const std::string& raw) {
    if (raw == "topBottom") return {true, MultiCamSplitDirection::kTopBottom};
    if (raw == "leftRight") return {true, MultiCamSplitDirection::kLeftRight};
    return {false, MultiCamSplitDirection::kTopBottom};
}

const char* LayoutModeName(MultiCamLayoutMode mode) {
    return mode == MultiCamLayoutMode::kSplitScreen ? "splitScreen" : "pip";
}

const char* AnchorName(MultiCamPiPAnchor anchor) {
    switch (anchor) {
        case MultiCamPiPAnchor::kTopLeft: return "topLeft";
        case MultiCamPiPAnchor::kTopRight: return "topRight";
        case MultiCamPiPAnchor::kBottomLeft: return "bottomLeft";
        case MultiCamPiPAnchor::kBottomRight: return "bottomRight";
        case MultiCamPiPAnchor::kFreeFloating: return "freeFloating";
    }
    return "freeFloating";
}

const char* SplitDirectionName(MultiCamSplitDirection direction) {
    return direction == MultiCamSplitDirection::kLeftRight ? "leftRight" : "topBottom";
}

// ---------------------------------------------------------------------------
// Normalized (top-left origin, Y-down) <-> pixel (bottom-left origin,
// Y-up) conversion. Duplicated from android_phase3_multicam_spatial_oes_
// render_jni.cpp (private anonymous-namespace helper in that TU, not shared
// through a header) -- same exact rounding rule: round the left/right (and
// top/bottom) edges independently via std::lround, then take widths/heights
// as the *difference* of the rounded edges. Every field is clamped finite
// into [0,1] first; nonfinite fields, an out-of-bounds rect after clamping,
// or a non-positive rounded width/height all fail closed.
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
        result.error = "multicam_dynamic_descriptor_rect_nonfinite";
        return result;
    }

    const double x = ClampUnit(rect.x);
    const double y = ClampUnit(rect.y);
    const double w = ClampUnit(rect.width);
    const double h = ClampUnit(rect.height);

    constexpr double kBoundsEpsilon = 1e-6;
    if (x + w > 1.0 + kBoundsEpsilon || y + h > 1.0 + kBoundsEpsilon) {
        result.error = "multicam_dynamic_descriptor_rect_out_of_bounds_after_clamp";
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
        result.error = "multicam_dynamic_descriptor_rect_nonpositive_after_round";
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

// ---------------------------------------------------------------------------
// Derived (never hardcoded) readback sample points.
// ---------------------------------------------------------------------------

struct NormalizedPoint {
    double x;
    double y;
};

bool NormalizedPointInsideRect(double x, double y, const NormalizedRect& r) {
    return x >= r.x && x <= r.x + r.width && y >= r.y && y <= r.y + r.height;
}

NormalizedPoint RectCenter(const NormalizedRect& r) {
    return {r.x + r.width / 2.0, r.y + r.height / 2.0};
}

// Returns a point inside `containerRect` that is provably outside
// `avoidRect`: prefers containerRect's own center (true for the split-screen
// lane, whose primary/secondary rects never overlap), and falls back to an
// inset canvas corner only when that center collides with avoidRect (true
// for the PiP lane, whose primary rect is the full canvas containing the
// secondary PiP rect).
NormalizedPoint ComputePointInsideButOutside(const NormalizedRect& containerRect,
                                              const NormalizedRect& avoidRect) {
    const NormalizedPoint center = RectCenter(containerRect);
    if (!NormalizedPointInsideRect(center.x, center.y, avoidRect)) {
        return center;
    }
    constexpr double kInset = 0.05;
    const NormalizedPoint candidates[4] = {
        {kInset, kInset},
        {1.0 - kInset, kInset},
        {kInset, 1.0 - kInset},
        {1.0 - kInset, 1.0 - kInset},
    };
    for (const auto& candidate : candidates) {
        if (!NormalizedPointInsideRect(candidate.x, candidate.y, avoidRect)) {
            return candidate;
        }
    }
    // Unreachable for in-bounds proof descriptors; fall back to the
    // (colliding) center rather than an unrelated hardcoded point.
    return center;
}

std::string BuildFailureString(const std::string& reason,
                               const std::string& descriptorParseStatus = "not_run",
                               const std::string& descriptorParseLastError = "") {
    std::ostringstream oss;
    oss << "status=FAIL;"
        << "width=0;height=0;"
        << "clientVersion=0;vendor=;renderer=;version=;"
        << "rgbaADescribe=not_run;rgbaAFill=not_run;"
        << "rgbaBDescribe=not_run;rgbaBFill=not_run;"
        << "ycbcrADescribe=not_run;ycbcrAFormatIs420888=false;"
        << "ycbcrBDescribe=not_run;ycbcrBFormatIs420888=false;"
        << "initialize=not_run;attach=not_run;"
        << "importRgbaA=not_run;handleRgbaA=0;targetRgbaA=0;"
        << "importRgbaB=not_run;handleRgbaB=0;targetRgbaB=0;"
        << "importYcbcrA=not_run;handleYcbcrA=0;targetYcbcrA=0;"
        << "importYcbcrB=not_run;handleYcbcrB=0;targetYcbcrB=0;"
        << "descriptorParse=" << descriptorParseStatus << ";"
        << "descriptorParseLastError=" << descriptorParseLastError << ";"
        << "layoutModeResolved=;anchorResolved=;directionResolved=;"
        << "layoutConvert=not_run;layoutConvertLastError=;"
        << "primaryRectX=0;primaryRectY=0;primaryRectW=0;primaryRectH=0;"
        << "secondaryRectX=0;secondaryRectY=0;secondaryRectW=0;secondaryRectH=0;"
        << "renderLaneMode=;primaryTextureKind=;secondaryTextureKind=;"
        << "renderDraw=not_run;renderDrawLastError=;"
        << "primaryTargetOk=false;secondaryTargetOk=false;"
        << "primarySampleReadOk=false;secondarySampleReadOk=false;"
        << "deterministicColorSide=;deterministicColorOk=false;"
        << "presentLane=not_run;presentLaneLastError=;"
        << "releaseRgbaA=not_run;releaseRgbaAFence=-1;hasRgbaAAfterRelease=false;"
        << "releaseRgbaB=not_run;releaseRgbaBFence=-1;hasRgbaBAfterRelease=false;"
        << "releaseYcbcrA=not_run;releaseYcbcrAFence=-1;hasYcbcrAAfterRelease=false;"
        << "releaseYcbcrB=not_run;releaseYcbcrBFence=-1;hasYcbcrBAfterRelease=false;"
        << "postReleaseLane=not_run;postReleaseLastError=;"
        << "detach=not_run;shutdown=not_run;idempotentShutdown=not_run;"
        << "proofBoundary=" << kProofBoundary << ";"
        << "lastError=" << reason;
    return oss.str();
}

} // namespace

extern "C" JNIEXPORT jstring JNICALL
Java_com_connects_vanguard_1media_1engine_bridge_VanguardNativeBridge_runAndroidDagPhase3MultiCamDynamicDescriptorSpatialRenderSmoke(
    JNIEnv* env,
    jobject /* this */,
    jobject jSurface,
    jobject jRgbaBufferA,
    jobject jRgbaBufferB,
    jobject jYcbcrBufferA,
    jobject jYcbcrBufferB,
    jint width,
    jint height,
    jstring layoutModeJ,
    jstring pipAnchorJ,
    jdouble pipCenterX,
    jdouble pipCenterY,
    jdouble pipWidthFraction,
    jdouble pipAspectRatio,
    jdouble pipMarginFraction,
    jstring splitDirectionJ,
    jdouble splitRatio) {

    if (!jSurface || !jRgbaBufferA || !jRgbaBufferB || !jYcbcrBufferA || !jYcbcrBufferB ||
        width <= 0 || height <= 0) {
        return env->NewStringUTF(BuildFailureString("invalid_arguments").c_str());
    }

    // Descriptor-parse lane: strict string resolution, executed before any
    // AHardwareBuffer import or GLES work so an unrecognized enum value
    // fails closed with zero native side effects.
    const std::string layoutModeRaw = JStringToStdString(env, layoutModeJ);
    const std::string pipAnchorRaw = JStringToStdString(env, pipAnchorJ);
    const std::string splitDirectionRaw = JStringToStdString(env, splitDirectionJ);

    const LayoutModeResolution modeRes = ResolveLayoutModeStrict(layoutModeRaw);
    const AnchorResolution anchorRes = ResolveAnchorStrict(pipAnchorRaw);
    const SplitDirectionResolution directionRes = ResolveSplitDirectionStrict(splitDirectionRaw);

    if (!modeRes.ok) {
        return env->NewStringUTF(
            BuildFailureString("unknown_layout_mode", "failed", "unknown_layout_mode").c_str());
    }
    if (!anchorRes.ok) {
        return env->NewStringUTF(
            BuildFailureString("unknown_pip_anchor", "failed", "unknown_pip_anchor").c_str());
    }
    if (!directionRes.ok) {
        return env->NewStringUTF(
            BuildFailureString("unknown_split_direction", "failed", "unknown_split_direction").c_str());
    }

    NativeHardwareBufferFunctions ahbFns = ResolveNativeHardwareBufferFunctions();
    if (!ahbFns.isValid()) {
        return env->NewStringUTF(
            BuildFailureString("hardware_buffer_symbols_unavailable", "success").c_str());
    }

    ANativeWindow* window = ANativeWindow_fromSurface(env, jSurface);
    if (!window) {
        return env->NewStringUTF(
            BuildFailureString("native_window_from_surface_failed", "success").c_str());
    }

    AHardwareBuffer* ahbRgbaA = ahbFns.fromHardwareBuffer(env, jRgbaBufferA);
    AHardwareBuffer* ahbRgbaB = ahbFns.fromHardwareBuffer(env, jRgbaBufferB);
    AHardwareBuffer* ahbYcbcrA = ahbFns.fromHardwareBuffer(env, jYcbcrBufferA);
    AHardwareBuffer* ahbYcbcrB = ahbFns.fromHardwareBuffer(env, jYcbcrBufferB);
    if (!ahbRgbaA || !ahbRgbaB || !ahbYcbcrA || !ahbYcbcrB) {
        ANativeWindow_release(window);
        return env->NewStringUTF(
            BuildFailureString("hardware_buffer_from_jobject_failed", "success").c_str());
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
        return env->NewStringUTF(
            BuildFailureString("hardware_buffer_descriptor_mismatch", "success").c_str());
    }

    // Native fills rgbaBufferA solid opaque red and rgbaBufferB solid opaque
    // blue; the YCBCR buffers are never CPU-filled (mirrors the existing
    // android_phase3_multicam_spatial_oes_render_jni.cpp precedent), so OES
    // lanes assert render/readback success and resolved texture target only.
    const bool rgbaAFillOk = FillBuffer(ahbFns, ahbRgbaA, descRgbaA, 255, 0, 0, 255);
    const bool rgbaBFillOk = FillBuffer(ahbFns, ahbRgbaB, descRgbaB, 0, 0, 255, 255);
    if (!rgbaAFillOk || !rgbaBFillOk) {
        ANativeWindow_release(window);
        return env->NewStringUTF(
            BuildFailureString("hardware_buffer_fill_failed", "success").c_str());
    }

    GlesBackend backend;

    const bool initOk = backend.initialize();
    const int clientVersion = backend.clientVersion();
    const std::string vendor = SanitizeString(backend.diagnosticVendor());
    const std::string renderer = SanitizeString(backend.diagnosticRenderer());
    const std::string version = SanitizeString(backend.diagnosticVersion());
    const bool initCheckOk = initOk && backend.isInitialized() && (clientVersion >= 2) &&
                             !vendor.empty() && !renderer.empty() && !version.empty();

    // GlesBackend spatial readback requires an attached surface: native must
    // attach the caller-provided Surface before any render call below.
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

    // Layout-conversion lane: native is the sole layout authority. Build the
    // MultiCamLayout entirely from the caller's resolved descriptor fields
    // (cornerRadiusFractionOfCanvasWidth/opacity hard-set, never taken from
    // the caller), call the already-verified ComputeMultiCamLayout(), then
    // convert both normalized rects into GLES pixel viewport rects.
    MultiCamLayout layout{};
    layout.mode = modeRes.mode;
    layout.canvasWidth = static_cast<double>(width);
    layout.canvasHeight = static_cast<double>(height);
    layout.pip.anchor = anchorRes.anchor;
    layout.pip.centerX = pipCenterX;
    layout.pip.centerY = pipCenterY;
    layout.pip.normalizedWidth = pipWidthFraction;
    layout.pip.aspectRatio = pipAspectRatio;
    layout.pip.marginFraction = pipMarginFraction;
    layout.pip.cornerRadiusFractionOfCanvasWidth = 0.0;
    layout.pip.opacity = 1.0;
    layout.split.direction = directionRes.direction;
    layout.split.splitRatio = splitRatio;

    const MultiCamLayoutResult layoutResult = ComputeMultiCamLayout(layout);
    const RectConversionResult primaryConv =
        ConvertNormalizedRectToPixelRect(layoutResult.primaryViewport, width, height);
    const RectConversionResult secondaryConv =
        ConvertNormalizedRectToPixelRect(layoutResult.secondaryViewport, width, height);
    const bool layoutConvertOk = primaryConv.ok && secondaryConv.ok;
    const std::string layoutConvertLastError =
        layoutConvertOk ? "" : (!primaryConv.ok ? primaryConv.error : secondaryConv.error);

    // Render-lane texture assignment: kPictureInPicture draws the RGBA
    // (deterministic red) buffer as primary and the OES (never-CPU-filled)
    // buffer as secondary; kSplitScreen draws the OES buffer as primary and
    // the RGBA (deterministic blue) buffer as secondary. Applies uniformly
    // to any caller anchor/direction value.
    const bool isPip = (modeRes.mode == MultiCamLayoutMode::kPictureInPicture);
    const HardwareBufferHandle primaryHandle = isPip ? handleRgbaA : handleYcbcrA;
    const HardwareBufferHandle secondaryHandle = isPip ? handleYcbcrB : handleRgbaB;
    const char* primaryTextureKind = isPip ? "rgba" : "oes";
    const char* secondaryTextureKind = isPip ? "oes" : "rgba";
    const char* deterministicColorSide = isPip ? "primary" : "secondary";

    bool renderDrawOk = false;
    std::string renderDrawLastError = layoutConvertOk ? "" : layoutConvertLastError;
    bool primaryTargetOk = false;
    bool secondaryTargetOk = false;
    bool primarySampleReadOk = false;
    bool secondarySampleReadOk = false;
    bool deterministicColorOk = false;

    if (layoutConvertOk) {
        // Redraw immediately before the readback below (single no-swap draw
        // shared by both sample points taken from this same frame).
        renderDrawOk = backend.diagnosticRenderMultiCamSpatialCompositeForReadback(
            primaryHandle, secondaryHandle, primaryConv.rect, secondaryConv.rect,
            VideoFrameTransform{}, VideoFrameTransform{});
        // GlesBackend::lastError() is sticky (never cleared on success), so
        // only capture it on failure -- otherwise it leaks a stale error
        // from an earlier step into this lane's reported last error.
        renderDrawLastError = renderDrawOk ? "" : SanitizeString(backend.lastError());

        const uint32_t primaryTarget = backend.diagnosticTextureTargetForHardwareBuffer(primaryHandle);
        const uint32_t secondaryTarget = backend.diagnosticTextureTargetForHardwareBuffer(secondaryHandle);
        primaryTargetOk = isPip ? (primaryTarget == kTextureTarget2D) : (primaryTarget == kTextureTargetExternalOes);
        secondaryTargetOk = isPip ? (secondaryTarget == kTextureTargetExternalOes) : (secondaryTarget == kTextureTarget2D);

        const NormalizedPoint primaryPoint =
            ComputePointInsideButOutside(layoutResult.primaryViewport, layoutResult.secondaryViewport);
        const NormalizedPoint secondaryPoint = RectCenter(layoutResult.secondaryViewport);

        const PixelSample primarySample = SampleNormalizedPoint(backend, primaryPoint.x, primaryPoint.y, width, height);
        const PixelSample secondarySample = SampleNormalizedPoint(backend, secondaryPoint.x, secondaryPoint.y, width, height);
        primarySampleReadOk = primarySample.readOk;
        secondarySampleReadOk = secondarySample.readOk;

        deterministicColorOk = isPip
            ? (primarySample.readOk && IsRedish(primarySample.rgba))
            : (secondarySample.readOk && IsBlueish(secondarySample.rgba));
    }

    // Present lane: final draw+swap only, not paired with a readback --
    // proves the descriptor-driven spatial composite reaches the attached
    // window surface end to end. Its own internal draw satisfies "redraw
    // before every readback lane" for itself (no readback follows it).
    bool presentLaneOk = false;
    std::string presentLaneLastError = layoutConvertOk ? "" : layoutConvertLastError;
    if (layoutConvertOk) {
        presentLaneOk = backend.diagnosticPresentMultiCamSpatialComposite(
            primaryHandle, secondaryHandle, primaryConv.rect, secondaryConv.rect,
            VideoFrameTransform{}, VideoFrameTransform{});
        presentLaneLastError = presentLaneOk ? "" : SanitizeString(backend.lastError());
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

    // Post-release invalid-handle lane: the render lane's own (now released)
    // handles fail closed with invalid_buffer_handle.
    const GlesViewportRectPx fullCanvasRect{0, 0, static_cast<uint32_t>(width), static_cast<uint32_t>(height)};
    const bool postReleaseRes = backend.diagnosticRenderMultiCamSpatialCompositeForReadback(
        primaryHandle, secondaryHandle, fullCanvasRect, fullCanvasRect, VideoFrameTransform{}, VideoFrameTransform{});
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
                               initCheckOk && attachCheckOk &&
                               importRgbaAOk && importRgbaBOk &&
                               importYcbcrAOk && importYcbcrBOk &&
                               layoutConvertOk &&
                               renderDrawOk && primaryTargetOk && secondaryTargetOk &&
                               primarySampleReadOk && secondarySampleReadOk && deterministicColorOk &&
                               presentLaneOk &&
                               releaseRgbaAOk && releaseRgbaBOk &&
                               releaseYcbcrAOk && releaseYcbcrBOk &&
                               postReleaseLaneOk &&
                               detachOk && shutdownOk && idempotentShutdownOk;

    // GlesBackend::lastError() is sticky (never cleared on success), so by
    // this point it still holds the intentional postReleaseLane failure
    // (invalid_buffer_handle) even when every check passed. The final
    // lastError must reflect overall pass/fail, not a stale per-lane
    // rejection: none on full pass, otherwise the sanitized backend error if
    // one is present, else a synthesized reason so FAIL never reports an
    // empty lastError.
    const std::string backendLastError = SanitizeString(backend.lastError());
    const std::string finalLastError = allChecksPass
        ? std::string()
        : (!backendLastError.empty()
               ? backendLastError
               : std::string("multicam_dynamic_descriptor_spatial_checks_failed_no_backend_error"));

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
        << "descriptorParse=success;"
        << "descriptorParseLastError=;"
        << "layoutModeResolved=" << LayoutModeName(modeRes.mode) << ";"
        << "anchorResolved=" << AnchorName(anchorRes.anchor) << ";"
        << "directionResolved=" << SplitDirectionName(directionRes.direction) << ";"
        << "layoutConvert=" << (layoutConvertOk ? "success" : "failed") << ";"
        << "layoutConvertLastError=" << (layoutConvertLastError.empty() ? "none" : layoutConvertLastError) << ";"
        << "primaryRectX=" << (layoutConvertOk ? primaryConv.rect.x : 0) << ";"
        << "primaryRectY=" << (layoutConvertOk ? primaryConv.rect.yBottom : 0) << ";"
        << "primaryRectW=" << (layoutConvertOk ? primaryConv.rect.width : 0) << ";"
        << "primaryRectH=" << (layoutConvertOk ? primaryConv.rect.height : 0) << ";"
        << "secondaryRectX=" << (layoutConvertOk ? secondaryConv.rect.x : 0) << ";"
        << "secondaryRectY=" << (layoutConvertOk ? secondaryConv.rect.yBottom : 0) << ";"
        << "secondaryRectW=" << (layoutConvertOk ? secondaryConv.rect.width : 0) << ";"
        << "secondaryRectH=" << (layoutConvertOk ? secondaryConv.rect.height : 0) << ";"
        << "renderLaneMode=" << LayoutModeName(modeRes.mode) << ";"
        << "primaryTextureKind=" << primaryTextureKind << ";"
        << "secondaryTextureKind=" << secondaryTextureKind << ";"
        << "renderDraw=" << (renderDrawOk ? "success" : "failed") << ";"
        << "renderDrawLastError=" << (renderDrawLastError.empty() ? "none" : renderDrawLastError) << ";"
        << "primaryTargetOk=" << (primaryTargetOk ? "true" : "false") << ";"
        << "secondaryTargetOk=" << (secondaryTargetOk ? "true" : "false") << ";"
        << "primarySampleReadOk=" << (primarySampleReadOk ? "true" : "false") << ";"
        << "secondarySampleReadOk=" << (secondarySampleReadOk ? "true" : "false") << ";"
        << "deterministicColorSide=" << deterministicColorSide << ";"
        << "deterministicColorOk=" << (deterministicColorOk ? "true" : "false") << ";"
        << "presentLane=" << (presentLaneOk ? "success" : "failed") << ";"
        << "presentLaneLastError=" << (presentLaneLastError.empty() ? "none" : presentLaneLastError) << ";"
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
