// android_dualcam_compositor_jni.cpp
// Slice 1: Native Dual-Camera Compositor Core — JNI entry points.
//
// Exposes four JNI functions:
//   nativeCreateDualCamSession    — Vulkan swapchain OR GLES EGL session + command pool.
//   nativeDualCamCompositeFrame   — Per-frame AHB→Vulkan import + swapchain render, OR GLES draw.
//   nativeComputeMultiCamLayout   — Thin JSON wrapper over ComputeMultiCamLayout().
//   nativeDestroyDualCamSession   — Idempotent teardown (vkDeviceWaitIdle or eglDestroyContext).
//
// Logging tag: "VanguardDualCamJNI"
//
// Architectural constraints (Slice 1):
//   - No Camera2 / CameraDevice / CaptureSession interaction.
//   - No TextureRegistry / Flutter surfaces — outputSurface is caller-supplied.
//   - No photo capture readback (separate one-shot path, Slice 4).

#if defined(__ANDROID__)

#ifndef VK_USE_PLATFORM_ANDROID_KHR
#define VK_USE_PLATFORM_ANDROID_KHR
#endif

#include <jni.h>
#include <android/log.h>
#include <android/native_window_jni.h>
#include <android/hardware_buffer_jni.h>

#include <vulkan/vulkan.h>
#include <EGL/egl.h>
#include <GLES3/gl3.h>

#include <string>
#include <cstring>
#include <memory>
#include <atomic>
#include <dlfcn.h>
#include <cstdlib>

// Engine helpers.
#include "vanguard/render/vulkan_backend.h"
#include <unistd.h>
#include <cmath>
#include <algorithm>

// Layout math — public compositors include dir.
#include "vanguard/compositors/multi_cam_compositor_node.h"

// Backend probe — platform/android/include.
#include "vanguard/platform/android_backend_probe.h"

#define VGLOG_TAG "VanguardDualCamJNI"
#define VGLOG_I(...) __android_log_print(ANDROID_LOG_INFO,  VGLOG_TAG, __VA_ARGS__)
#define VGLOG_W(...) __android_log_print(ANDROID_LOG_WARN,  VGLOG_TAG, __VA_ARGS__)
#define VGLOG_E(...) __android_log_print(ANDROID_LOG_ERROR, VGLOG_TAG, __VA_ARGS__)
#define VGLOG_D(...) __android_log_print(ANDROID_LOG_DEBUG, VGLOG_TAG, __VA_ARGS__)

