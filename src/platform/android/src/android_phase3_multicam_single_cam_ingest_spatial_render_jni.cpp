// P3-MULTICAM-NODE-SINGLE-CAM-INGEST-DESCRIPTOR-SPATIAL-RENDER: bounded
// diagnostic proof that one real Camera2 ImageReader(YUV_420_888)
// buffer-queue frame (imported as GL_TEXTURE_EXTERNAL_OES) and one synthetic
// RGBA_8888 HardwareBuffer (native-filled solid blue, imported as
// GL_TEXTURE_2D) are laid out by a caller-supplied Dart layout descriptor via
// the existing vanguard::compositors::ComputeMultiCamLayout(), rendered by
// the existing GlesBackend spatial compositor, structurally read back, and
// presented -- combining the Camera2 single-frame ingest pattern (see
// android_phase3_camera_concurrent_ingest_jni.cpp's sibling Kotlin harness)
// with the dynamic-descriptor spatial render route
// (android_phase3_multicam_dynamic_descriptor_spatial_render_jni.cpp), whose
// strict descriptor-parse/rect-conversion/readback-sample helpers are
// duplicated here (private anonymous-namespace helpers, not shared through a
// header, matching that file's own precedent of duplicating the OES
// route's helpers).
//
// Unlike the dynamic-descriptor route (whose primary/secondary texture
// assignment flips with layoutMode), this route's primary/secondary
// assignment is fixed regardless of layoutMode: the real camera YUV buffer
// is always the OES primary; the synthetic RGBA buffer is always the 2D
// secondary. Camera-side readback assertions are structural only (resolved
// OES target, render/readback success) -- never hue/luma/non-black/
// non-uniform content, since the camera frame's actual pixel content is
// unconstrained. The synthetic secondary is native-filled solid opaque blue,
// so its readback additionally asserts that deterministic color.
//
// Native is the sole layout authority: layoutMode/pipAnchor/splitDirection
// strings are resolved strictly (unrecognized value FAILS CLOSED before any
// AHardwareBuffer import or GLES work -- no default fallback).
// cornerRadiusFractionOfCanvasWidth/opacity are hard-set to 0.0/1.0; this
// route accepts no cornerRadius/opacity parameter at all.
//
// Proof boundary (exact):
// single_camera_ingest_buffer_queue_dynamic_descriptor_spatial_gles_oes_render_readback_only_no_concurrent_camera_no_vulkan_no_recording_no_export_no_product
//
// Non-claims: no concurrent/dual camera, no Vulkan, no recording/export, no
// product/editor UI, no color-correct YUV->RGB conversion, no camera hue/
// luma/content assertion.
//
// JNI entry point:
//   runAndroidDagPhase3SingleCamIngestSpatialRenderSmoke -> jstring

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
    "single_camera_ingest_buffer_queue_dynamic_descriptor_spatial_gles_oes_render_readback_only_no_concurrent_camera_no_vulkan_no_recording_no_export_no_product";

constexpr uint32_t kTextureTarget2D = 0x0DE1;
constexpr uint32_t kTextureTargetExternalOes = 0x8D65;

// ---------------------------------------------------------------------------
// AHardwareBuffer native symbol resolution (duplicated from
// android_phase3_multicam_dynamic_descriptor_spatial_render_jni.cpp).
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

bool FillBufferSolidColor(const NativeHardwareBufferFunctions& fns, AHardwareBuffer* buf,
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
// Strict Dart-descriptor-string -> native MultiCam* enum resolution
// (duplicated from android_phase3_multicam_dynamic_descriptor_spatial_
// render_jni.cpp): every resolver reports ok=false for any string outside
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
// Y-up) conversion (duplicated from android_phase3_multicam_dynamic_
// descriptor_spatial_render_jni.cpp, itself duplicated from
// android_phase3_multicam_spatial_oes_render_jni.cpp) -- same exact rounding
// rule: round the left/right (and top/bottom) edges independently via
// std::lround, then take widths/heights as the *difference* of the rounded
// edges. Every field is clamped finite into [0,1] first; nonfinite fields,
// an out-of-bounds rect after clamping, or a non-positive rounded width/
// height all fail closed.
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
        result.error = "single_cam_ingest_rect_nonfinite";
        return result;
    }

    const double x = ClampUnit(rect.x);
    const double y = ClampUnit(rect.y);
    const double w = ClampUnit(rect.width);
    const double h = ClampUnit(rect.height);

    constexpr double kBoundsEpsilon = 1e-6;
    if (x + w > 1.0 + kBoundsEpsilon || y + h > 1.0 + kBoundsEpsilon) {
        result.error = "single_cam_ingest_rect_out_of_bounds_after_clamp";
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
        result.error = "single_cam_ingest_rect_nonpositive_after_round";
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

bool IsBlueish(const uint8_t rgba[4]) {
    return rgba[0] < 50 && rgba[1] < 50 && rgba[2] > 200 && rgba[3] > 200;
}

// ---------------------------------------------------------------------------
// Derived (never hardcoded) readback sample points (duplicated from
// android_phase3_multicam_dynamic_descriptor_spatial_render_jni.cpp).
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
// lane, whose camera/synthetic rects never overlap), and falls back to an
// inset canvas corner only when that center collides with avoidRect (true
// for the PiP lane, whose camera primary rect is the full canvas containing
// the synthetic secondary PiP rect).
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
        << "cameraDescribe=not_run;cameraFormatIsYcbcr420=false;"
        << "rgbaDescribe=not_run;rgbaFill=not_run;"
        << "initialize=not_run;attach=not_run;"
        << "importCamera=not_run;handleCamera=0;targetCamera=0;"
        << "importRgba=not_run;handleRgba=0;targetRgba=0;"
        << "descriptorParse=" << descriptorParseStatus << ";"
        << "descriptorParseLastError=" << descriptorParseLastError << ";"
        << "layoutModeResolved=;anchorResolved=;directionResolved=;"
        << "layoutConvert=not_run;layoutConvertLastError=;"
        << "primaryRectX=0;primaryRectY=0;primaryRectW=0;primaryRectH=0;"
        << "secondaryRectX=0;secondaryRectY=0;secondaryRectW=0;secondaryRectH=0;"
        << "renderDraw=not_run;renderDrawLastError=;"
        << "primaryTargetOk=false;secondaryTargetOk=false;"
        << "primarySampleReadOk=false;secondarySampleReadOk=false;"
        << "secondaryColorOk=false;"
        << "presentLane=not_run;presentLaneLastError=;"
        << "releaseCamera=not_run;releaseCameraFence=-1;hasCameraAfterRelease=false;"
        << "releaseRgba=not_run;releaseRgbaFence=-1;hasRgbaAfterRelease=false;"
        << "postReleaseLane=not_run;postReleaseLastError=;"
        << "detach=not_run;shutdown=not_run;idempotentShutdown=not_run;"
        << "proofBoundary=" << kProofBoundary << ";"
        << "lastError=" << reason;
    return oss.str();
}

} // namespace