namespace {

// ---------------------------------------------------------------------------
// AHardwareBuffer_fromHardwareBuffer runtime resolution (pattern established
// in existing JNI TUs).
// ---------------------------------------------------------------------------
using FnAHardwareBuffer_fromHardwareBuffer = AHardwareBuffer* (*)(JNIEnv*, jobject);

FnAHardwareBuffer_fromHardwareBuffer ResolveAHBFromHardwareBuffer() {
    void* lib = dlopen("libandroid.so", RTLD_NOW | RTLD_LOCAL);
    if (!lib) return nullptr;
    auto fn = reinterpret_cast<FnAHardwareBuffer_fromHardwareBuffer>(
        dlsym(lib, "AHardwareBuffer_fromHardwareBuffer"));
    dlclose(lib);
    return fn;
}

// ---------------------------------------------------------------------------
// JSON layout parsing helpers (fail-closed: reject any unknown string).
// ---------------------------------------------------------------------------
struct ParsedLayoutParams {
    bool ok = false;
    std::string rejectionReason;
    vanguard::compositors::MultiCamLayoutMode  mode;
    vanguard::compositors::MultiCamPiPAnchor   anchor;
    vanguard::compositors::MultiCamSplitDirection direction;
    double splitRatio         = 0.5;
    double pipWidthFraction   = 0.3;
    double pipCenterX         = 0.5; // normalized [0,1]; used only when anchor == kFreeFloating
    double pipCenterY         = 0.5; // normalized [0,1]; used only when anchor == kFreeFloating
    double pipCornerRadius    = 24.0;
};

// Minimal JSON value extraction — looks for "key":"value" or "key":number.
static std::string ExtractJsonString(const std::string& json, const std::string& key) {
    std::string search = "\"" + key + "\":\"";
    auto pos = json.find(search);
    if (pos == std::string::npos) return "";
    pos += search.size();
    auto end = json.find('"', pos);
    if (end == std::string::npos) return "";
    return json.substr(pos, end - pos);
}

static double ExtractJsonDouble(const std::string& json, const std::string& key, double fallback) {
    std::string search = "\"" + key + "\":";
    auto pos = json.find(search);
    if (pos == std::string::npos) return fallback;
    pos += search.size();
    try { return std::stod(json.substr(pos)); } catch (...) { return fallback; }
}

static ParsedLayoutParams ParseLayoutJson(const std::string& json) {
    ParsedLayoutParams out;
    using namespace vanguard::compositors;

    const std::string modeStr      = ExtractJsonString(json, "layoutMode");
    const std::string anchorStr    = ExtractJsonString(json, "pipAnchor");
    const std::string dirStr       = ExtractJsonString(json, "splitDirection");

    if (modeStr == "pip")         out.mode = MultiCamLayoutMode::kPictureInPicture;
    else if (modeStr == "splitScreen") out.mode = MultiCamLayoutMode::kSplitScreen;
    else { out.rejectionReason = "unknown_layout_mode:" + modeStr; return out; }

    if      (anchorStr == "freeFloating")  out.anchor = MultiCamPiPAnchor::kFreeFloating;
    else if (anchorStr == "topLeft")       out.anchor = MultiCamPiPAnchor::kTopLeft;
    else if (anchorStr == "topRight")      out.anchor = MultiCamPiPAnchor::kTopRight;
    else if (anchorStr == "bottomLeft")    out.anchor = MultiCamPiPAnchor::kBottomLeft;
    else if (anchorStr == "bottomRight")   out.anchor = MultiCamPiPAnchor::kBottomRight;
    else { out.rejectionReason = "unknown_pip_anchor:" + anchorStr; return out; }

    if      (dirStr == "topBottom")  out.direction = MultiCamSplitDirection::kTopBottom;
    else if (dirStr == "leftRight")  out.direction = MultiCamSplitDirection::kLeftRight;
    else { out.rejectionReason = "unknown_split_direction:" + dirStr; return out; }

    out.splitRatio       = ExtractJsonDouble(json, "splitRatio", 0.5);
    out.pipWidthFraction = ExtractJsonDouble(json, "pipWidthFraction", 0.3);
    out.pipCenterX       = ExtractJsonDouble(json, "pipCenterX", 0.5);
    out.pipCenterY       = ExtractJsonDouble(json, "pipCenterY", 0.5);
    out.pipCornerRadius  = ExtractJsonDouble(json, "pipCornerRadius", 24.0);
    out.ok = true;
    return out;
}

// ---------------------------------------------------------------------------
// Session structs
// ---------------------------------------------------------------------------

struct VulkanDualCamSession {
    std::unique_ptr<vanguard::render::VulkanBackend> backend;
    ANativeWindow* nativeWindow = nullptr;
    uint32_t width  = 0;
    uint32_t height = 0;

    bool isValid() const { return backend != nullptr && backend->hasSurface(); }

    void Teardown() {
        if (backend) {
            backend->detachSurface();
            backend->shutdown();
            backend.reset();
        }
        if (nativeWindow) {
            ANativeWindow_release(nativeWindow);
            nativeWindow = nullptr;
        }
    }
};

struct GlesDualCamSession {
    EGLDisplay display = EGL_NO_DISPLAY;
    EGLContext context = EGL_NO_CONTEXT;
    EGLSurface surface = EGL_NO_SURFACE;
    ANativeWindow* nativeWindow = nullptr;

    bool isValid() const { return context != EGL_NO_CONTEXT; }

    void Teardown() {
        if (display == EGL_NO_DISPLAY) return;
        eglMakeCurrent(display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
        if (surface != EGL_NO_SURFACE) { eglDestroySurface(display, surface); surface = EGL_NO_SURFACE; }
        if (context != EGL_NO_CONTEXT) { eglDestroyContext(display, context); context = EGL_NO_CONTEXT; }
        eglTerminate(display);
        display = EGL_NO_DISPLAY;
        if (nativeWindow) { ANativeWindow_release(nativeWindow); nativeWindow = nullptr; }
    }
};

// Discriminated union session — opaque jlong handle points to this.
struct DualCamSession {
    bool useVulkan = false;
    std::unique_ptr<VulkanDualCamSession> vk;
    std::unique_ptr<GlesDualCamSession>   gles;
    uint32_t canvasWidth  = 0;
    uint32_t canvasHeight = 0;