extern "C" JNIEXPORT jstring JNICALL
Java_com_connects_vanguard_1media_1engine_bridge_VanguardNativeBridge_runAndroidDagPhase3SingleCamIngestSpatialRenderSmoke(
    JNIEnv* env,
    jobject /* this */,
    jobject jSurface,
    jobject jCameraYuvBuffer,
    jobject jSyntheticRgbaBuffer,
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

    if (!jSurface || !jCameraYuvBuffer || !jSyntheticRgbaBuffer || width <= 0 || height <= 0) {
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

    AHardwareBuffer* ahbCamera = ahbFns.fromHardwareBuffer(env, jCameraYuvBuffer);
    AHardwareBuffer* ahbRgba = ahbFns.fromHardwareBuffer(env, jSyntheticRgbaBuffer);
    if (!ahbCamera || !ahbRgba) {
        ANativeWindow_release(window);
        return env->NewStringUTF(
            BuildFailureString("hardware_buffer_from_jobject_failed", "success").c_str());
    }

    AHardwareBuffer_Desc descCamera{};
    ahbFns.describe(ahbCamera, &descCamera);
    const bool cameraFormatIsYcbcr420 = (descCamera.format == AHARDWAREBUFFER_FORMAT_Y8Cb8Cr8_420);
    const bool cameraDescribeOk = (descCamera.width == static_cast<uint32_t>(width)) &&
                                  (descCamera.height == static_cast<uint32_t>(height)) &&
                                  (descCamera.layers == 1) &&
                                  cameraFormatIsYcbcr420 &&
                                  ((descCamera.usage & AHARDWAREBUFFER_USAGE_GPU_SAMPLED_IMAGE) != 0);

    AHardwareBuffer_Desc descRgba{};
    ahbFns.describe(ahbRgba, &descRgba);
    const bool rgbaDescribeOk = (descRgba.width == static_cast<uint32_t>(width)) &&
                                (descRgba.height == static_cast<uint32_t>(height)) &&
                                (descRgba.layers == 1) &&
                                (descRgba.format == AHARDWAREBUFFER_FORMAT_R8G8B8A8_UNORM) &&
                                ((descRgba.usage & AHARDWAREBUFFER_USAGE_GPU_SAMPLED_IMAGE) != 0) &&
                                ((descRgba.usage & AHARDWAREBUFFER_USAGE_CPU_WRITE_OFTEN) != 0) &&
                                (descRgba.stride >= descRgba.width);

    // The real camera buffer's describe/import/target-resolution outcome is
    // the sole signal the Kotlin harness uses to distinguish
    // decision=cameraIngestUnsupported (device/format cannot import this
    // camera's YUV_420_888 buffer as GL_TEXTURE_EXTERNAL_OES) from any other
    // failure; it is intentionally never treated as an early-return
    // precondition here so every other lane still reports its own explicit
    // not_run/failed status.
    if (!rgbaDescribeOk) {
        ANativeWindow_release(window);
        return env->NewStringUTF(
            BuildFailureString("synthetic_rgba_hardware_buffer_descriptor_mismatch", "success").c_str());
    }

    // Native fills the synthetic secondary buffer solid opaque blue; the
    // real camera YUV buffer is never CPU-filled (it already carries a real
    // camera frame).
    const bool rgbaFillOk = FillBufferSolidColor(ahbFns, ahbRgba, descRgba, 0, 0, 255, 255);
    if (!rgbaFillOk) {
        ANativeWindow_release(window);
        return env->NewStringUTF(
            BuildFailureString("synthetic_rgba_hardware_buffer_fill_failed", "success").c_str());
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

    // Camera buffer is always the OES primary; synthetic buffer is always
    // the 2D secondary, regardless of the resolved layoutMode.
    HardwareBufferHandle handleCamera = vanguard::render::kInvalidHardwareBufferHandle;
    vanguard::render::HardwareBufferDescriptor descImportCamera{};
    const auto resImportCamera = backend.importHardwareBuffer(ahbCamera, -1, &handleCamera, &descImportCamera);
    const uint32_t targetCamera = backend.diagnosticTextureTargetForHardwareBuffer(handleCamera);
    const bool importCameraOk = (resImportCamera == HardwareBufferImportResult::kSuccess) &&
                                (handleCamera != vanguard::render::kInvalidHardwareBufferHandle) &&
                                backend.hasHardwareBuffer(handleCamera) && (targetCamera == kTextureTargetExternalOes);

    HardwareBufferHandle handleRgba = vanguard::render::kInvalidHardwareBufferHandle;
    vanguard::render::HardwareBufferDescriptor descImportRgba{};
    const auto resImportRgba = backend.importHardwareBuffer(ahbRgba, -1, &handleRgba, &descImportRgba);
    const uint32_t targetRgba = backend.diagnosticTextureTargetForHardwareBuffer(handleRgba);
    const bool importRgbaOk = (resImportRgba == HardwareBufferImportResult::kSuccess) &&
                              (handleRgba != vanguard::render::kInvalidHardwareBufferHandle) &&
                              backend.hasHardwareBuffer(handleRgba) && (targetRgba == kTextureTarget2D);

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

    bool renderDrawOk = false;
    std::string renderDrawLastError = layoutConvertOk ? "" : layoutConvertLastError;
    bool primaryTargetOk = false;
    bool secondaryTargetOk = false;
    bool primarySampleReadOk = false;
    bool secondarySampleReadOk = false;
    bool secondaryColorOk = false;

    if (layoutConvertOk) {
        // Redraw immediately before the readback below (single no-swap draw
        // shared by both sample points taken from this same frame).
        renderDrawOk = backend.diagnosticRenderMultiCamSpatialCompositeForReadback(
            handleCamera, handleRgba, primaryConv.rect, secondaryConv.rect,
            VideoFrameTransform{}, VideoFrameTransform{});
        // GlesBackend::lastError() is sticky (never cleared on success), so
        // only capture it on failure -- otherwise it leaks a stale error
        // from an earlier step into this lane's reported last error.
        renderDrawLastError = renderDrawOk ? "" : SanitizeString(backend.lastError());

        const uint32_t primaryTarget = backend.diagnosticTextureTargetForHardwareBuffer(handleCamera);
        const uint32_t secondaryTarget = backend.diagnosticTextureTargetForHardwareBuffer(handleRgba);
        primaryTargetOk = (primaryTarget == kTextureTargetExternalOes);
        secondaryTargetOk = (secondaryTarget == kTextureTarget2D);

        const NormalizedPoint primaryPoint =
            ComputePointInsideButOutside(layoutResult.primaryViewport, layoutResult.secondaryViewport);
        const NormalizedPoint secondaryPoint = RectCenter(layoutResult.secondaryViewport);

        const PixelSample primarySample = SampleNormalizedPoint(backend, primaryPoint.x, primaryPoint.y, width, height);
        const PixelSample secondarySample = SampleNormalizedPoint(backend, secondaryPoint.x, secondaryPoint.y, width, height);
        // Camera-side sample is structural only -- read success, never
        // color content (the real camera frame's pixel content is
        // unconstrained).
        primarySampleReadOk = primarySample.readOk;
        secondarySampleReadOk = secondarySample.readOk;
        secondaryColorOk = secondarySample.readOk && IsBlueish(secondarySample.rgba);
    }

    // Present lane: final draw+swap only, not paired with a readback --
    // proves the descriptor-driven spatial composite reaches the attached
    // window surface end to end.
    bool presentLaneOk = false;
    std::string presentLaneLastError = layoutConvertOk ? "" : layoutConvertLastError;
    if (layoutConvertOk) {
        presentLaneOk = backend.diagnosticPresentMultiCamSpatialComposite(
            handleCamera, handleRgba, primaryConv.rect, secondaryConv.rect,
            VideoFrameTransform{}, VideoFrameTransform{});
        presentLaneLastError = presentLaneOk ? "" : SanitizeString(backend.lastError());
    }

    int releaseFenceCamera = -999;
    const auto resReleaseCamera = backend.releaseHardwareBuffer(handleCamera, &releaseFenceCamera);
    const bool hasCameraAfterRelease = backend.hasHardwareBuffer(handleCamera);
    const bool releaseCameraOk = (resReleaseCamera == HardwareBufferImportResult::kSuccess) &&
                                 (releaseFenceCamera >= -1) && !hasCameraAfterRelease;
    if (releaseFenceCamera >= 0) {
        close(releaseFenceCamera);
    }

    int releaseFenceRgba = -999;
    const auto resReleaseRgba = backend.releaseHardwareBuffer(handleRgba, &releaseFenceRgba);
    const bool hasRgbaAfterRelease = backend.hasHardwareBuffer(handleRgba);
    const bool releaseRgbaOk = (resReleaseRgba == HardwareBufferImportResult::kSuccess) &&
                               (releaseFenceRgba >= -1) && !hasRgbaAfterRelease;
    if (releaseFenceRgba >= 0) {
        close(releaseFenceRgba);
    }

    // Post-release invalid-handle lane: the render lane's own (now released)
    // handles fail closed with invalid_buffer_handle.
    const GlesViewportRectPx fullCanvasRect{0, 0, static_cast<uint32_t>(width), static_cast<uint32_t>(height)};
    const bool postReleaseRes = backend.diagnosticRenderMultiCamSpatialCompositeForReadback(
        handleCamera, handleRgba, fullCanvasRect, fullCanvasRect, VideoFrameTransform{}, VideoFrameTransform{});
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

    const bool allChecksPass = cameraDescribeOk && rgbaDescribeOk && rgbaFillOk &&
                               initCheckOk && attachCheckOk &&
                               importCameraOk && importRgbaOk &&
                               layoutConvertOk &&
                               renderDrawOk && primaryTargetOk && secondaryTargetOk &&
                               primarySampleReadOk && secondarySampleReadOk && secondaryColorOk &&
                               presentLaneOk &&
                               releaseCameraOk && releaseRgbaOk &&
                               postReleaseLaneOk &&
                               detachOk && shutdownOk && idempotentShutdownOk;

    // GlesBackend::lastError() is sticky (never cleared on success), so by
    // this point it still holds the intentional postReleaseLane failure
    // (invalid_buffer_handle) even when every check passed. The final
    // lastError must reflect overall pass/fail, not a stale per-lane
    // rejection: none on full pass, otherwise the sanitized backend error if
    // one is present, else a synthesized reason so FAIL never reports an
    // empty lastError. A camera-describe/import/target failure is reported
    // via the explicit yuv_ahb_import_unsupported_format reason so the
    // Kotlin harness can map it to decision=cameraIngestUnsupported without
    // depending on GlesBackend's sticky per-lane error text.
    const std::string backendLastError = SanitizeString(backend.lastError());
    std::string finalLastError;
    if (allChecksPass) {
        finalLastError.clear();
    } else if (!cameraDescribeOk || !importCameraOk) {
        finalLastError = "yuv_ahb_import_unsupported_format";
    } else if (!backendLastError.empty()) {
        finalLastError = backendLastError;
    } else {
        finalLastError = "single_cam_ingest_spatial_checks_failed_no_backend_error";
    }

    std::ostringstream oss;
    oss << "status=" << (allChecksPass ? "PASS" : "FAIL") << ";"
        << "width=" << width << ";"
        << "height=" << height << ";"
        << "clientVersion=" << clientVersion << ";"
        << "vendor=" << vendor << ";"
        << "renderer=" << renderer << ";"
        << "version=" << version << ";"
        << "cameraDescribe=" << (cameraDescribeOk ? "success" : "failed") << ";"
        << "cameraFormatIsYcbcr420=" << (cameraFormatIsYcbcr420 ? "true" : "false") << ";"
        << "rgbaDescribe=" << (rgbaDescribeOk ? "success" : "failed") << ";"
        << "rgbaFill=" << (rgbaFillOk ? "success" : "failed") << ";"
        << "initialize=" << (initCheckOk ? "success" : "failed") << ";"
        << "attach=" << (attachCheckOk ? "success" : "failed") << ";"
        << "importCamera=" << (importCameraOk ? "success" : "failed") << ";"
        << "handleCamera=" << handleCamera << ";"
        << "targetCamera=" << targetCamera << ";"
        << "importRgba=" << (importRgbaOk ? "success" : "failed") << ";"
        << "handleRgba=" << handleRgba << ";"
        << "targetRgba=" << targetRgba << ";"
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
        << "renderDraw=" << (renderDrawOk ? "success" : "failed") << ";"
        << "renderDrawLastError=" << (renderDrawLastError.empty() ? "none" : renderDrawLastError) << ";"
        << "primaryTargetOk=" << (primaryTargetOk ? "true" : "false") << ";"
        << "secondaryTargetOk=" << (secondaryTargetOk ? "true" : "false") << ";"
        << "primarySampleReadOk=" << (primarySampleReadOk ? "true" : "false") << ";"
        << "secondarySampleReadOk=" << (secondarySampleReadOk ? "true" : "false") << ";"
        << "secondaryColorOk=" << (secondaryColorOk ? "true" : "false") << ";"
        << "presentLane=" << (presentLaneOk ? "success" : "failed") << ";"
        << "presentLaneLastError=" << (presentLaneLastError.empty() ? "none" : presentLaneLastError) << ";"
        << "releaseCamera=" << (releaseCameraOk ? "success" : "failed") << ";"
        << "releaseCameraFence=" << releaseFenceCamera << ";"
        << "hasCameraAfterRelease=" << (hasCameraAfterRelease ? "true" : "false") << ";"
        << "releaseRgba=" << (releaseRgbaOk ? "success" : "failed") << ";"
        << "releaseRgbaFence=" << releaseFenceRgba << ";"
        << "hasRgbaAfterRelease=" << (hasRgbaAfterRelease ? "true" : "false") << ";"
        << "postReleaseLane=" << (postReleaseLaneOk ? "rejected_as_expected" : "failed") << ";"
        << "postReleaseLastError=" << postReleaseLastError << ";"
        << "detach=" << (detachOk ? "success" : "failed") << ";"
        << "shutdown=" << (shutdownOk ? "success" : "failed") << ";"
        << "idempotentShutdown=" << (idempotentShutdownOk ? "success" : "failed") << ";"
        << "proofBoundary=" << kProofBoundary << ";"
        << "lastError=" << (finalLastError.empty() ? "none" : finalLastError);

    return env->NewStringUTF(oss.str().c_str());
}