    void Teardown() {
        if (vk)   { vk->Teardown();   vk.reset(); }
        if (gles) { gles->Teardown(); gles.reset(); }
    }
};

// ---------------------------------------------------------------------------
// Vulkan session creation
// ---------------------------------------------------------------------------
static bool CreateVulkanSession(VulkanDualCamSession& s, ANativeWindow* window,
                                uint32_t width, uint32_t height,
                                std::string& outErr) {
    s.backend = std::make_unique<vanguard::render::VulkanBackend>();
    if (!s.backend->initialize()) {
        outErr = "VulkanBackend::initialize failed";
        s.Teardown();
        return false;
    }
    s.nativeWindow = window;
    ANativeWindow_acquire(window);
    if (!s.backend->attachSurface(window, width, height)) {
        outErr = "VulkanBackend::attachSurface failed";
        s.Teardown();
        return false;
    }
    s.width = width;
    s.height = height;
    VGLOG_I("Vulkan session created via VulkanBackend width=%u height=%u", width, height);
    return true;
}

// ---------------------------------------------------------------------------
// GLES session creation
// ---------------------------------------------------------------------------
static bool CreateGlesSession(GlesDualCamSession& g, ANativeWindow* window,
                              std::string& outErr) {
    g.display = eglGetDisplay(EGL_DEFAULT_DISPLAY);
    if (g.display == EGL_NO_DISPLAY) { outErr = "eglGetDisplay failed"; return false; }

    EGLint major = 0, minor = 0;
    if (!eglInitialize(g.display, &major, &minor)) {
        outErr = "eglInitialize failed";
        g.Teardown(); return false;
    }

    const EGLint attribs[] = {
        EGL_RENDERABLE_TYPE, EGL_OPENGL_ES3_BIT,
        EGL_SURFACE_TYPE, EGL_WINDOW_BIT,
        EGL_RED_SIZE, 8, EGL_GREEN_SIZE, 8, EGL_BLUE_SIZE, 8, EGL_ALPHA_SIZE, 8,
        EGL_NONE
    };
    EGLConfig config = nullptr;
    EGLint numConfigs = 0;
    if (!eglChooseConfig(g.display, attribs, &config, 1, &numConfigs) || numConfigs == 0) {
        outErr = "eglChooseConfig failed";
        g.Teardown(); return false;
    }

    const EGLint ctxAttribs[] = { EGL_CONTEXT_CLIENT_VERSION, 3, EGL_NONE };
    g.context = eglCreateContext(g.display, config, EGL_NO_CONTEXT, ctxAttribs);
    if (g.context == EGL_NO_CONTEXT) {
        outErr = "eglCreateContext failed";
        g.Teardown(); return false;
    }

    g.nativeWindow = window;
    ANativeWindow_acquire(window);
    g.surface = eglCreateWindowSurface(g.display, config, window, nullptr);
    if (g.surface == EGL_NO_SURFACE) {
        outErr = "eglCreateWindowSurface failed";
        g.Teardown(); return false;
    }

    if (!eglMakeCurrent(g.display, g.surface, g.surface, g.context)) {
        outErr = "eglMakeCurrent failed";
        g.Teardown(); return false;
    }

    // Unbind from the calling (creation) thread so the render thread can
    // freely call eglMakeCurrent without getting EGL_BAD_ACCESS.
    eglMakeCurrent(g.display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);

    VGLOG_I("GLES session created");
    return true;
}

// ---------------------------------------------------------------------------
// Layout JSON builder (mirrors Kotlin buildLayoutJson).
// ---------------------------------------------------------------------------
static std::string BuildLayoutJson(const ParsedLayoutParams& p) {
    using namespace vanguard::compositors;
    const char* modeStr = (p.mode == MultiCamLayoutMode::kSplitScreen) ? "splitScreen" : "pip";
    const char* anchorStr = "freeFloating";
    switch (p.anchor) {
        case MultiCamPiPAnchor::kTopLeft:     anchorStr = "topLeft";     break;
        case MultiCamPiPAnchor::kTopRight:    anchorStr = "topRight";    break;
        case MultiCamPiPAnchor::kBottomLeft:  anchorStr = "bottomLeft";  break;
        case MultiCamPiPAnchor::kBottomRight: anchorStr = "bottomRight"; break;
        default: break;
    }
    const char* dirStr = (p.direction == MultiCamSplitDirection::kLeftRight) ? "leftRight" : "topBottom";
    char buf[512];
    std::snprintf(buf, sizeof(buf),
        "{\"layoutMode\":\"%s\",\"pipAnchor\":\"%s\","
        "\"splitDirection\":\"%s\","
        "\"splitRatio\":%.4f,\"pipWidthFraction\":%.4f}",
        modeStr, anchorStr, dirStr, p.splitRatio, p.pipWidthFraction);
    return buf;
}

// ---------------------------------------------------------------------------
// Vulkan per-frame composite render
// ---------------------------------------------------------------------------
static bool VulkanCompositeFrame(VulkanDualCamSession& s,
                                 AHardwareBuffer* frontAhb,
                                 AHardwareBuffer* backAhb,
                                 const ParsedLayoutParams& layout) {
    using namespace vanguard::render;
    using namespace vanguard::compositors;

    if (!s.backend || !frontAhb || !backAhb) {
        return false;
    }

    HardwareBufferHandle backHandle = kInvalidHardwareBufferHandle;
    HardwareBufferDescriptor backDesc{};
    auto backRes = s.backend->importHardwareBuffer(static_cast<void*>(backAhb), -1, &backHandle, &backDesc);
    if (backRes != HardwareBufferImportResult::kSuccess) {
        VGLOG_W("Back AHB import failed result=%d", static_cast<int>(backRes));
        return false;
    }

    HardwareBufferHandle frontHandle = kInvalidHardwareBufferHandle;
    HardwareBufferDescriptor frontDesc{};
    auto frontRes = s.backend->importHardwareBuffer(static_cast<void*>(frontAhb), -1, &frontHandle, &frontDesc);
    if (frontRes != HardwareBufferImportResult::kSuccess) {
        VGLOG_W("Front AHB import failed result=%d", static_cast<int>(frontRes));
        int releaseFd = -1;
        s.backend->releaseHardwareBuffer(backHandle, &releaseFd);
        if (releaseFd >= 0) ::close(releaseFd);
        return false;
    }

    const double canvasW = static_cast<double>(s.width);
    const double canvasH = static_cast<double>(s.height);
    const double canvasAr = (canvasH > 0) ? (canvasW / canvasH) : (9.0 / 16.0);

    MultiCamLayout mcl{};
    mcl.mode = layout.mode;
    mcl.canvasWidth = canvasW;
    mcl.canvasHeight = canvasH;
    mcl.pip.anchor = layout.anchor;
    mcl.pip.centerX = std::max(0.0, std::min(1.0, layout.pipCenterX));
    mcl.pip.centerY = std::max(0.0, std::min(1.0, layout.pipCenterY));
    mcl.pip.normalizedWidth = std::max(0.05, std::min(0.95, layout.pipWidthFraction));
    mcl.pip.aspectRatio = canvasAr;
    mcl.pip.marginFraction = 0.02;
    mcl.pip.cornerRadiusFractionOfCanvasWidth = (canvasW > 0) ? (layout.pipCornerRadius / canvasW) : 0.02;
    mcl.pip.opacity = 1.0;
    mcl.split.direction = layout.direction;
    mcl.split.splitRatio = std::max(0.2, std::min(0.8, layout.splitRatio));

    const MultiCamLayoutResult res = ComputeMultiCamLayout(mcl);

    RenderDestinationRect backRect{
        static_cast<int32_t>(std::round(res.primaryViewport.x * canvasW)),
        static_cast<int32_t>(std::round(res.primaryViewport.y * canvasH)),
        static_cast<int32_t>(std::round(res.primaryViewport.width * canvasW)),
        static_cast<int32_t>(std::round(res.primaryViewport.height * canvasH)),
    };

    RenderDestinationRect frontRect{
        static_cast<int32_t>(std::round(res.secondaryViewport.x * canvasW)),
        static_cast<int32_t>(std::round(res.secondaryViewport.y * canvasH)),
        static_cast<int32_t>(std::round(res.secondaryViewport.width * canvasW)),
        static_cast<int32_t>(std::round(res.secondaryViewport.height * canvasH)),
    };

    if (layout.mode == vanguard::compositors::MultiCamLayoutMode::kSplitScreen &&
        layout.direction == vanguard::compositors::MultiCamSplitDirection::kLeftRight) {
        // Vertical Split (Left/Right): Aspect-fit (BoxFit.contain) each stream within its
        // allocated half-width slot, centering vertically and preserving uncropped 9:16
        // framing with black letterbox bands on top and bottom (TikTok-style).
        auto fitToSlot = [&](const vanguard::compositors::NormalizedRect& vp) -> RenderDestinationRect {
            const double slotX = vp.x * canvasW;
            const double slotY = vp.y * canvasH;
            const double slotW = vp.width * canvasW;
            const double slotH = vp.height * canvasH;
            double fittedW = slotW;
            double fittedH = (canvasAr > 0.0) ? (slotW / canvasAr) : slotH;
            if (fittedH > slotH) {
                fittedH = slotH;
                fittedW = slotH * canvasAr;
            }
            const double offX = slotX + (slotW - fittedW) * 0.5;
            const double offY = slotY + (slotH - fittedH) * 0.5;
            return RenderDestinationRect{
                static_cast<int32_t>(std::round(offX)),
                static_cast<int32_t>(std::round(offY)),
                static_cast<int32_t>(std::round(fittedW)),
                static_cast<int32_t>(std::round(fittedH)),
            };
        };
        backRect = fitToSlot(res.primaryViewport);
        frontRect = fitToSlot(res.secondaryViewport);
    }

    const float cameraCornerRadiusPx = static_cast<float>(
        std::max(0.0, res.secondaryCornerRadiusFractionOfCanvasWidth * canvasW));

    auto renderRes = s.backend->renderDuetLayoutFrame(
        backHandle,
        frontHandle,
        backRect,
        frontRect,
        backDesc.width, backDesc.height,
        frontDesc.width, frontDesc.height,
        /*sourceRotationDegrees=*/90, /*sourceMirrorHorizontal=*/false,
        /*cameraRotationDegrees=*/270, /*cameraMirrorHorizontal=*/true,
        cameraCornerRadiusPx
    );

    int backReleaseFd = -1;
    s.backend->releaseHardwareBuffer(backHandle, &backReleaseFd);
    if (backReleaseFd >= 0) ::close(backReleaseFd);

    int frontReleaseFd = -1;
    s.backend->releaseHardwareBuffer(frontHandle, &frontReleaseFd);
    if (frontReleaseFd >= 0) ::close(frontReleaseFd);

    return renderRes == RenderFrameResult::kSuccess || renderRes == RenderFrameResult::kSuboptimal;
}

// ---------------------------------------------------------------------------
// GLES per-frame composite render (clear + swap — full draw in Slice 3).
// ---------------------------------------------------------------------------
static bool GlesCompositeFrame(GlesDualCamSession& g) {
    if (!eglMakeCurrent(g.display, g.surface, g.surface, g.context)) {
        VGLOG_W("eglMakeCurrent failed in render frame");
        return false;
    }
    // Slice 1 proof: clear to opaque black.
    glClearColor(0.0f, 0.0f, 0.0f, 1.0f);
    glClear(GL_COLOR_BUFFER_BIT);
    // TODO Slice 3: bind GlesMultiCamSpatialCompositor drawSpatialComposite here.
    if (!eglSwapBuffers(g.display, g.surface)) {
        VGLOG_W("eglSwapBuffers failed");
        return false;
    }
    return true;
}

} // anonymous namespace

// ===========================================================================
// JNI entry points
// ===========================================================================

extern "C" {

// ---------------------------------------------------------------------------
// nativeCreateDualCamSession
// ---------------------------------------------------------------------------
JNIEXPORT jlong JNICALL
Java_com_connects_vanguard_1media_1engine_bridge_VanguardNativeBridge_nativeCreateDualCamSession(
    JNIEnv* env, jclass /*cls*/,
    jobject outputSurface, jint width, jint height, jboolean useVulkan)
{
    VGLOG_I("nativeCreateDualCamSession useVulkan=%d width=%d height=%d",
            static_cast<int>(useVulkan), width, height);

    if (!outputSurface) {
        VGLOG_E("outputSurface is null");
        return 0L;
    }

    ANativeWindow* window = ANativeWindow_fromSurface(env, outputSurface);
    if (!window) {
        VGLOG_E("ANativeWindow_fromSurface returned null");
        return 0L;
    }

    auto session = std::make_unique<DualCamSession>();
    session->canvasWidth  = static_cast<uint32_t>(width);
    session->canvasHeight = static_cast<uint32_t>(height);
    session->useVulkan    = static_cast<bool>(useVulkan);

    std::string err;
    bool ok = false;

    if (useVulkan) {
        session->vk = std::make_unique<VulkanDualCamSession>();
        ok = CreateVulkanSession(*session->vk, window, static_cast<uint32_t>(width),
                                 static_cast<uint32_t>(height), err);
        if (!ok) {
            VGLOG_W("Vulkan session creation failed: %s", err.c_str());
            ANativeWindow_release(window);
            return 0L;
        }
    } else {
        session->gles = std::make_unique<GlesDualCamSession>();
        ok = CreateGlesSession(*session->gles, window, err);
        if (!ok) {
            VGLOG_W("GLES session creation failed: %s", err.c_str());
            ANativeWindow_release(window);
            return 0L;
        }
    }

    // The session's sub-session owns the ANativeWindow reference now; release our ref.
    ANativeWindow_release(window);

    jlong handle = reinterpret_cast<jlong>(session.release());
    VGLOG_I("nativeCreateDualCamSession success handle=%lld", static_cast<long long>(handle));
    return handle;
}

// ---------------------------------------------------------------------------
// nativeDualCamCompositeFrame
// ---------------------------------------------------------------------------
JNIEXPORT jboolean JNICALL
Java_com_connects_vanguard_1media_1engine_bridge_VanguardNativeBridge_nativeDualCamCompositeFrame(
    JNIEnv* env, jclass /*cls*/,
    jlong sessionHandle,
    jobject frontHardwareBuffer,
    jobject backHardwareBuffer,
    jstring layoutParamsJson)
{
    if (sessionHandle == 0L) {
        VGLOG_W("nativeDualCamCompositeFrame: null session handle");
        return JNI_FALSE;
    }

    auto* session = reinterpret_cast<DualCamSession*>(sessionHandle);

    // Parse layout JSON.
    ParsedLayoutParams layout;
    if (layoutParamsJson) {
        const char* jsonCStr = env->GetStringUTFChars(layoutParamsJson, nullptr);
        if (jsonCStr) {
            layout = ParseLayoutJson(std::string(jsonCStr));
            env->ReleaseStringUTFChars(layoutParamsJson, jsonCStr);
        }
    }
    if (!layout.ok) {
        VGLOG_W("nativeDualCamCompositeFrame: layout parse failed: %s", layout.rejectionReason.c_str());
        // Fall through with default layout for robustness.
        layout.ok        = true;
        layout.mode      = vanguard::compositors::MultiCamLayoutMode::kPictureInPicture;
        layout.anchor    = vanguard::compositors::MultiCamPiPAnchor::kBottomRight;
        layout.direction = vanguard::compositors::MultiCamSplitDirection::kLeftRight;
    }

    if (session->useVulkan && session->vk && session->vk->isValid()) {
        // Resolve Java HardwareBuffer objects → AHardwareBuffer*.
        static auto fnFromHwBuf = ResolveAHBFromHardwareBuffer();
        AHardwareBuffer* frontAhb = (frontHardwareBuffer && fnFromHwBuf)
            ? fnFromHwBuf(env, frontHardwareBuffer) : nullptr;
        AHardwareBuffer* backAhb  = (backHardwareBuffer && fnFromHwBuf)
            ? fnFromHwBuf(env, backHardwareBuffer) : nullptr;

        bool ok = VulkanCompositeFrame(*session->vk, frontAhb, backAhb, layout);
        return ok ? JNI_TRUE : JNI_FALSE;
    } else if (!session->useVulkan && session->gles && session->gles->isValid()) {
        // GLES path: SurfaceTextures updated Kotlin-side before calling here;
        // native side clears + swaps.
        bool ok = GlesCompositeFrame(*session->gles);
        return ok ? JNI_TRUE : JNI_FALSE;
    }

    VGLOG_W("nativeDualCamCompositeFrame: no valid backend session");
    return JNI_FALSE;
}

// ---------------------------------------------------------------------------
// nativeComputeMultiCamLayout — thin JSON wrapper over ComputeMultiCamLayout().
// ---------------------------------------------------------------------------
JNIEXPORT jstring JNICALL
Java_com_connects_vanguard_1media_1engine_bridge_VanguardNativeBridge_nativeComputeMultiCamLayout(
    JNIEnv* env, jclass /*cls*/,
    jstring layoutParamsJson, jint canvasWidth, jint canvasHeight)
{
    using namespace vanguard::compositors;

    if (!layoutParamsJson) {
        return env->NewStringUTF("{\"error\":\"null_layout_params\"}");
    }
    const char* jsonCStr = env->GetStringUTFChars(layoutParamsJson, nullptr);
    if (!jsonCStr) {
        return env->NewStringUTF("{\"error\":\"get_string_chars_failed\"}");
    }
    ParsedLayoutParams p = ParseLayoutJson(std::string(jsonCStr));
    env->ReleaseStringUTFChars(layoutParamsJson, jsonCStr);

    if (!p.ok) {
        std::string errJson = "{\"error\":\"parse_failed\",\"reason\":\"" + p.rejectionReason + "\"}";
        return env->NewStringUTF(errJson.c_str());
    }

    // Clamp splitRatio and pipWidthFraction to safe ranges.
    const double splitRatio = std::max(0.2, std::min(0.8, p.splitRatio));
    const double pipWidth   = std::max(0.05, std::min(0.95, p.pipWidthFraction));
    const double canvasAr   = (canvasHeight > 0)
        ? static_cast<double>(canvasWidth) / static_cast<double>(canvasHeight)
        : 9.0 / 16.0;

    MultiCamLayout layout{};
    layout.mode         = p.mode;
    layout.canvasWidth  = static_cast<double>(canvasWidth);
    layout.canvasHeight = static_cast<double>(canvasHeight);
    layout.pip.anchor              = p.anchor;
    layout.pip.centerX             = std::max(0.0, std::min(1.0, p.pipCenterX));
    layout.pip.centerY             = std::max(0.0, std::min(1.0, p.pipCenterY));
    layout.pip.normalizedWidth     = pipWidth;
    layout.pip.aspectRatio         = canvasAr;
    layout.pip.marginFraction      = 0.02;
    layout.pip.cornerRadiusFractionOfCanvasWidth = 0.02;
    layout.pip.opacity             = 1.0;
    layout.split.direction         = p.direction;
    layout.split.splitRatio        = splitRatio;

    const MultiCamLayoutResult result = ComputeMultiCamLayout(layout);

    char buf[512];
    std::snprintf(buf, sizeof(buf),
        "{\"primaryViewport\":{\"x\":%.4f,\"y\":%.4f,\"w\":%.4f,\"h\":%.4f},"
        "\"secondaryViewport\":{\"x\":%.4f,\"y\":%.4f,\"w\":%.4f,\"h\":%.4f},"
        "\"secondaryOpacity\":%.4f}",
        result.primaryViewport.x,   result.primaryViewport.y,
        result.primaryViewport.width, result.primaryViewport.height,
        result.secondaryViewport.x,  result.secondaryViewport.y,
        result.secondaryViewport.width, result.secondaryViewport.height,
        result.secondaryOpacity);

    return env->NewStringUTF(buf);
}

// ---------------------------------------------------------------------------
// nativeDestroyDualCamSession
// ---------------------------------------------------------------------------
JNIEXPORT void JNICALL
Java_com_connects_vanguard_1media_1engine_bridge_VanguardNativeBridge_nativeDestroyDualCamSession(
    JNIEnv* /*env*/, jclass /*cls*/,
    jlong sessionHandle)
{
    if (sessionHandle == 0L) {
        VGLOG_W("nativeDestroyDualCamSession: null handle, nothing to do");
        return;
    }
    VGLOG_I("nativeDestroyDualCamSession handle=%lld", static_cast<long long>(sessionHandle));
    auto* session = reinterpret_cast<DualCamSession*>(sessionHandle);
    session->Teardown();
    delete session;
    VGLOG_I("nativeDestroyDualCamSession complete");
}

} // extern "C"

#endif // __ANDROID__
