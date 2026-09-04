// Android Vulkan-first export native seam.
// Native session that renders HardwareBuffer frames directly into a
// MediaCodec encoder input Surface via VulkanBackend. This is the smallest
// production-named foundation for the Vulkan export path; it is not yet
// wired into AndroidTimelineExportSession.
//
// This translation unit is Android-only and must NOT be included in iOS or
// host builds. It is added via the Android-only target_sources block in
// src/CMakeLists.txt.
//
// JNI entry points (matching VanguardNativeBridge.kt declarations):
//   createAndroidTimelineVulkanExportSession         -> jstring
//   renderAndroidTimelineVulkanExportFrame           -> jstring
//   renderAndroidTimelineVulkanExportFrameCropped     -> jstring (crop + rotationDegrees, 0/90/180/270, dest fit rect,
//                                                                  Phase 10: optional 20-element raw colorMatrix;
//                                                                  P5-BEAUTY-V2-PRODUCTION-EXPORT-ROUTE-A: optional
//                                                                  clip-level Beauty V2 intensity, Vulkan-only)
//   renderAndroidTimelineVulkanExportFrameCroppedWithOverlays -> jstring (P5-OVERLAYS-TRANS Route-A N7: same cropped
//                                                                  solo frame as above, plus native-owned overlay
//                                                                  placement/draw seam -- Kotlin passes only texture
//                                                                  handles and already-resolved per-overlay
//                                                                  geometry, never UV/scissor math; no beauty params)
//   renderAndroidTimelineVulkanExportTransitionFrame  -> jstring (P5-COMPOSITOR-TRANS: two imported AHardwareBuffers,
//                                                                  per-layer 9-int geometry + optional colorMatrix,
//                                                                  compositor-owned transition type code + progress)
//   uploadAndroidTimelineVulkanExportOverlayTexture   -> jstring (P5-OVERLAYS-PRODUCTION-EXPORT-ROUTE-A sub-slice N5:
//                                                                  direct RGBA8888 ByteBuffer upload into the
//                                                                  backend-owned overlay texture store)
//   releaseAndroidTimelineVulkanExportOverlayTexture  -> jstring (sub-slice N5: release one overlay texture)
//   clearAndroidTimelineVulkanExportOverlayTextures   -> jstring (sub-slice N5: release every overlay texture)
//   destroyAndroidTimelineVulkanExportSession        -> jstring

#include <jni.h>

#include <android/hardware_buffer.h>
#include <android/native_window_jni.h>
#include <dlfcn.h>
#include <unistd.h>

#include <atomic>
#include <cmath>
#include <condition_variable>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <mutex>
#include <new>
#include <string>
#include <unordered_map>
#include <vector>

#include "vanguard/compositors/vg_timeline_compositor_node.h"
#include "vanguard/render/vulkan_backend.h"
// P5-BEAUTY-V2-PRODUCTION-EXPORT-ROUTE-A: ComputeVulkanBeautyV2ParametersFromIntensity
// expands a clip's beautyIntensity into the full Beauty V2 ramp using the
// CROPPED SOURCE extent (never the output extent), matching the private
// Vulkan render backend's own beauty ramp math exactly (this JNI is already
// Android/Vulkan-specific and already sits on the private Vulkan src include
// path, see target_include_directories(vanguard_media_engine PRIVATE
// "render/vulkan/src") in src/CMakeLists.txt).
#include "vulkan_beauty_v2_compositor.h"
// P5-OVERLAYS-TRANS Route-A N7: VulkanOverlayFrameDraw (already-resolved
// overlay draw) plus the pure placement/validation helpers
// (ValidateVulkanOverlayLayerDescriptor / ComputeVulkanOverlayPlacement /
// VulkanOverlayLayerDescriptor). Same private Vulkan src include path as
// vulkan_beauty_v2_compositor.h above.
#include "vulkan_overlay_compositor.h"
#include "vulkan_overlay_frame_renderer.h"

// ---------------------------------------------------------------------------
// AHardwareBuffer_fromHardwareBuffer dynamic lookup
// ---------------------------------------------------------------------------
namespace {

using FnAHardwareBuffer_fromHardwareBuffer =
    AHardwareBuffer* (*)(JNIEnv*, jobject);

AHardwareBuffer* ResolveAHardwareBufferFromJObject(JNIEnv* env, jobject jHwBuf) {
    void* lib = dlopen("libandroid.so", RTLD_NOW | RTLD_LOCAL);
    if (!lib) return nullptr;
    auto fn = reinterpret_cast<FnAHardwareBuffer_fromHardwareBuffer>(
        dlsym(lib, "AHardwareBuffer_fromHardwareBuffer"));
    AHardwareBuffer* buf = nullptr;
    if (fn && jHwBuf) {
        buf = fn(env, jHwBuf);
    }
    dlclose(lib);
    return buf;
}

// ---------------------------------------------------------------------------
// Vulkan export session structure
// ---------------------------------------------------------------------------

struct VulkanExportSession {
    ANativeWindow*                  nativeWindow{nullptr};
    vanguard::render::VulkanBackend backend;
    bool                            initialized{false};
    bool                            surfaceAttached{false};
    int32_t                         width{0};
    int32_t                         height{0};
    int                             renderedFrames{0};
    std::string                     sessionId;
    // Number of in-flight backend operations currently using this
    // session's backend: render/transition frame calls and overlay
    // texture upload/release/clear calls. Guarded by
    // gVulkanExportSessionMutex. destroy() waits for this to reach zero
    // (after removing the session from the registry) before touching the
    // backend or freeing the session.
    int                             activeRenderCount{0};
    // Serializes every call into `backend` (the render/transition routes
    // and the overlay texture upload/release/clear routes below), since
    // VulkanBackend performs no internal synchronization of its own and
    // requires callers to serialize all backend use against each other.
    // Disjoint from gVulkanExportSessionMutex, which only guards registry
    // lookup/erase and activeRenderCount bookkeeping: the two are never
    // held at the same time.
    std::mutex                      backendLaneMutex;
};

// ---------------------------------------------------------------------------
// Session registry (guarded by mutex)
// ---------------------------------------------------------------------------
//
// Lifetime safety: every backend-operation entry point (the render and
// transition frame routes, and the overlay texture upload/release/clear
// routes) and destroyAndroidTimelineVulkanExportSession all serialize
// their registry lookup/erase and activeRenderCount bookkeeping on
// gVulkanExportSessionMutex. destroy() erases the session from the map
// before waiting for activeRenderCount to drain, so no new backend
// operation can observe a closing session, and no in-flight backend
// operation can still be touching the backend once destroy proceeds to
// detach/shutdown/release/delete. Neither side ever calls into
// VulkanBackend while holding gVulkanExportSessionMutex.

std::mutex                                            gVulkanExportSessionMutex;
std::condition_variable                               gVulkanExportSessionIdleCv;
std::unordered_map<std::string, VulkanExportSession*> gVulkanExportSessions;
std::atomic<uint64_t>                                 gNextVulkanExportSessionId{1};

const char* HwBufResultName(vanguard::render::HardwareBufferImportResult r) {
    using R = vanguard::render::HardwareBufferImportResult;
    switch (r) {
        case R::kSuccess:                     return "success";
        case R::kUnavailable:                 return "unavailable";
        case R::kBackendNotInitialized:       return "backend_not_initialized";
        case R::kInvalidArgument:             return "invalid_argument";
        case R::kDuplicateImport:             return "duplicate_import";
        case R::kIncompatibleBuffer:          return "incompatible_buffer";
        case R::kVulkanFunctionUnavailable:   return "vulkan_function_unavailable";
        case R::kVulkanFailure:               return "vulkan_failure";
        case R::kUnknownHandle:               return "unknown_handle";
    }
    return "unknown";
}

const char* RenderResultName(vanguard::render::RenderFrameResult r) {
    using R = vanguard::render::RenderFrameResult;
    switch (r) {
        case R::kSuccess:                return "success";
        case R::kSuboptimal:             return "suboptimal";
        case R::kBackendNotInitialized:  return "backend_not_initialized";
        case R::kNoSurface:              return "no_surface";
        case R::kInvalidBufferHandle:    return "invalid_buffer_handle";
        case R::kOutOfDate:              return "out_of_date";
        case R::kSurfaceLost:            return "surface_lost";
        case R::kDeviceLost:             return "device_lost";
        case R::kVulkanFailure:          return "vulkan_failure";
        case R::kUnavailable:            return "unavailable";
    }
    return "unknown";
}

// ---------------------------------------------------------------------------
// Per-layer render geometry shared by the cropped solo route and the
// transition route: decoder crop rect, cardinal rotation, and the
// aspect-fit destination rect inside the session's output surface.
// ---------------------------------------------------------------------------

struct LayerGeometryArgs {
    int32_t cropLeft = 0;
    int32_t cropTop = 0;
    int32_t cropRight = 0;
    int32_t cropBottom = 0;
    int32_t rotationDegrees = 0;
    int32_t destFitX = 0;
    int32_t destFitY = 0;
    int32_t destFitWidth = 0;
    int32_t destFitHeight = 0;
};

// Wire layout of the Kotlin IntArray(9) for one transition layer.
constexpr jsize kLayerGeometryLength = 9;

// P5-OVERLAYS-TRANS Route-A N7: wire layout of the Kotlin DoubleArray for one
// overlay in renderAndroidTimelineVulkanExportFrameCroppedWithOverlays's
// overlayGeometry -- x, y, width, height, rotationRadians, scale, opacity --
// and the bounded max overlay count per call.
constexpr jsize kOverlayGeometryLength = 7;
constexpr jint kMaxOverlayCount = 128;

// Non-dispatchable Vulkan handles are exactly 8 bytes on every ABI Vulkan
// supports (a pointer on LP64/64-bit targets, a plain uint64_t otherwise), so
// a byte-for-byte memcpy round-trips through uint64_t on either ABI, matching
// VulkanOverlayTextureInfo::imageViewHandle/samplerHandle and
// vulkan_overlay_frame_renderer.cpp's own ToImageView/ToSampler helpers.
static_assert(sizeof(VkImageView) == sizeof(uint64_t),
             "VkImageView must be 8 bytes to round-trip through uint64_t");
static_assert(sizeof(VkSampler) == sizeof(uint64_t),
             "VkSampler must be 8 bytes to round-trip through uint64_t");

VkImageView ToImageView(uint64_t handle) {
    VkImageView view = VK_NULL_HANDLE;
    std::memcpy(&view, &handle, sizeof(view));
    return view;
}

VkSampler ToSampler(uint64_t handle) {
    VkSampler sampler = VK_NULL_HANDLE;
    std::memcpy(&sampler, &handle, sizeof(sampler));
    return sampler;
}

bool ReadLayerGeometry(JNIEnv* env, jintArray arr, LayerGeometryArgs* out, jsize* outLen) {
    *outLen = arr ? env->GetArrayLength(arr) : -1;
    if (!arr || *outLen != kLayerGeometryLength) return false;
    jint values[kLayerGeometryLength];
    env->GetIntArrayRegion(arr, 0, kLayerGeometryLength, values);
    out->cropLeft = values[0];
    out->cropTop = values[1];
    out->cropRight = values[2];
    out->cropBottom = values[3];
    out->rotationDegrees = values[4];
    out->destFitX = values[5];
    out->destFitY = values[6];
    out->destFitWidth = values[7];
    out->destFitHeight = values[8];
    return true;
}

// Returns nullptr when the geometry is structurally valid for a width x
// height output, else a machine-readable reason token.
const char* ValidateLayerGeometry(const LayerGeometryArgs& g, int32_t width, int32_t height) {
    if (g.cropLeft < 0 || g.cropTop < 0 || g.cropRight <= g.cropLeft || g.cropBottom <= g.cropTop) {
        return "invalid_crop";
    }
    if (g.rotationDegrees != 0 && g.rotationDegrees != 90 &&
        g.rotationDegrees != 180 && g.rotationDegrees != 270) {
        return "vulkan_rotation_unsupported";
    }
    if (g.destFitWidth <= 0 || g.destFitHeight <= 0 || g.destFitX < 0 || g.destFitY < 0 ||
        (static_cast<int64_t>(g.destFitX) + g.destFitWidth) > width ||
        (static_cast<int64_t>(g.destFitY) + g.destFitHeight) > height) {
        return "vulkan_dest_fit_rect_invalid";
    }
    return nullptr;
}

bool CropWithinDescriptor(const LayerGeometryArgs& g,
                          const vanguard::render::HardwareBufferDescriptor& d) {
    return d.width > 0 && d.height > 0 &&
           static_cast<uint32_t>(g.cropRight) <= d.width &&
           static_cast<uint32_t>(g.cropBottom) <= d.height;
}

// Builds the render transform for one layer against its *imported*
// descriptor (the authoritative, possibly padded buffer geometry). The four
// raw color-matrix offsets (indices 4, 9, 14, 19) are normalized by /255.0
// exactly once here, matching the GLES backend's uColorMatrixOffset upload.
void ApplyLayerTransform(const LayerGeometryArgs& g,
                         const vanguard::render::HardwareBufferDescriptor& d,
                         const float* colorMatrix /* nullable, 20 raw values */,
                         vanguard::render::VideoFrameTransform* out) {
    out->rotationDegrees = static_cast<uint32_t>(g.rotationDegrees);
    out->cropScaleU = static_cast<float>(g.cropRight - g.cropLeft) / static_cast<float>(d.width);
    out->cropScaleV = static_cast<float>(g.cropBottom - g.cropTop) / static_cast<float>(d.height);
    out->cropBiasU = static_cast<float>(g.cropLeft) / static_cast<float>(d.width);
    out->cropBiasV = static_cast<float>(g.cropTop) / static_cast<float>(d.height);
    out->destinationRect.x = g.destFitX;
    out->destinationRect.y = g.destFitY;
    out->destinationRect.width = g.destFitWidth;
    out->destinationRect.height = g.destFitHeight;
    if (colorMatrix != nullptr) {
        out->colorMatrixEnabled = true;
        out->colorMatrixRow0[0] = colorMatrix[0];
        out->colorMatrixRow0[1] = colorMatrix[1];
        out->colorMatrixRow0[2] = colorMatrix[2];
        out->colorMatrixRow0[3] = colorMatrix[3];
        out->colorMatrixRow1[0] = colorMatrix[5];
        out->colorMatrixRow1[1] = colorMatrix[6];
        out->colorMatrixRow1[2] = colorMatrix[7];
        out->colorMatrixRow1[3] = colorMatrix[8];
        out->colorMatrixRow2[0] = colorMatrix[10];
        out->colorMatrixRow2[1] = colorMatrix[11];
        out->colorMatrixRow2[2] = colorMatrix[12];
        out->colorMatrixRow2[3] = colorMatrix[13];
        out->colorMatrixRow3[0] = colorMatrix[15];
        out->colorMatrixRow3[1] = colorMatrix[16];
        out->colorMatrixRow3[2] = colorMatrix[17];
        out->colorMatrixRow3[3] = colorMatrix[18];
        out->colorMatrixOffset[0] = colorMatrix[4] / 255.0f;
        out->colorMatrixOffset[1] = colorMatrix[9] / 255.0f;
        out->colorMatrixOffset[2] = colorMatrix[14] / 255.0f;
        out->colorMatrixOffset[3] = colorMatrix[19] / 255.0f;
    }
}

// Reads an optional 20-element raw colorMatrix. Returns false only when a
// non-null array has the wrong length ([outLen] then carries that length).
bool ReadOptionalColorMatrix(JNIEnv* env, jfloatArray arr, float* out20, bool* outHas, jsize* outLen) {
    *outHas = false;
    *outLen = 0;
    if (arr == nullptr) return true;
    *outLen = env->GetArrayLength(arr);
    if (*outLen != 20) return false;
    env->GetFloatArrayRegion(arr, 0, 20, out20);
    *outHas = true;
    return true;
}

// Kotlin AndroidTimelineTransitionDescriptor.Type.nativeCode wire codes.
// 0 (hard cut) is deliberately rejected: hard cuts never reach this route.
bool TransitionTypeFromCode(jint code,
                            vanguard::compositors::TransitionType* outType,
                            const char** outName) {
    using T = vanguard::compositors::TransitionType;
    switch (code) {
        case 1: *outType = T::kCrossfade;  *outName = "crossfade";  return true;
        case 2: *outType = T::kWipeLeft;   *outName = "wipeLeft";   return true;
        case 3: *outType = T::kWipeRight;  *outName = "wipeRight";  return true;
        case 4: *outType = T::kWipeUp;     *outName = "wipeUp";     return true;
        case 5: *outType = T::kWipeDown;   *outName = "wipeDown";   return true;
        case 6: *outType = T::kSlideLeft;  *outName = "slideLeft";  return true;
        case 7: *outType = T::kSlideRight; *outName = "slideRight"; return true;
        case 8: *outType = T::kSlideUp;    *outName = "slideUp";    return true;
        case 9: *outType = T::kSlideDown;  *outName = "slideDown";  return true;
        default: *outName = "unknown"; return false;
    }
}

vanguard::render::RenderNormalizedRect ToRenderRect(
    const vanguard::compositors::TimelineNormalizedRect& r) {
    vanguard::render::RenderNormalizedRect out;
    out.x = r.x;
    out.y = r.y;
    out.width = r.width;
    out.height = r.height;
    return out;
}

} // namespace

// ---------------------------------------------------------------------------
// JNI: createAndroidTimelineVulkanExportSession
// ---------------------------------------------------------------------------
extern "C" JNIEXPORT jstring JNICALL
Java_com_connects_vanguard_1media_1engine_bridge_VanguardNativeBridge_createAndroidTimelineVulkanExportSession(
    JNIEnv*  env,
    jobject  /* this */,
    jobject  surface,
    jint     width,
    jint     height) {

    char status[512];

    if (!surface || width <= 0 || height <= 0) {
        std::snprintf(status, sizeof(status),
            "status=FAIL;reason=invalid_args;sessionId=none");
        return env->NewStringUTF(status);
    }

    ANativeWindow* nw = ANativeWindow_fromSurface(env, surface);
    if (!nw) {
        std::snprintf(status, sizeof(status),
            "status=FAIL;reason=native_window_failed;sessionId=none");
        return env->NewStringUTF(status);
    }

    auto* session = new VulkanExportSession();
    session->nativeWindow = nw;
    session->width        = width;
    session->height       = height;

    uint64_t sid = gNextVulkanExportSessionId.fetch_add(1, std::memory_order_relaxed);
    char sidBuf[32];
    std::snprintf(sidBuf, sizeof(sidBuf), "vulkan_export_%llu",
        static_cast<unsigned long long>(sid));
    session->sessionId = sidBuf;

    if (!session->backend.initialize()) {
        ANativeWindow_release(nw);
        delete session;
        std::snprintf(status, sizeof(status),
            "status=FAIL;reason=backend_init_failed;sessionId=none");
        return env->NewStringUTF(status);
    }
    session->initialized = true;

    if (!session->backend.attachSurface(
            nw,
            static_cast<uint32_t>(width),
            static_cast<uint32_t>(height))) {
        session->backend.shutdown();
        ANativeWindow_release(nw);
        delete session;
        std::snprintf(status, sizeof(status),
            "status=FAIL;reason=surface_attach_failed;sessionId=none");
        return env->NewStringUTF(status);
    }
    session->surfaceAttached = true;

    {
        std::lock_guard<std::mutex> lock(gVulkanExportSessionMutex);
        gVulkanExportSessions[session->sessionId] = session;
    }

    std::snprintf(status, sizeof(status),
        "status=OK;sessionId=%s;width=%d;height=%d",
        session->sessionId.c_str(), width, height);
    return env->NewStringUTF(status);
}

// ---------------------------------------------------------------------------
// JNI: renderAndroidTimelineVulkanExportFrame
// ---------------------------------------------------------------------------
extern "C" JNIEXPORT jstring JNICALL
Java_com_connects_vanguard_1media_1engine_bridge_VanguardNativeBridge_renderAndroidTimelineVulkanExportFrame(
    JNIEnv*  env,
    jobject  /* this */,
    jstring  sessionIdJ,
    jobject  hardwareBufferJ,
    jint     width,
    jint     height,
    jlong    timelinePtsUs,
    jint     frameIndex) {

    char status[512];

    if (!sessionIdJ || !hardwareBufferJ || width <= 0 || height <= 0) {
        std::snprintf(status, sizeof(status),
            "status=FAIL;frameIndex=%d;reason=invalid_args",
            static_cast<int>(frameIndex));
        return env->NewStringUTF(status);
    }

    const char* sidCStr = env->GetStringUTFChars(sessionIdJ, nullptr);
    std::string sid(sidCStr ? sidCStr : "");
    if (sidCStr) env->ReleaseStringUTFChars(sessionIdJ, sidCStr);

    VulkanExportSession* session = nullptr;
    {
        // Look up and claim the session atomically under the registry lock
        // so this can never observe a session that destroy() is about to
        // erase-and-delete: either the lookup happens before the erase
        // (and the render count is incremented before destroy can proceed
        // past its own erase+wait), or it happens after (and simply finds
        // nothing).
        std::lock_guard<std::mutex> lock(gVulkanExportSessionMutex);
        auto it = gVulkanExportSessions.find(sid);
        if (it != gVulkanExportSessions.end()) {
            session = it->second;
            session->activeRenderCount++;
        }
    }

    if (!session) {
        std::snprintf(status, sizeof(status),
            "status=FAIL;frameIndex=%d;reason=session_not_found;sessionId=%s",
            static_cast<int>(frameIndex), sid.c_str());
        return env->NewStringUTF(status);
    }

    // Releases the claim (and wakes a waiting destroy call) on every exit
    // path below, including early returns.
    struct ReleaseGuard {
        VulkanExportSession* s;
        ~ReleaseGuard() {
            std::lock_guard<std::mutex> lock(gVulkanExportSessionMutex);
            if (--s->activeRenderCount == 0) {
                gVulkanExportSessionIdleCv.notify_all();
            }
        }
    } releaseGuard{session};

    if (!session->initialized || !session->surfaceAttached) {
        std::snprintf(status, sizeof(status),
            "status=FAIL;frameIndex=%d;reason=session_not_ready",
            static_cast<int>(frameIndex));
        return env->NewStringUTF(status);
    }

    AHardwareBuffer* ahwb = ResolveAHardwareBufferFromJObject(env, hardwareBufferJ);
    if (!ahwb) {
        std::snprintf(status, sizeof(status),
            "status=FAIL;frameIndex=%d;reason=ahardwarebuffer_resolve_failed",
            static_cast<int>(frameIndex));
        return env->NewStringUTF(status);
    }

    vanguard::render::HardwareBufferHandle handle =
        vanguard::render::kInvalidHardwareBufferHandle;
    vanguard::render::HardwareBufferDescriptor descriptor{};
    vanguard::render::HardwareBufferImportResult importResult =
        vanguard::render::HardwareBufferImportResult::kUnknownHandle;
    vanguard::render::RenderFrameResult renderResult =
        vanguard::render::RenderFrameResult::kInvalidBufferHandle;
    bool renderOk = false;
    vanguard::render::HardwareBufferImportResult releaseResult =
        vanguard::render::HardwareBufferImportResult::kUnknownHandle;
    {
        // One uninterrupted critical section: import, render, and release
        // all happen while holding backendLaneMutex so no other call can
        // interleave its own backend use with this frame's.
        std::lock_guard<std::mutex> lane(session->backendLaneMutex);
        importResult = session->backend.importHardwareBuffer(
            ahwb, -1, &handle, &descriptor);
        if (importResult == vanguard::render::HardwareBufferImportResult::kSuccess) {
            renderResult = session->backend.renderFrame(handle);
            renderOk =
                renderResult == vanguard::render::RenderFrameResult::kSuccess ||
                renderResult == vanguard::render::RenderFrameResult::kSuboptimal;

            int releaseFenceFd = -1;
            releaseResult =
                session->backend.releaseHardwareBuffer(handle, &releaseFenceFd);
            if (releaseFenceFd >= 0) {
                ::close(releaseFenceFd);
                releaseFenceFd = -1;
            }
        }
    }

    if (importResult != vanguard::render::HardwareBufferImportResult::kSuccess) {
        std::snprintf(status, sizeof(status),
            "status=FAIL;frameIndex=%d;reason=import_failed;importResult=%s",
            static_cast<int>(frameIndex),
            HwBufResultName(importResult));
        return env->NewStringUTF(status);
    }

    if (!renderOk) {
        std::snprintf(status, sizeof(status),
            "status=FAIL;frameIndex=%d;reason=render_failed;renderResult=%s",
            static_cast<int>(frameIndex),
            RenderResultName(renderResult));
        return env->NewStringUTF(status);
    }

    const bool releaseOk =
        releaseResult == vanguard::render::HardwareBufferImportResult::kSuccess;

    if (!releaseOk) {
        std::snprintf(status, sizeof(status),
            "status=FAIL;frameIndex=%d;reason=release_failed;releaseResult=%s",
            static_cast<int>(frameIndex),
            HwBufResultName(releaseResult));
        return env->NewStringUTF(status);
    }

    session->renderedFrames++;

    std::snprintf(status, sizeof(status),
        "status=OK;frameIndex=%d;timelinePtsUs=%lld;renderedFrames=%d;"
        "renderResult=%s;releaseResult=%s",
        static_cast<int>(frameIndex),
        static_cast<long long>(timelinePtsUs),
        session->renderedFrames,
        RenderResultName(renderResult),
        HwBufResultName(releaseResult));
    return env->NewStringUTF(status);
}

// ---------------------------------------------------------------------------
// JNI: renderAndroidTimelineVulkanExportFrameCropped
// ---------------------------------------------------------------------------
// Renders an aspect-preserving-fit destination sub-rect
// ([destFitX],[destFitY])-([destFitX]+[destFitWidth],[destFitY]+[destFitHeight])
// of the [width]x[height] output surface, sourced from the crop rect
// ([cropLeft],[cropTop])-([cropRight],[cropBottom]) of [hardwareBuffer], which
// may be padded larger than the clip's real decoded source extent.
// [width]/[height] are always the encoder's fixed output geometry and are
// cross-checked against the session's own attached surface extent. The crop
// rect is only validated against the *imported* buffer's own
// HardwareBufferDescriptor (the source of truth for the real, possibly
// padded, buffer geometry) -- there is no longer an output/rotation-derived
// expected crop size, since a clip's decoded source extent may legitimately
// differ from the output extent under aspect-preserving fit/scaling. The
// destination rect is validated to be non-empty and to lie fully within the
// [width]x[height] output surface; any invalid destination rect fails closed
// with a machine-readable reason before the HardwareBuffer is even resolved.
// [rotationDegrees] must be exactly 0, 90, 180, or 270 -- an invalid value
// fails closed with a distinct reason before the HardwareBuffer is even
// imported.
// [colorMatrix] (Phase 10), when non-null, must be exactly 20 elements (4x5
// row-major, matching Flutter's ColorFilter.matrix / the GLES backend's
// upload convention) -- native validates the length before the HardwareBuffer
// is even resolved and fails closed with "vulkan_color_matrix_invalid:len=N"
// on any other length. A null colorMatrix renders with the identity color
// matrix (no filter). The four additive offset entries (indices 4, 9, 14, 19)
// are raw (un-normalized) on the wire; native normalizes them by /255.0
// exactly once when building the render transform, matching the GLES
// backend's uColorMatrixOffset upload.
// [beautyEnabled]/[beautyIntensity] (P5-BEAUTY-V2-PRODUCTION-EXPORT-ROUTE-A):
// when [beautyEnabled], [beautyIntensity] must be finite and in [0.0, 1.0]
// -- native fails closed with "beauty_v2_invalid_intensity" before the
// HardwareBuffer is even resolved on any other value (Kotlin already
// validates this before the call; this is defense-in-depth). When enabled,
// native expands the intensity into the full Beauty V2 ramp via
// ComputeVulkanBeautyV2ParametersFromIntensity using the CROPPED SOURCE
// extent (cropRight-cropLeft) x (cropBottom-cropTop), never the output
// extent, and renders through VulkanBackend::renderFrame's beauty-aware
// overload (VulkanBeautyFrameRenderer). A render failure while
// [beautyEnabled] is reported with reason
// "beauty_v2_requires_vulkan:vulkan_render_failed" instead of the generic
// "render_failed" so callers can distinguish a beauty-specific failure.
extern "C" JNIEXPORT jstring JNICALL
Java_com_connects_vanguard_1media_1engine_bridge_VanguardNativeBridge_renderAndroidTimelineVulkanExportFrameCropped(
    JNIEnv*  env,
    jobject  /* this */,
    jstring  sessionIdJ,
    jobject  hardwareBufferJ,
    jint     width,
    jint     height,
    jint     cropLeft,
    jint     cropTop,
    jint     cropRight,
    jint     cropBottom,
    jint     rotationDegrees,
    jint     destFitX,
    jint     destFitY,
    jint     destFitWidth,
    jint     destFitHeight,
    jlong    timelinePtsUs,
    jint     frameIndex,
    jfloatArray colorMatrix,
    jboolean beautyEnabled,
    jfloat   beautyIntensity) {

    char status[512];

    if (!sessionIdJ || !hardwareBufferJ || width <= 0 || height <= 0 ||
        cropLeft < 0 || cropTop < 0 || cropRight <= cropLeft || cropBottom <= cropTop) {
        std::snprintf(status, sizeof(status),
            "status=FAIL;frameIndex=%d;reason=invalid_crop:invalid_args",
            static_cast<int>(frameIndex));
        return env->NewStringUTF(status);
    }

    // P5-BEAUTY-V2-PRODUCTION-EXPORT-ROUTE-A: beautyIntensity, when present,
    // must be finite and in [0.0, 1.0]. The Kotlin parser already fails
    // closed (INVALID_ARG) on malformed values before this native call is
    // ever made; this is defense-in-depth, matching the colorMatrix length
    // check below.
    const bool hasBeauty = beautyEnabled == JNI_TRUE;
    if (hasBeauty &&
        (!std::isfinite(beautyIntensity) || beautyIntensity < 0.0f || beautyIntensity > 1.0f)) {
        std::snprintf(status, sizeof(status),
            "status=FAIL;frameIndex=%d;reason=beauty_v2_invalid_intensity",
            static_cast<int>(frameIndex));
        return env->NewStringUTF(status);
    }

    if (rotationDegrees != 0 && rotationDegrees != 90 &&
        rotationDegrees != 180 && rotationDegrees != 270) {
        std::snprintf(status, sizeof(status),
            "status=FAIL;frameIndex=%d;reason=vulkan_rotation_unsupported:%d",
            static_cast<int>(frameIndex), static_cast<int>(rotationDegrees));
        return env->NewStringUTF(status);
    }

    // Destination fit rect must be non-empty and lie fully within the
    // session's [width]x[height] output surface. Validated before the
    // session lookup / buffer import so an invalid destination never reaches
    // render.
    if (destFitWidth <= 0 || destFitHeight <= 0 || destFitX < 0 || destFitY < 0 ||
        (static_cast<int64_t>(destFitX) + destFitWidth) > width ||
        (static_cast<int64_t>(destFitY) + destFitHeight) > height) {
        std::snprintf(status, sizeof(status),
            "status=FAIL;frameIndex=%d;reason=vulkan_dest_fit_rect_invalid:"
            "destFit=%d,%d-%dx%d:outW=%d:outH=%d",
            static_cast<int>(frameIndex),
            static_cast<int>(destFitX), static_cast<int>(destFitY),
            static_cast<int>(destFitWidth), static_cast<int>(destFitHeight),
            static_cast<int>(width), static_cast<int>(height));
        return env->NewStringUTF(status);
    }

    // Phase 10: colorMatrix length must be validated before the buffer is
    // even resolved/imported -- this check is independent of the session and
    // buffer, so it fails closed early alongside the other pre-import
    // argument validation above. [colorMatrixValues] is copied out now (while
    // the jfloatArray reference is guaranteed live) for use after import.
    float colorMatrixValues[20];
    bool hasColorMatrix = false;
    if (colorMatrix != nullptr) {
        const jsize colorMatrixLen = env->GetArrayLength(colorMatrix);
        if (colorMatrixLen != 20) {
            std::snprintf(status, sizeof(status),
                "status=FAIL;frameIndex=%d;reason=vulkan_color_matrix_invalid:len=%d",
                static_cast<int>(frameIndex), static_cast<int>(colorMatrixLen));
            return env->NewStringUTF(status);
        }
        env->GetFloatArrayRegion(colorMatrix, 0, 20, colorMatrixValues);
        hasColorMatrix = true;
    }

    const char* sidCStr = env->GetStringUTFChars(sessionIdJ, nullptr);
    std::string sid(sidCStr ? sidCStr : "");
    if (sidCStr) env->ReleaseStringUTFChars(sessionIdJ, sidCStr);

    VulkanExportSession* session = nullptr;
    {
        // See renderAndroidTimelineVulkanExportFrame above for the claim/
        // erase-and-wait lifetime argument; this route follows the same
        // registry protocol.
        std::lock_guard<std::mutex> lock(gVulkanExportSessionMutex);
        auto it = gVulkanExportSessions.find(sid);
        if (it != gVulkanExportSessions.end()) {
            session = it->second;
            session->activeRenderCount++;
        }
    }

    if (!session) {
        std::snprintf(status, sizeof(status),
            "status=FAIL;frameIndex=%d;reason=session_not_found;sessionId=%s",
            static_cast<int>(frameIndex), sid.c_str());
        return env->NewStringUTF(status);
    }

    struct ReleaseGuard {
        VulkanExportSession* s;
        ~ReleaseGuard() {
            std::lock_guard<std::mutex> lock(gVulkanExportSessionMutex);
            if (--s->activeRenderCount == 0) {
                gVulkanExportSessionIdleCv.notify_all();
            }
        }
    } releaseGuard{session};

    if (!session->initialized || !session->surfaceAttached) {
        std::snprintf(status, sizeof(status),
            "status=FAIL;frameIndex=%d;reason=session_not_ready",
            static_cast<int>(frameIndex));
        return env->NewStringUTF(status);
    }

    // Cross-check the Kotlin-supplied output extent against the session's
    // own attached surface extent before touching the buffer. There is no
    // longer an output/rotation-derived expected crop size here: the crop
    // extent is validated below against the *imported* buffer's own
    // descriptor instead, since a clip's real decoded source extent may
    // legitimately differ from the output extent under aspect-fit scaling.
    if (width != session->width || height != session->height) {
        std::snprintf(status, sizeof(status),
            "status=FAIL;frameIndex=%d;reason=vulkan_output_geometry_mismatch:"
            "sessionW=%d:sessionH=%d:outW=%d:outH=%d",
            static_cast<int>(frameIndex), session->width, session->height,
            static_cast<int>(width), static_cast<int>(height));
        return env->NewStringUTF(status);
    }

    AHardwareBuffer* ahwb = ResolveAHardwareBufferFromJObject(env, hardwareBufferJ);
    if (!ahwb) {
        std::snprintf(status, sizeof(status),
            "status=FAIL;frameIndex=%d;reason=ahardwarebuffer_resolve_failed",
            static_cast<int>(frameIndex));
        return env->NewStringUTF(status);
    }

    vanguard::render::HardwareBufferHandle handle =
        vanguard::render::kInvalidHardwareBufferHandle;
    vanguard::render::HardwareBufferDescriptor descriptor{};
    vanguard::render::HardwareBufferImportResult importResult =
        vanguard::render::HardwareBufferImportResult::kUnknownHandle;
    bool cropWithinBuffer = false;
    vanguard::render::RenderFrameResult renderResult =
        vanguard::render::RenderFrameResult::kInvalidBufferHandle;
    bool renderOk = false;
    // P5-BEAUTY-V2-PRODUCTION-EXPORT-ROUTE-A: overrides the generic
    // "render_failed" reason below with a machine-readable beauty_v2_*
    // token when the failure occurred for a beauty-enabled render.
    const char* renderFailureReason = "render_failed";
    vanguard::render::HardwareBufferImportResult releaseResult =
        vanguard::render::HardwareBufferImportResult::kUnknownHandle;

    {
        // One uninterrupted critical section: import, the conditional
        // render, and the (always-attempted-on-import-success) release all
        // happen while holding backendLaneMutex so no other call can
        // interleave its own backend use with this frame's.
        std::lock_guard<std::mutex> lane(session->backendLaneMutex);
        importResult = session->backend.importHardwareBuffer(
            ahwb, -1, &handle, &descriptor);

        if (importResult == vanguard::render::HardwareBufferImportResult::kSuccess) {
            // Normalize the crop against the *imported* descriptor -- the
            // authoritative source of truth for the real (possibly padded)
            // buffer geometry, per Opus P0. Any failure past this point
            // still releases the successfully imported buffer below.
            cropWithinBuffer =
                descriptor.width > 0 && descriptor.height > 0 &&
                static_cast<uint32_t>(cropRight) <= descriptor.width &&
                static_cast<uint32_t>(cropBottom) <= descriptor.height;

            if (cropWithinBuffer) {
                // Phase 10: colorMatrix was already validated (length == 20)
                // before the buffer was imported above; [colorMatrixValues]
                // holds the raw (un-normalized) 4x5 row-major values,
                // normalized once by ApplyLayerTransform (shared with the
                // transition route).
                LayerGeometryArgs geometry;
                geometry.cropLeft = static_cast<int32_t>(cropLeft);
                geometry.cropTop = static_cast<int32_t>(cropTop);
                geometry.cropRight = static_cast<int32_t>(cropRight);
                geometry.cropBottom = static_cast<int32_t>(cropBottom);
                geometry.rotationDegrees = static_cast<int32_t>(rotationDegrees);
                geometry.destFitX = static_cast<int32_t>(destFitX);
                geometry.destFitY = static_cast<int32_t>(destFitY);
                geometry.destFitWidth = static_cast<int32_t>(destFitWidth);
                geometry.destFitHeight = static_cast<int32_t>(destFitHeight);
                vanguard::render::VideoFrameTransform transform{};
                ApplyLayerTransform(geometry, descriptor,
                                    hasColorMatrix ? colorMatrixValues : nullptr, &transform);

                // P5-BEAUTY-V2-PRODUCTION-EXPORT-ROUTE-A: expand
                // beautyIntensity into the full Beauty V2 ramp using the
                // CROPPED SOURCE extent (never the output extent), matching
                // VideoBeautyV2RenderParams's documented contract. A
                // disabled/absent beautyIntensity leaves beautyParams at its
                // all-default (enabled=false) state, which VulkanBackend
                // treats as byte-identical to the pre-existing non-beauty
                // renderFrame path.
                vanguard::render::VideoBeautyV2RenderParams beautyParams{};
                bool beautyRampOk = true;
                if (hasBeauty) {
                    const uint32_t beautyCropWidth = static_cast<uint32_t>(cropRight - cropLeft);
                    const uint32_t beautyCropHeight = static_cast<uint32_t>(cropBottom - cropTop);
                    vanguard::render::VulkanBeautyV2Parameters vkBeautyParams{};
                    std::string beautyRampErr;
                    beautyRampOk = vanguard::render::ComputeVulkanBeautyV2ParametersFromIntensity(
                        beautyIntensity, beautyCropWidth, beautyCropHeight, &vkBeautyParams, &beautyRampErr);
                    if (beautyRampOk) {
                        beautyParams.enabled = true;
                        beautyParams.radius = vkBeautyParams.radius;
                        beautyParams.sigma = vkBeautyParams.sigma;
                        beautyParams.rangeSigma = vkBeautyParams.rangeSigma;
                        beautyParams.smoothStrength = vkBeautyParams.smoothStrength;
                        beautyParams.sharpenStrength = vkBeautyParams.sharpenStrength;
                        beautyParams.theta = vkBeautyParams.theta;
                        beautyParams.detailDamping = vkBeautyParams.detailDamping;
                        beautyParams.toneStrength = vkBeautyParams.toneStrength;
                        beautyParams.midtoneLift = vkBeautyParams.midtoneLift;
                        beautyParams.cropWidth = beautyCropWidth;
                        beautyParams.cropHeight = beautyCropHeight;
                    }
                }

                if (!beautyRampOk) {
                    // Defensive-only: Kotlin already validated beautyIntensity
                    // in [0,1] and cropWidth/cropHeight are already guaranteed
                    // > 0 by the crop validation above, so
                    // ComputeVulkanBeautyV2ParametersFromIntensity should
                    // never actually fail here. Still fails closed: the
                    // buffer is released below exactly like every other
                    // failure path.
                    renderResult = vanguard::render::RenderFrameResult::kVulkanFailure;
                    renderOk = false;
                    renderFailureReason = "beauty_v2_requires_vulkan:ramp_failed";
                } else {
                    renderResult = session->backend.renderFrame(handle, transform, beautyParams);
                    renderOk =
                        renderResult == vanguard::render::RenderFrameResult::kSuccess ||
                        renderResult == vanguard::render::RenderFrameResult::kSuboptimal;
                    if (!renderOk && hasBeauty) {
                        renderFailureReason = "beauty_v2_requires_vulkan:vulkan_render_failed";
                    }
                }
            }

            int releaseFenceFd = -1;
            releaseResult =
                session->backend.releaseHardwareBuffer(handle, &releaseFenceFd);
            if (releaseFenceFd >= 0) {
                ::close(releaseFenceFd);
                releaseFenceFd = -1;
            }
        }
    }

    if (importResult != vanguard::render::HardwareBufferImportResult::kSuccess) {
        std::snprintf(status, sizeof(status),
            "status=FAIL;frameIndex=%d;reason=import_failed;importResult=%s",
            static_cast<int>(frameIndex),
            HwBufResultName(importResult));
        return env->NewStringUTF(status);
    }

    if (!cropWithinBuffer) {
        std::snprintf(status, sizeof(status),
            "status=FAIL;frameIndex=%d;reason=vulkan_decoder_crop_unsupported:"
            "crop=%d,%d-%d,%d:descW=%u:descH=%u",
            static_cast<int>(frameIndex),
            static_cast<int>(cropLeft), static_cast<int>(cropTop),
            static_cast<int>(cropRight), static_cast<int>(cropBottom),
            descriptor.width, descriptor.height);
        return env->NewStringUTF(status);
    }

    if (!renderOk) {
        std::snprintf(status, sizeof(status),
            "status=FAIL;frameIndex=%d;reason=%s;renderResult=%s",
            static_cast<int>(frameIndex),
            renderFailureReason,
            RenderResultName(renderResult));
        return env->NewStringUTF(status);
    }

    const bool releaseOk =
        releaseResult == vanguard::render::HardwareBufferImportResult::kSuccess;

    if (!releaseOk) {
        std::snprintf(status, sizeof(status),
            "status=FAIL;frameIndex=%d;reason=release_failed;releaseResult=%s",
            static_cast<int>(frameIndex),
            HwBufResultName(releaseResult));
        return env->NewStringUTF(status);
    }

    session->renderedFrames++;

    std::snprintf(status, sizeof(status),
        "status=OK;frameIndex=%d;timelinePtsUs=%lld;renderedFrames=%d;"
        "renderResult=%s;releaseResult=%s;descW=%u;descH=%u;"
        "destFit=%d,%d-%dx%d;colorMatrix=%d;beauty=%d",
        static_cast<int>(frameIndex),
        static_cast<long long>(timelinePtsUs),
        session->renderedFrames,
        RenderResultName(renderResult),
        HwBufResultName(releaseResult),
        descriptor.width, descriptor.height,
        static_cast<int>(destFitX), static_cast<int>(destFitY),
        static_cast<int>(destFitWidth), static_cast<int>(destFitHeight),
        hasColorMatrix ? 1 : 0,
        hasBeauty ? 1 : 0);
    return env->NewStringUTF(status);
}

// ---------------------------------------------------------------------------
// JNI: renderAndroidTimelineVulkanExportFrameCroppedWithOverlays
// ---------------------------------------------------------------------------
// P5-OVERLAYS-TRANS Route-A N7: renders the same aspect-preserving-fit
// cropped solo frame as renderAndroidTimelineVulkanExportFrameCropped above,
// then composites zero or more already-placed overlay layers on top via
// VulkanBackend::renderFrame's overlay overload. Native owns all overlay
// placement math (ValidateVulkanOverlayLayerDescriptor /
// ComputeVulkanOverlayPlacement); Kotlin never computes or passes UV rows or
// scissor rects, and never passes an imageView/sampler handle -- only a
// backend-owned texture handle, resolved here via
// VulkanBackend::getOverlayTextureInfo. No beauty params on this route:
// overlays + beauty stays unreachable until a later export-wiring slice
// deliberately combines them.
//
// [overlayTextureHandles] is a LongArray of [overlayCount] handles
// previously returned by uploadAndroidTimelineVulkanExportOverlayTexture.
// [overlayGeometry] is a DoubleArray of [overlayCount] * 7 values, 7 per
// overlay in the caller's draw order (already sorted back-to-front by
// zIndex/id): x, y, width, height, rotationRadians, scale, opacity, all in
// output-canvas pixels. Both arrays are ignored (may be null or empty) when
// [overlayCount] == 0; when [overlayCount] > 0 a length mismatch fails
// closed with "invalid_overlay_texture_handles_len" /
// "invalid_overlay_geometry_len" before the session is even looked up. Both
// arrays are copied out with GetLongArrayRegion/GetDoubleArrayRegion (never
// GetPrimitiveArrayCritical).
//
// Inside the same backendLaneMutex critical section as the cropped route
// (import -> crop check -> base transform -> overlays -> render -> release),
// each overlay in order: a non-positive handle fails closed with
// "invalid_overlay_texture_handle:index=N"; an unknown handle
// (getOverlayTextureInfo returns false) fails closed with
// "overlay_texture_unknown:index=N"; a ValidateVulkanOverlayLayerDescriptor
// failure fails closed with "overlay_descriptor_invalid:index=N:reason=<err>";
// a ComputeVulkanOverlayPlacement failure fails closed with
// "overlay_placement_failed:index=N". A validated-but-not-visible overlay
// (placement.visible == false) is silently skipped, not an error. Every
// failure past a successful import still releases the imported
// HardwareBuffer and closes its release fence, exactly like the cropped
// route. The placement canvas is always session->width/height (already
// cross-checked against the Kotlin-supplied width/height above); the render
// call passes exactly the visible draws (visibleOverlayCount <=
// overlayCount) to VulkanBackend::renderFrame(handle, transform, draws,
// visibleCount) -- visibleCount == 0 delegates to the byte-identical
// no-overlay render path.
extern "C" JNIEXPORT jstring JNICALL
Java_com_connects_vanguard_1media_1engine_bridge_VanguardNativeBridge_renderAndroidTimelineVulkanExportFrameCroppedWithOverlays(
    JNIEnv*  env,
    jobject  /* this */,
    jstring  sessionIdJ,
    jobject  hardwareBufferJ,
    jint     width,
    jint     height,
    jint     cropLeft,
    jint     cropTop,
    jint     cropRight,
    jint     cropBottom,
    jint     rotationDegrees,
    jint     destFitX,
    jint     destFitY,
    jint     destFitWidth,
    jint     destFitHeight,
    jlong    timelinePtsUs,
    jint     frameIndex,
    jfloatArray colorMatrix,
    jlongArray overlayTextureHandles,
    jdoubleArray overlayGeometry,
    jint     overlayCount) {

    char status[1024];

    if (!sessionIdJ || !hardwareBufferJ || width <= 0 || height <= 0 ||
        cropLeft < 0 || cropTop < 0 || cropRight <= cropLeft || cropBottom <= cropTop) {
        std::snprintf(status, sizeof(status),
            "status=FAIL;frameIndex=%d;reason=invalid_crop:invalid_args",
            static_cast<int>(frameIndex));
        return env->NewStringUTF(status);
    }

    if (rotationDegrees != 0 && rotationDegrees != 90 &&
        rotationDegrees != 180 && rotationDegrees != 270) {
        std::snprintf(status, sizeof(status),
            "status=FAIL;frameIndex=%d;reason=vulkan_rotation_unsupported:%d",
            static_cast<int>(frameIndex), static_cast<int>(rotationDegrees));
        return env->NewStringUTF(status);
    }

    // Destination fit rect must be non-empty and lie fully within the
    // session's [width]x[height] output surface, validated before the
    // session lookup / buffer import, exactly like the cropped route.
    if (destFitWidth <= 0 || destFitHeight <= 0 || destFitX < 0 || destFitY < 0 ||
        (static_cast<int64_t>(destFitX) + destFitWidth) > width ||
        (static_cast<int64_t>(destFitY) + destFitHeight) > height) {
        std::snprintf(status, sizeof(status),
            "status=FAIL;frameIndex=%d;reason=vulkan_dest_fit_rect_invalid:"
            "destFit=%d,%d-%dx%d:outW=%d:outH=%d",
            static_cast<int>(frameIndex),
            static_cast<int>(destFitX), static_cast<int>(destFitY),
            static_cast<int>(destFitWidth), static_cast<int>(destFitHeight),
            static_cast<int>(width), static_cast<int>(height));
        return env->NewStringUTF(status);
    }

    // colorMatrix length must be validated before the buffer is even
    // resolved/imported, exactly like the cropped route. [colorMatrixValues]
    // is copied out now (while the jfloatArray reference is guaranteed live)
    // for use after import.
    float colorMatrixValues[20];
    bool hasColorMatrix = false;
    if (colorMatrix != nullptr) {
        const jsize colorMatrixLen = env->GetArrayLength(colorMatrix);
        if (colorMatrixLen != 20) {
            std::snprintf(status, sizeof(status),
                "status=FAIL;frameIndex=%d;reason=vulkan_color_matrix_invalid:len=%d",
                static_cast<int>(frameIndex), static_cast<int>(colorMatrixLen));
            return env->NewStringUTF(status);
        }
        env->GetFloatArrayRegion(colorMatrix, 0, 20, colorMatrixValues);
        hasColorMatrix = true;
    }

    if (overlayCount < 0 || overlayCount > kMaxOverlayCount) {
        std::snprintf(status, sizeof(status),
            "status=FAIL;frameIndex=%d;reason=invalid_overlay_count:count=%d",
            static_cast<int>(frameIndex), static_cast<int>(overlayCount));
        return env->NewStringUTF(status);
    }

    // overlayTextureHandles/overlayGeometry are ignored (may be null or
    // empty) when overlayCount == 0; otherwise both are validated for exact
    // length and copied out now (never GetPrimitiveArrayCritical) so they
    // can still be read after the HardwareBuffer is imported below.
    std::vector<jlong> overlayHandles;
    std::vector<jdouble> overlayGeometryValues;
    if (overlayCount > 0) {
        const jsize expectedHandlesLen = static_cast<jsize>(overlayCount);
        const jsize actualHandlesLen =
            overlayTextureHandles ? env->GetArrayLength(overlayTextureHandles) : -1;
        if (actualHandlesLen != expectedHandlesLen) {
            std::snprintf(status, sizeof(status),
                "status=FAIL;frameIndex=%d;reason=invalid_overlay_texture_handles_len:"
                "expected=%d:actual=%d",
                static_cast<int>(frameIndex), static_cast<int>(expectedHandlesLen),
                static_cast<int>(actualHandlesLen));
            return env->NewStringUTF(status);
        }

        const jsize expectedGeometryLen =
            static_cast<jsize>(overlayCount) * kOverlayGeometryLength;
        const jsize actualGeometryLen =
            overlayGeometry ? env->GetArrayLength(overlayGeometry) : -1;
        if (actualGeometryLen != expectedGeometryLen) {
            std::snprintf(status, sizeof(status),
                "status=FAIL;frameIndex=%d;reason=invalid_overlay_geometry_len:"
                "expected=%d:actual=%d",
                static_cast<int>(frameIndex), static_cast<int>(expectedGeometryLen),
                static_cast<int>(actualGeometryLen));
            return env->NewStringUTF(status);
        }

        overlayHandles.resize(static_cast<size_t>(overlayCount));
        env->GetLongArrayRegion(overlayTextureHandles, 0, expectedHandlesLen, overlayHandles.data());
        overlayGeometryValues.resize(static_cast<size_t>(expectedGeometryLen));
        env->GetDoubleArrayRegion(overlayGeometry, 0, expectedGeometryLen, overlayGeometryValues.data());
    }

    // visibleDraws is allocated and fully reserved up front, before the
    // session is even looked up / the buffer imported, so that the
    // post-import critical section below (import -> ... -> release) can
    // never throw std::bad_alloc out from under an already-imported
    // HardwareBuffer. Its capacity is >= overlayCount so the push_back loop
    // in that critical section cannot allocate.
    std::vector<vanguard::render::VulkanOverlayFrameDraw> visibleDraws;
    try {
        visibleDraws.reserve(static_cast<size_t>(overlayCount));
    } catch (const std::bad_alloc&) {
        std::snprintf(status, sizeof(status),
            "status=FAIL;frameIndex=%d;reason=overlay_allocation_failed",
            static_cast<int>(frameIndex));
        return env->NewStringUTF(status);
    }

    const char* sidCStr = env->GetStringUTFChars(sessionIdJ, nullptr);
    std::string sid(sidCStr ? sidCStr : "");
    if (sidCStr) env->ReleaseStringUTFChars(sessionIdJ, sidCStr);

    VulkanExportSession* session = nullptr;
    {
        // See renderAndroidTimelineVulkanExportFrame above for the claim/
        // erase-and-wait lifetime argument; this route follows the same
        // registry protocol.
        std::lock_guard<std::mutex> lock(gVulkanExportSessionMutex);
        auto it = gVulkanExportSessions.find(sid);
        if (it != gVulkanExportSessions.end()) {
            session = it->second;
            session->activeRenderCount++;
        }
    }

    if (!session) {
        std::snprintf(status, sizeof(status),
            "status=FAIL;frameIndex=%d;reason=session_not_found;sessionId=%s",
            static_cast<int>(frameIndex), sid.c_str());
        return env->NewStringUTF(status);
    }

    struct ReleaseGuard {
        VulkanExportSession* s;
        ~ReleaseGuard() {
            std::lock_guard<std::mutex> lock(gVulkanExportSessionMutex);
            if (--s->activeRenderCount == 0) {
                gVulkanExportSessionIdleCv.notify_all();
            }
        }
    } releaseGuard{session};

    if (!session->initialized || !session->surfaceAttached) {
        std::snprintf(status, sizeof(status),
            "status=FAIL;frameIndex=%d;reason=session_not_ready",
            static_cast<int>(frameIndex));
        return env->NewStringUTF(status);
    }

    // Cross-check the Kotlin-supplied output extent against the session's
    // own attached surface extent before touching the buffer, exactly like
    // the cropped route. session->width/height (not [width]/[height]) is
    // used below as the overlay placement canvas extent.
    if (width != session->width || height != session->height) {
        std::snprintf(status, sizeof(status),
            "status=FAIL;frameIndex=%d;reason=vulkan_output_geometry_mismatch:"
            "sessionW=%d:sessionH=%d:outW=%d:outH=%d",
            static_cast<int>(frameIndex), session->width, session->height,
            static_cast<int>(width), static_cast<int>(height));
        return env->NewStringUTF(status);
    }

    AHardwareBuffer* ahwb = ResolveAHardwareBufferFromJObject(env, hardwareBufferJ);
    if (!ahwb) {
        std::snprintf(status, sizeof(status),
            "status=FAIL;frameIndex=%d;reason=ahardwarebuffer_resolve_failed",
            static_cast<int>(frameIndex));
        return env->NewStringUTF(status);
    }

    vanguard::render::HardwareBufferHandle handle =
        vanguard::render::kInvalidHardwareBufferHandle;
    vanguard::render::HardwareBufferDescriptor descriptor{};
    vanguard::render::HardwareBufferImportResult importResult =
        vanguard::render::HardwareBufferImportResult::kUnknownHandle;
    bool cropWithinBuffer = false;
    vanguard::render::RenderFrameResult renderResult =
        vanguard::render::RenderFrameResult::kInvalidBufferHandle;
    bool renderOk = false;
    // Set false on the first invalid overlay; overlayFailureReason then
    // carries the machine-readable token reported to the caller instead of
    // the generic render_failed reason.
    bool overlayOk = true;
    std::string overlayFailureReason;
    uint32_t visibleOverlayCount = 0;
    vanguard::render::HardwareBufferImportResult releaseResult =
        vanguard::render::HardwareBufferImportResult::kUnknownHandle;

    {
        // One uninterrupted critical section: import, the conditional crop
        // check / base transform / overlay resolution+placement / render,
        // and the (always-attempted-on-import-success) release all happen
        // while holding backendLaneMutex so no other call can interleave its
        // own backend use with this frame's. Never holds
        // gVulkanExportSessionMutex at the same time.
        std::lock_guard<std::mutex> lane(session->backendLaneMutex);
        importResult = session->backend.importHardwareBuffer(
            ahwb, -1, &handle, &descriptor);

        if (importResult == vanguard::render::HardwareBufferImportResult::kSuccess) {
            // Normalize the crop against the *imported* descriptor, exactly
            // like the cropped route.
            cropWithinBuffer =
                descriptor.width > 0 && descriptor.height > 0 &&
                static_cast<uint32_t>(cropRight) <= descriptor.width &&
                static_cast<uint32_t>(cropBottom) <= descriptor.height;

            if (cropWithinBuffer) {
                LayerGeometryArgs geometry;
                geometry.cropLeft = static_cast<int32_t>(cropLeft);
                geometry.cropTop = static_cast<int32_t>(cropTop);
                geometry.cropRight = static_cast<int32_t>(cropRight);
                geometry.cropBottom = static_cast<int32_t>(cropBottom);
                geometry.rotationDegrees = static_cast<int32_t>(rotationDegrees);
                geometry.destFitX = static_cast<int32_t>(destFitX);
                geometry.destFitY = static_cast<int32_t>(destFitY);
                geometry.destFitWidth = static_cast<int32_t>(destFitWidth);
                geometry.destFitHeight = static_cast<int32_t>(destFitHeight);
                vanguard::render::VideoFrameTransform transform{};
                ApplyLayerTransform(geometry, descriptor,
                                    hasColorMatrix ? colorMatrixValues : nullptr, &transform);

                const uint32_t canvasWidth = static_cast<uint32_t>(session->width);
                const uint32_t canvasHeight = static_cast<uint32_t>(session->height);

                for (int32_t i = 0; i < overlayCount; ++i) {
                    const int64_t textureHandle =
                        static_cast<int64_t>(overlayHandles[static_cast<size_t>(i)]);
                    if (textureHandle <= 0) {
                        overlayOk = false;
                        overlayFailureReason =
                            "invalid_overlay_texture_handle:index=" + std::to_string(i);
                        break;
                    }

                    // Kotlin is only trusted for the texture handle; the
                    // imageView/sampler used below always come from the
                    // backend's own overlay texture store, never from the
                    // caller.
                    vanguard::render::VulkanOverlayTextureInfo info{};
                    const bool infoOk = session->backend.getOverlayTextureInfo(
                        static_cast<vanguard::render::VulkanOverlayTextureHandle>(textureHandle),
                        &info);
                    if (!infoOk) {
                        overlayOk = false;
                        overlayFailureReason =
                            "overlay_texture_unknown:index=" + std::to_string(i);
                        break;
                    }

                    const size_t base = static_cast<size_t>(i) * kOverlayGeometryLength;
                    vanguard::render::VulkanOverlayLayerDescriptor layer;
                    layer.imageView = ToImageView(info.imageViewHandle);
                    layer.sampler = ToSampler(info.samplerHandle);
                    layer.x = static_cast<double>(overlayGeometryValues[base + 0]);
                    layer.y = static_cast<double>(overlayGeometryValues[base + 1]);
                    layer.width = static_cast<double>(overlayGeometryValues[base + 2]);
                    layer.height = static_cast<double>(overlayGeometryValues[base + 3]);
                    layer.rotation = static_cast<double>(overlayGeometryValues[base + 4]);
                    layer.scale = static_cast<double>(overlayGeometryValues[base + 5]);
                    layer.opacity = static_cast<double>(overlayGeometryValues[base + 6]);
                    layer.zIndex = i;

                    std::string descriptorErr;
                    if (!vanguard::render::ValidateVulkanOverlayLayerDescriptor(
                            layer, canvasWidth, canvasHeight, &descriptorErr)) {
                        overlayOk = false;
                        overlayFailureReason =
                            "overlay_descriptor_invalid:index=" + std::to_string(i) +
                            ":reason=" + descriptorErr;
                        break;
                    }

                    vanguard::render::VulkanOverlayLayerPlacement placement;
                    const bool placedOk = vanguard::render::ComputeVulkanOverlayPlacement(
                        layer, canvasWidth, canvasHeight, &placement);
                    if (!placedOk) {
                        overlayOk = false;
                        overlayFailureReason =
                            "overlay_placement_failed:index=" + std::to_string(i);
                        break;
                    }

                    if (!placement.visible) {
                        continue;
                    }

                    vanguard::render::VulkanOverlayFrameDraw draw;
                    draw.imageViewHandle = info.imageViewHandle;
                    draw.samplerHandle = info.samplerHandle;
                    draw.uvRow0[0] = placement.uvRow0[0];
                    draw.uvRow0[1] = placement.uvRow0[1];
                    draw.uvRow0[2] = placement.uvRow0[2];
                    draw.uvRow0[3] = placement.uvRow0[3];
                    draw.uvRow1[0] = placement.uvRow1[0];
                    draw.uvRow1[1] = placement.uvRow1[1];
                    draw.uvRow1[2] = placement.uvRow1[2];
                    draw.uvRow1[3] = placement.uvRow1[3];
                    draw.scissorX = placement.scissorX;
                    draw.scissorY = placement.scissorY;
                    draw.scissorWidth = placement.scissorWidth;
                    draw.scissorHeight = placement.scissorHeight;
                    draw.opacity = static_cast<float>(layer.opacity);
                    visibleDraws.push_back(draw);
                }

                if (overlayOk) {
                    visibleOverlayCount = static_cast<uint32_t>(visibleDraws.size());
                    renderResult = session->backend.renderFrame(
                        handle, transform,
                        visibleDraws.empty() ? nullptr : visibleDraws.data(),
                        visibleOverlayCount);
                    renderOk =
                        renderResult == vanguard::render::RenderFrameResult::kSuccess ||
                        renderResult == vanguard::render::RenderFrameResult::kSuboptimal;
                }
            }

            int releaseFenceFd = -1;
            releaseResult =
                session->backend.releaseHardwareBuffer(handle, &releaseFenceFd);
            if (releaseFenceFd >= 0) {
                ::close(releaseFenceFd);
                releaseFenceFd = -1;
            }
        }
    }

    if (importResult != vanguard::render::HardwareBufferImportResult::kSuccess) {
        std::snprintf(status, sizeof(status),
            "status=FAIL;frameIndex=%d;reason=import_failed;importResult=%s",
            static_cast<int>(frameIndex),
            HwBufResultName(importResult));
        return env->NewStringUTF(status);
    }

    if (!cropWithinBuffer) {
        std::snprintf(status, sizeof(status),
            "status=FAIL;frameIndex=%d;reason=vulkan_decoder_crop_unsupported:"
            "crop=%d,%d-%d,%d:descW=%u:descH=%u",
            static_cast<int>(frameIndex),
            static_cast<int>(cropLeft), static_cast<int>(cropTop),
            static_cast<int>(cropRight), static_cast<int>(cropBottom),
            descriptor.width, descriptor.height);
        return env->NewStringUTF(status);
    }

    if (!overlayOk) {
        std::snprintf(status, sizeof(status),
            "status=FAIL;frameIndex=%d;reason=%s",
            static_cast<int>(frameIndex), overlayFailureReason.c_str());
        return env->NewStringUTF(status);
    }

    if (!renderOk) {
        std::snprintf(status, sizeof(status),
            "status=FAIL;frameIndex=%d;reason=render_failed;renderResult=%s",
            static_cast<int>(frameIndex),
            RenderResultName(renderResult));
        return env->NewStringUTF(status);
    }

    const bool releaseOk =
        releaseResult == vanguard::render::HardwareBufferImportResult::kSuccess;

    if (!releaseOk) {
        std::snprintf(status, sizeof(status),
            "status=FAIL;frameIndex=%d;reason=release_failed;releaseResult=%s",
            static_cast<int>(frameIndex),
            HwBufResultName(releaseResult));
        return env->NewStringUTF(status);
    }

    session->renderedFrames++;

    std::snprintf(status, sizeof(status),
        "status=OK;frameIndex=%d;timelinePtsUs=%lld;renderedFrames=%d;"
        "renderResult=%s;releaseResult=%s;descW=%u;descH=%u;"
        "destFit=%d,%d-%dx%d;colorMatrix=%d;overlayCount=%d;visibleOverlayCount=%u",
        static_cast<int>(frameIndex),
        static_cast<long long>(timelinePtsUs),
        session->renderedFrames,
        RenderResultName(renderResult),
        HwBufResultName(releaseResult),
        descriptor.width, descriptor.height,
        static_cast<int>(destFitX), static_cast<int>(destFitY),
        static_cast<int>(destFitWidth), static_cast<int>(destFitHeight),
        hasColorMatrix ? 1 : 0,
        static_cast<int>(overlayCount),
        visibleOverlayCount);
    return env->NewStringUTF(status);
}

// ---------------------------------------------------------------------------
// JNI: renderAndroidTimelineVulkanExportTransitionFrame (P5-COMPOSITOR-TRANS)
// ---------------------------------------------------------------------------
// Production compositor-owned clip overlap transition frame: imports the
// outgoing ("from") and incoming ("to") decoder HardwareBuffers into the
// existing production Vulkan export session, evaluates the compositor-owned
// transition geometry (vanguard::compositors::ComputeTransitionGeometry) for
// [transitionTypeCode] at [progress], and renders one output frame through
// VulkanBackend::renderTransitionFrame -- the same swapchain acquire /
// submit / present lifecycle and activeRenderCount registry protocol as the
// solo routes above. Both imports are released on every path after import,
// and both release fence fds are closed here.
//
// [fromLayerGeometry] / [toLayerGeometry] are IntArray(9):
//   [cropLeft, cropTop, cropRight, cropBottom, rotationDegrees,
//    destFitX, destFitY, destFitWidth, destFitHeight]
// validated exactly like the cropped solo route (crop against the imported
// descriptor, cardinal rotation, destination rect inside width x height).
// [fromColorMatrix] / [toColorMatrix] follow the cropped route's optional
// 20-element raw colorMatrix contract. [transitionTypeCode] must be one of
// the non-hard-cut codes accepted by TransitionTypeFromCode; [progress] must
// be finite in [0, 1]. Every failure is reported with a machine-readable
// reason plus transitionType / progress / frameIndex, and success reports
// renderedFrames and both release results.
//
// P5-BEAUTY-V2-TRANSITION-COMP: [fromBeautyEnabled]/[fromBeautyIntensity] and
// [toBeautyEnabled]/[toBeautyIntensity] are optional per-layer Beauty V2
// requests, following the cropped solo route's contract: when enabled, the
// intensity must be finite and in [0.0, 1.0] (fails closed with
// "beauty_v2_invalid_intensity:layer=<from|to>" otherwise, before either
// HardwareBuffer is even resolved). When enabled, native expands the
// intensity into the full Beauty V2 ramp via
// ComputeVulkanBeautyV2ParametersFromIntensity using THAT layer's CROPPED
// SOURCE extent (cropRight-cropLeft) x (cropBottom-cropTop) from the
// validated layer geometry, never the output extent, and renders through
// VulkanBackend::renderTransitionFrame's beauty-aware overload. A render
// failure while either layer is beauty-enabled is reported with reason
// "beauty_v2_requires_vulkan:vulkan_render_failed" instead of the generic
// "render_failed" so callers can distinguish a beauty-specific failure.
extern "C" JNIEXPORT jstring JNICALL
Java_com_connects_vanguard_1media_1engine_bridge_VanguardNativeBridge_renderAndroidTimelineVulkanExportTransitionFrame(
    JNIEnv*     env,
    jobject     /* this */,
    jstring     sessionIdJ,
    jint        width,
    jint        height,
    jint        transitionTypeCode,
    jdouble     progress,
    jobject     fromHardwareBufferJ,
    jintArray   fromLayerGeometryJ,
    jfloatArray fromColorMatrixJ,
    jboolean    fromBeautyEnabled,
    jfloat      fromBeautyIntensity,
    jobject     toHardwareBufferJ,
    jintArray   toLayerGeometryJ,
    jfloatArray toColorMatrixJ,
    jboolean    toBeautyEnabled,
    jfloat      toBeautyIntensity,
    jlong       timelinePtsUs,
    jint        frameIndex) {

    char status[768];
    const char* typeName = "unknown";
    vanguard::compositors::TransitionType type = vanguard::compositors::TransitionType::kNone;
    const double progressValue = static_cast<double>(progress);

    if (!TransitionTypeFromCode(transitionTypeCode, &type, &typeName)) {
        std::snprintf(status, sizeof(status),
            "status=FAIL;reason=transition_type_unsupported:code=%d;transitionType=%s;"
            "progress=%.4f;frameIndex=%d",
            static_cast<int>(transitionTypeCode), typeName, progressValue,
            static_cast<int>(frameIndex));
        return env->NewStringUTF(status);
    }

    if (!sessionIdJ || !fromHardwareBufferJ || !toHardwareBufferJ || width <= 0 || height <= 0) {
        std::snprintf(status, sizeof(status),
            "status=FAIL;reason=invalid_args;transitionType=%s;progress=%.4f;frameIndex=%d",
            typeName, progressValue, static_cast<int>(frameIndex));
        return env->NewStringUTF(status);
    }

    if (!std::isfinite(progressValue) || progressValue < 0.0 || progressValue > 1.0) {
        std::snprintf(status, sizeof(status),
            "status=FAIL;reason=transition_progress_invalid;transitionType=%s;progress=%.4f;"
            "frameIndex=%d",
            typeName, progressValue, static_cast<int>(frameIndex));
        return env->NewStringUTF(status);
    }

    // P5-BEAUTY-V2-TRANSITION-COMP: fromBeautyIntensity/toBeautyIntensity,
    // when enabled, must each be finite and in [0.0, 1.0]. Kotlin already
    // validates this before the call; this is defense-in-depth, matching the
    // cropped solo route's identical check.
    const bool hasFromBeauty = fromBeautyEnabled == JNI_TRUE;
    const bool hasToBeauty = toBeautyEnabled == JNI_TRUE;
    if (hasFromBeauty &&
        (!std::isfinite(fromBeautyIntensity) || fromBeautyIntensity < 0.0f || fromBeautyIntensity > 1.0f)) {
        std::snprintf(status, sizeof(status),
            "status=FAIL;reason=beauty_v2_invalid_intensity:layer=from;transitionType=%s;"
            "progress=%.4f;frameIndex=%d",
            typeName, progressValue, static_cast<int>(frameIndex));
        return env->NewStringUTF(status);
    }
    if (hasToBeauty &&
        (!std::isfinite(toBeautyIntensity) || toBeautyIntensity < 0.0f || toBeautyIntensity > 1.0f)) {
        std::snprintf(status, sizeof(status),
            "status=FAIL;reason=beauty_v2_invalid_intensity:layer=to;transitionType=%s;"
            "progress=%.4f;frameIndex=%d",
            typeName, progressValue, static_cast<int>(frameIndex));
        return env->NewStringUTF(status);
    }

    LayerGeometryArgs fromGeometry;
    LayerGeometryArgs toGeometry;
    jsize geometryLen = 0;
    if (!ReadLayerGeometry(env, fromLayerGeometryJ, &fromGeometry, &geometryLen)) {
        std::snprintf(status, sizeof(status),
            "status=FAIL;reason=layer_geometry_invalid:layer=from:len=%d;transitionType=%s;"
            "progress=%.4f;frameIndex=%d",
            static_cast<int>(geometryLen), typeName, progressValue, static_cast<int>(frameIndex));
        return env->NewStringUTF(status);
    }
    if (!ReadLayerGeometry(env, toLayerGeometryJ, &toGeometry, &geometryLen)) {
        std::snprintf(status, sizeof(status),
            "status=FAIL;reason=layer_geometry_invalid:layer=to:len=%d;transitionType=%s;"
            "progress=%.4f;frameIndex=%d",
            static_cast<int>(geometryLen), typeName, progressValue, static_cast<int>(frameIndex));
        return env->NewStringUTF(status);
    }
    if (const char* reason = ValidateLayerGeometry(fromGeometry, width, height)) {
        std::snprintf(status, sizeof(status),
            "status=FAIL;reason=%s:layer=from;transitionType=%s;progress=%.4f;frameIndex=%d",
            reason, typeName, progressValue, static_cast<int>(frameIndex));
        return env->NewStringUTF(status);
    }
    if (const char* reason = ValidateLayerGeometry(toGeometry, width, height)) {
        std::snprintf(status, sizeof(status),
            "status=FAIL;reason=%s:layer=to;transitionType=%s;progress=%.4f;frameIndex=%d",
            reason, typeName, progressValue, static_cast<int>(frameIndex));
        return env->NewStringUTF(status);
    }

    float fromColorMatrix[20];
    float toColorMatrix[20];
    bool hasFromColorMatrix = false;
    bool hasToColorMatrix = false;
    jsize colorMatrixLen = 0;
    if (!ReadOptionalColorMatrix(env, fromColorMatrixJ, fromColorMatrix, &hasFromColorMatrix, &colorMatrixLen)) {
        std::snprintf(status, sizeof(status),
            "status=FAIL;reason=vulkan_color_matrix_invalid:layer=from:len=%d;transitionType=%s;"
            "progress=%.4f;frameIndex=%d",
            static_cast<int>(colorMatrixLen), typeName, progressValue, static_cast<int>(frameIndex));
        return env->NewStringUTF(status);
    }
    if (!ReadOptionalColorMatrix(env, toColorMatrixJ, toColorMatrix, &hasToColorMatrix, &colorMatrixLen)) {
        std::snprintf(status, sizeof(status),
            "status=FAIL;reason=vulkan_color_matrix_invalid:layer=to:len=%d;transitionType=%s;"
            "progress=%.4f;frameIndex=%d",
            static_cast<int>(colorMatrixLen), typeName, progressValue, static_cast<int>(frameIndex));
        return env->NewStringUTF(status);
    }

    const char* sidCStr = env->GetStringUTFChars(sessionIdJ, nullptr);
    std::string sid(sidCStr ? sidCStr : "");
    if (sidCStr) env->ReleaseStringUTFChars(sessionIdJ, sidCStr);

    VulkanExportSession* session = nullptr;
    {
        // Same claim / erase-and-wait lifetime protocol as the solo routes.
        std::lock_guard<std::mutex> lock(gVulkanExportSessionMutex);
        auto it = gVulkanExportSessions.find(sid);
        if (it != gVulkanExportSessions.end()) {
            session = it->second;
            session->activeRenderCount++;
        }
    }

    if (!session) {
        std::snprintf(status, sizeof(status),
            "status=FAIL;reason=session_not_found;sessionId=%s;transitionType=%s;progress=%.4f;"
            "frameIndex=%d",
            sid.c_str(), typeName, progressValue, static_cast<int>(frameIndex));
        return env->NewStringUTF(status);
    }

    struct ReleaseGuard {
        VulkanExportSession* s;
        ~ReleaseGuard() {
            std::lock_guard<std::mutex> lock(gVulkanExportSessionMutex);
            if (--s->activeRenderCount == 0) {
                gVulkanExportSessionIdleCv.notify_all();
            }
        }
    } releaseGuard{session};

    if (!session->initialized || !session->surfaceAttached) {
        std::snprintf(status, sizeof(status),
            "status=FAIL;reason=session_not_ready;transitionType=%s;progress=%.4f;frameIndex=%d",
            typeName, progressValue, static_cast<int>(frameIndex));
        return env->NewStringUTF(status);
    }

    if (width != session->width || height != session->height) {
        std::snprintf(status, sizeof(status),
            "status=FAIL;reason=vulkan_output_geometry_mismatch:"
            "sessionW=%d:sessionH=%d:outW=%d:outH=%d;transitionType=%s;progress=%.4f;frameIndex=%d",
            session->width, session->height, static_cast<int>(width), static_cast<int>(height),
            typeName, progressValue, static_cast<int>(frameIndex));
        return env->NewStringUTF(status);
    }

    AHardwareBuffer* fromAhwb = ResolveAHardwareBufferFromJObject(env, fromHardwareBufferJ);
    AHardwareBuffer* toAhwb = ResolveAHardwareBufferFromJObject(env, toHardwareBufferJ);
    if (!fromAhwb || !toAhwb) {
        std::snprintf(status, sizeof(status),
            "status=FAIL;reason=ahardwarebuffer_resolve_failed:layer=%s;transitionType=%s;"
            "progress=%.4f;frameIndex=%d",
            fromAhwb ? "to" : "from", typeName, progressValue, static_cast<int>(frameIndex));
        return env->NewStringUTF(status);
    }

    using vanguard::render::HardwareBufferImportResult;
    vanguard::render::HardwareBufferHandle fromHandle = vanguard::render::kInvalidHardwareBufferHandle;
    vanguard::render::HardwareBufferHandle toHandle = vanguard::render::kInvalidHardwareBufferHandle;
    vanguard::render::HardwareBufferDescriptor fromDescriptor{};
    vanguard::render::HardwareBufferDescriptor toDescriptor{};
    HardwareBufferImportResult fromImportResult = HardwareBufferImportResult::kUnknownHandle;
    HardwareBufferImportResult toImportResult = HardwareBufferImportResult::kUnknownHandle;
    bool fromCropOk = false;
    bool toCropOk = false;
    vanguard::render::RenderFrameResult renderResult =
        vanguard::render::RenderFrameResult::kInvalidBufferHandle;
    bool renderOk = false;
    // P5-BEAUTY-V2-TRANSITION-COMP: overrides the generic "render_failed"
    // reason below with a machine-readable beauty_v2_* token when the
    // failure occurred for a beauty-enabled layer.
    const char* renderFailureReason = "render_failed";
    char beautyFailureReasonBuf[96];
    HardwareBufferImportResult fromReleaseResult = HardwareBufferImportResult::kUnknownHandle;
    HardwareBufferImportResult toReleaseResult = HardwareBufferImportResult::kUnknownHandle;

    {
        // One uninterrupted critical section: both imports, the conditional
        // render, and both releases all happen while holding
        // backendLaneMutex so no other call can interleave its own backend
        // use with this transition frame's.
        std::lock_guard<std::mutex> lane(session->backendLaneMutex);

        fromImportResult = session->backend.importHardwareBuffer(
            fromAhwb, -1, &fromHandle, &fromDescriptor);

        if (fromImportResult == HardwareBufferImportResult::kSuccess) {
            toImportResult = session->backend.importHardwareBuffer(
                toAhwb, -1, &toHandle, &toDescriptor);

            if (toImportResult != HardwareBufferImportResult::kSuccess) {
                // Exactly-once release of the already imported "from" layer.
                int fromReleaseFenceFd = -1;
                fromReleaseResult =
                    session->backend.releaseHardwareBuffer(fromHandle, &fromReleaseFenceFd);
                if (fromReleaseFenceFd >= 0) {
                    ::close(fromReleaseFenceFd);
                }
            } else {
                // Both imported: from here every path releases both handles
                // below.
                fromCropOk = CropWithinDescriptor(fromGeometry, fromDescriptor);
                toCropOk = CropWithinDescriptor(toGeometry, toDescriptor);

                if (fromCropOk && toCropOk) {
                    vanguard::render::VideoTransitionFrameTransform transition{};
                    ApplyLayerTransform(fromGeometry, fromDescriptor,
                                        hasFromColorMatrix ? fromColorMatrix : nullptr, &transition.from);
                    ApplyLayerTransform(toGeometry, toDescriptor,
                                        hasToColorMatrix ? toColorMatrix : nullptr, &transition.to);
                    const vanguard::compositors::TimelineTransitionProgress geometry =
                        vanguard::compositors::ComputeTransitionGeometry(type, progressValue);
                    transition.progress = geometry.progress;
                    transition.blendWeightFrom = geometry.blendWeightFrom;
                    transition.blendWeightTo = geometry.blendWeightTo;
                    transition.fromViewport = ToRenderRect(geometry.fromViewport);
                    transition.toViewport = ToRenderRect(geometry.toViewport);
                    transition.fromCrop = ToRenderRect(geometry.fromCrop);
                    transition.toCrop = ToRenderRect(geometry.toCrop);

                    // P5-BEAUTY-V2-TRANSITION-COMP: expand each enabled
                    // layer's beautyIntensity into the full Beauty V2 ramp
                    // using that layer's CROPPED SOURCE extent from the
                    // validated layer geometry (never the output extent),
                    // matching the cropped solo route's contract. A disabled
                    // layer leaves its VideoBeautyV2RenderParams at its
                    // all-default (enabled=false) state.
                    vanguard::render::VideoBeautyV2RenderParams fromBeautyParams{};
                    vanguard::render::VideoBeautyV2RenderParams toBeautyParams{};
                    bool beautyRampOk = true;
                    const char* beautyRampFailLayer = nullptr;
                    if (hasFromBeauty) {
                        const uint32_t cropWidth = static_cast<uint32_t>(fromGeometry.cropRight - fromGeometry.cropLeft);
                        const uint32_t cropHeight = static_cast<uint32_t>(fromGeometry.cropBottom - fromGeometry.cropTop);
                        vanguard::render::VulkanBeautyV2Parameters vkBeautyParams{};
                        std::string beautyRampErr;
                        if (!vanguard::render::ComputeVulkanBeautyV2ParametersFromIntensity(
                                fromBeautyIntensity, cropWidth, cropHeight, &vkBeautyParams, &beautyRampErr)) {
                            beautyRampOk = false;
                            beautyRampFailLayer = "from";
                        } else {
                            fromBeautyParams.enabled = true;
                            fromBeautyParams.radius = vkBeautyParams.radius;
                            fromBeautyParams.sigma = vkBeautyParams.sigma;
                            fromBeautyParams.rangeSigma = vkBeautyParams.rangeSigma;
                            fromBeautyParams.smoothStrength = vkBeautyParams.smoothStrength;
                            fromBeautyParams.sharpenStrength = vkBeautyParams.sharpenStrength;
                            fromBeautyParams.theta = vkBeautyParams.theta;
                            fromBeautyParams.detailDamping = vkBeautyParams.detailDamping;
                            fromBeautyParams.toneStrength = vkBeautyParams.toneStrength;
                            fromBeautyParams.midtoneLift = vkBeautyParams.midtoneLift;
                            fromBeautyParams.cropWidth = cropWidth;
                            fromBeautyParams.cropHeight = cropHeight;
                        }
                    }
                    if (beautyRampOk && hasToBeauty) {
                        const uint32_t cropWidth = static_cast<uint32_t>(toGeometry.cropRight - toGeometry.cropLeft);
                        const uint32_t cropHeight = static_cast<uint32_t>(toGeometry.cropBottom - toGeometry.cropTop);
                        vanguard::render::VulkanBeautyV2Parameters vkBeautyParams{};
                        std::string beautyRampErr;
                        if (!vanguard::render::ComputeVulkanBeautyV2ParametersFromIntensity(
                                toBeautyIntensity, cropWidth, cropHeight, &vkBeautyParams, &beautyRampErr)) {
                            beautyRampOk = false;
                            beautyRampFailLayer = "to";
                        } else {
                            toBeautyParams.enabled = true;
                            toBeautyParams.radius = vkBeautyParams.radius;
                            toBeautyParams.sigma = vkBeautyParams.sigma;
                            toBeautyParams.rangeSigma = vkBeautyParams.rangeSigma;
                            toBeautyParams.smoothStrength = vkBeautyParams.smoothStrength;
                            toBeautyParams.sharpenStrength = vkBeautyParams.sharpenStrength;
                            toBeautyParams.theta = vkBeautyParams.theta;
                            toBeautyParams.detailDamping = vkBeautyParams.detailDamping;
                            toBeautyParams.toneStrength = vkBeautyParams.toneStrength;
                            toBeautyParams.midtoneLift = vkBeautyParams.midtoneLift;
                            toBeautyParams.cropWidth = cropWidth;
                            toBeautyParams.cropHeight = cropHeight;
                        }
                    }

                    if (!beautyRampOk) {
                        // Defensive-only: Kotlin already validated
                        // beautyIntensity in [0,1] and cropWidth/cropHeight
                        // are already guaranteed > 0 by the crop validation
                        // above, so ComputeVulkanBeautyV2ParametersFromIntensity
                        // should never actually fail here. Still fails
                        // closed: both buffers are released below exactly
                        // like every other failure path.
                        renderResult = vanguard::render::RenderFrameResult::kVulkanFailure;
                        renderOk = false;
                        std::snprintf(beautyFailureReasonBuf, sizeof(beautyFailureReasonBuf),
                            "beauty_v2_requires_vulkan:ramp_failed:layer=%s", beautyRampFailLayer);
                        renderFailureReason = beautyFailureReasonBuf;
                    } else {
                        renderResult = session->backend.renderTransitionFrame(
                            fromHandle, toHandle, transition, fromBeautyParams, toBeautyParams);
                        renderOk =
                            renderResult == vanguard::render::RenderFrameResult::kSuccess ||
                            renderResult == vanguard::render::RenderFrameResult::kSuboptimal;
                        if (!renderOk && (hasFromBeauty || hasToBeauty)) {
                            renderFailureReason = "beauty_v2_requires_vulkan:vulkan_render_failed";
                        }
                    }
                }

                int fromReleaseFenceFd = -1;
                fromReleaseResult =
                    session->backend.releaseHardwareBuffer(fromHandle, &fromReleaseFenceFd);
                if (fromReleaseFenceFd >= 0) {
                    ::close(fromReleaseFenceFd);
                    fromReleaseFenceFd = -1;
                }
                int toReleaseFenceFd = -1;
                toReleaseResult =
                    session->backend.releaseHardwareBuffer(toHandle, &toReleaseFenceFd);
                if (toReleaseFenceFd >= 0) {
                    ::close(toReleaseFenceFd);
                    toReleaseFenceFd = -1;
                }
            }
        }
    }

    if (fromImportResult != HardwareBufferImportResult::kSuccess) {
        std::snprintf(status, sizeof(status),
            "status=FAIL;reason=import_failed:layer=from;importResult=%s;transitionType=%s;"
            "progress=%.4f;frameIndex=%d",
            HwBufResultName(fromImportResult), typeName, progressValue, static_cast<int>(frameIndex));
        return env->NewStringUTF(status);
    }

    if (toImportResult != HardwareBufferImportResult::kSuccess) {
        std::snprintf(status, sizeof(status),
            "status=FAIL;reason=import_failed:layer=to;importResult=%s;fromReleaseResult=%s;"
            "transitionType=%s;progress=%.4f;frameIndex=%d",
            HwBufResultName(toImportResult), HwBufResultName(fromReleaseResult),
            typeName, progressValue, static_cast<int>(frameIndex));
        return env->NewStringUTF(status);
    }

    if (!fromCropOk || !toCropOk) {
        const LayerGeometryArgs& g = fromCropOk ? toGeometry : fromGeometry;
        const vanguard::render::HardwareBufferDescriptor& d = fromCropOk ? toDescriptor : fromDescriptor;
        std::snprintf(status, sizeof(status),
            "status=FAIL;reason=vulkan_decoder_crop_unsupported:layer=%s:"
            "crop=%d,%d-%d,%d:descW=%u:descH=%u;fromReleaseResult=%s;toReleaseResult=%s;"
            "transitionType=%s;progress=%.4f;frameIndex=%d",
            fromCropOk ? "to" : "from",
            g.cropLeft, g.cropTop, g.cropRight, g.cropBottom, d.width, d.height,
            HwBufResultName(fromReleaseResult), HwBufResultName(toReleaseResult),
            typeName, progressValue, static_cast<int>(frameIndex));
        return env->NewStringUTF(status);
    }

    if (!renderOk) {
        std::snprintf(status, sizeof(status),
            "status=FAIL;reason=%s;renderResult=%s;fromReleaseResult=%s;"
            "toReleaseResult=%s;transitionType=%s;progress=%.4f;frameIndex=%d",
            renderFailureReason,
            RenderResultName(renderResult),
            HwBufResultName(fromReleaseResult), HwBufResultName(toReleaseResult),
            typeName, progressValue, static_cast<int>(frameIndex));
        return env->NewStringUTF(status);
    }

    if (fromReleaseResult != HardwareBufferImportResult::kSuccess ||
        toReleaseResult != HardwareBufferImportResult::kSuccess) {
        std::snprintf(status, sizeof(status),
            "status=FAIL;reason=release_failed;fromReleaseResult=%s;toReleaseResult=%s;"
            "transitionType=%s;progress=%.4f;frameIndex=%d",
            HwBufResultName(fromReleaseResult), HwBufResultName(toReleaseResult),
            typeName, progressValue, static_cast<int>(frameIndex));
        return env->NewStringUTF(status);
    }

    session->renderedFrames++;

    std::snprintf(status, sizeof(status),
        "status=OK;frameIndex=%d;timelinePtsUs=%lld;renderedFrames=%d;transitionType=%s;"
        "progress=%.4f;renderResult=%s;fromReleaseResult=%s;toReleaseResult=%s;"
        "fromDescW=%u;fromDescH=%u;toDescW=%u;toDescH=%u;"
        "fromDestFit=%d,%d-%dx%d;toDestFit=%d,%d-%dx%d;fromColorMatrix=%d;toColorMatrix=%d;"
        "fromBeauty=%d;toBeauty=%d",
        static_cast<int>(frameIndex),
        static_cast<long long>(timelinePtsUs),
        session->renderedFrames,
        typeName,
        progressValue,
        RenderResultName(renderResult),
        HwBufResultName(fromReleaseResult),
        HwBufResultName(toReleaseResult),
        fromDescriptor.width, fromDescriptor.height,
        toDescriptor.width, toDescriptor.height,
        fromGeometry.destFitX, fromGeometry.destFitY, fromGeometry.destFitWidth, fromGeometry.destFitHeight,
        toGeometry.destFitX, toGeometry.destFitY, toGeometry.destFitWidth, toGeometry.destFitHeight,
        hasFromColorMatrix ? 1 : 0, hasToColorMatrix ? 1 : 0,
        hasFromBeauty ? 1 : 0, hasToBeauty ? 1 : 0);
    return env->NewStringUTF(status);
}

// ---------------------------------------------------------------------------
// JNI: uploadAndroidTimelineVulkanExportOverlayTexture
// ---------------------------------------------------------------------------
// P5-OVERLAYS-PRODUCTION-EXPORT-ROUTE-A sub-slice N5: uploads one direct
// RGBA8888 ByteBuffer into the session's backend-owned overlay texture store
// (VulkanBackend::createOverlayTextureRgba8888). [rgbaBuffer] is read from
// byte index 0 for its own direct-buffer capacity -- position/limit are
// ignored; a caller needing an offset must pass a sliced direct buffer.
// [rowStrideBytes] of 0 means tightly packed (width * 4 bytes/row); any
// non-zero value less than width * 4 fails closed with reason=invalid_stride,
// and a buffer too small for rowStrideBytes * height bytes fails closed with
// reason=buffer_too_small. Upload is intended for session setup before frame
// encoding; this route does not draw the uploaded texture into any frame.
extern "C" JNIEXPORT jstring JNICALL
Java_com_connects_vanguard_1media_1engine_bridge_VanguardNativeBridge_uploadAndroidTimelineVulkanExportOverlayTexture(
    JNIEnv*  env,
    jobject  /* this */,
    jstring  sessionIdJ,
    jobject  rgbaBufferJ,
    jint     width,
    jint     height,
    jint     rowStrideBytes) {

    char status[384];

    if (!sessionIdJ) {
        std::snprintf(status, sizeof(status),
            "status=FAIL;sessionId=none;reason=invalid_args");
        return env->NewStringUTF(status);
    }

    const char* sidCStr = env->GetStringUTFChars(sessionIdJ, nullptr);
    std::string sid(sidCStr ? sidCStr : "");
    if (sidCStr) env->ReleaseStringUTFChars(sessionIdJ, sidCStr);

    if (!rgbaBufferJ || width <= 0 || height <= 0 || rowStrideBytes < 0) {
        std::snprintf(status, sizeof(status),
            "status=FAIL;sessionId=%s;reason=invalid_args", sid.c_str());
        return env->NewStringUTF(status);
    }

    void* rawAddress = env->GetDirectBufferAddress(rgbaBufferJ);
    const jlong capacity = env->GetDirectBufferCapacity(rgbaBufferJ);
    if (rawAddress == nullptr || capacity <= 0) {
        std::snprintf(status, sizeof(status),
            "status=FAIL;sessionId=%s;reason=not_direct_buffer", sid.c_str());
        return env->NewStringUTF(status);
    }

    const uint64_t minStride = static_cast<uint64_t>(width) * 4u;
    const uint64_t effectiveStride =
        rowStrideBytes == 0 ? minStride : static_cast<uint64_t>(rowStrideBytes);
    if (effectiveStride < minStride) {
        std::snprintf(status, sizeof(status),
            "status=FAIL;sessionId=%s;reason=invalid_stride", sid.c_str());
        return env->NewStringUTF(status);
    }
    if (effectiveStride * static_cast<uint64_t>(height) > static_cast<uint64_t>(capacity)) {
        std::snprintf(status, sizeof(status),
            "status=FAIL;sessionId=%s;reason=buffer_too_small", sid.c_str());
        return env->NewStringUTF(status);
    }

    VulkanExportSession* session = nullptr;
    {
        std::lock_guard<std::mutex> lock(gVulkanExportSessionMutex);
        auto it = gVulkanExportSessions.find(sid);
        if (it != gVulkanExportSessions.end()) {
            session = it->second;
            session->activeRenderCount++;
        }
    }

    if (!session) {
        std::snprintf(status, sizeof(status),
            "status=FAIL;sessionId=%s;reason=session_not_found", sid.c_str());
        return env->NewStringUTF(status);
    }

    struct ReleaseGuard {
        VulkanExportSession* s;
        ~ReleaseGuard() {
            std::lock_guard<std::mutex> lock(gVulkanExportSessionMutex);
            if (--s->activeRenderCount == 0) {
                gVulkanExportSessionIdleCv.notify_all();
            }
        }
    } releaseGuard{session};

    if (!session->initialized || !session->surfaceAttached) {
        std::snprintf(status, sizeof(status),
            "status=FAIL;sessionId=%s;reason=session_not_ready", sid.c_str());
        return env->NewStringUTF(status);
    }

    vanguard::render::VulkanOverlayTextureHandle handle =
        vanguard::render::kInvalidOverlayTextureHandle;
    vanguard::render::VulkanOverlayTextureInfo info{};
    bool created = false;
    {
        std::lock_guard<std::mutex> lane(session->backendLaneMutex);
        created = session->backend.createOverlayTextureRgba8888(
            static_cast<const uint8_t*>(rawAddress),
            static_cast<size_t>(capacity),
            static_cast<uint32_t>(width),
            static_cast<uint32_t>(height),
            static_cast<uint32_t>(rowStrideBytes),
            &handle,
            &info);
    }

    if (!created) {
        std::snprintf(status, sizeof(status),
            "status=FAIL;sessionId=%s;reason=texture_create_failed", sid.c_str());
        return env->NewStringUTF(status);
    }

    std::snprintf(status, sizeof(status),
        "status=OK;sessionId=%s;textureHandle=%llu;imageViewHandle=%llu;samplerHandle=%llu;"
        "width=%u;height=%u",
        sid.c_str(),
        static_cast<unsigned long long>(handle),
        static_cast<unsigned long long>(info.imageViewHandle),
        static_cast<unsigned long long>(info.samplerHandle),
        info.width, info.height);
    return env->NewStringUTF(status);
}

// ---------------------------------------------------------------------------
// JNI: releaseAndroidTimelineVulkanExportOverlayTexture
// ---------------------------------------------------------------------------
// P5-OVERLAYS-PRODUCTION-EXPORT-ROUTE-A sub-slice N5: releases one overlay
// texture previously returned by uploadAndroidTimelineVulkanExportOverlayTexture.
extern "C" JNIEXPORT jstring JNICALL
Java_com_connects_vanguard_1media_1engine_bridge_VanguardNativeBridge_releaseAndroidTimelineVulkanExportOverlayTexture(
    JNIEnv*  env,
    jobject  /* this */,
    jstring  sessionIdJ,
    jlong    textureHandleJ) {

    char status[256];
    const unsigned long long textureHandleU = static_cast<unsigned long long>(textureHandleJ);

    if (!sessionIdJ) {
        std::snprintf(status, sizeof(status),
            "status=FAIL;sessionId=none;textureHandle=%llu;reason=invalid_args", textureHandleU);
        return env->NewStringUTF(status);
    }

    const char* sidCStr = env->GetStringUTFChars(sessionIdJ, nullptr);
    std::string sid(sidCStr ? sidCStr : "");
    if (sidCStr) env->ReleaseStringUTFChars(sessionIdJ, sidCStr);

    if (textureHandleJ <= 0) {
        std::snprintf(status, sizeof(status),
            "status=FAIL;sessionId=%s;textureHandle=%llu;reason=invalid_args",
            sid.c_str(), textureHandleU);
        return env->NewStringUTF(status);
    }

    VulkanExportSession* session = nullptr;
    {
        std::lock_guard<std::mutex> lock(gVulkanExportSessionMutex);
        auto it = gVulkanExportSessions.find(sid);
        if (it != gVulkanExportSessions.end()) {
            session = it->second;
            session->activeRenderCount++;
        }
    }

    if (!session) {
        std::snprintf(status, sizeof(status),
            "status=FAIL;sessionId=%s;textureHandle=%llu;reason=session_not_found",
            sid.c_str(), textureHandleU);
        return env->NewStringUTF(status);
    }

    struct ReleaseGuard {
        VulkanExportSession* s;
        ~ReleaseGuard() {
            std::lock_guard<std::mutex> lock(gVulkanExportSessionMutex);
            if (--s->activeRenderCount == 0) {
                gVulkanExportSessionIdleCv.notify_all();
            }
        }
    } releaseGuard{session};

    if (!session->initialized || !session->surfaceAttached) {
        std::snprintf(status, sizeof(status),
            "status=FAIL;sessionId=%s;textureHandle=%llu;reason=session_not_ready",
            sid.c_str(), textureHandleU);
        return env->NewStringUTF(status);
    }

    bool released = false;
    {
        std::lock_guard<std::mutex> lane(session->backendLaneMutex);
        released = session->backend.releaseOverlayTexture(
            static_cast<vanguard::render::VulkanOverlayTextureHandle>(textureHandleJ));
    }

    if (!released) {
        std::snprintf(status, sizeof(status),
            "status=FAIL;sessionId=%s;textureHandle=%llu;reason=release_failed",
            sid.c_str(), textureHandleU);
        return env->NewStringUTF(status);
    }

    std::snprintf(status, sizeof(status),
        "status=OK;sessionId=%s;textureHandle=%llu", sid.c_str(), textureHandleU);
    return env->NewStringUTF(status);
}

// ---------------------------------------------------------------------------
// JNI: clearAndroidTimelineVulkanExportOverlayTextures
// ---------------------------------------------------------------------------
// P5-OVERLAYS-PRODUCTION-EXPORT-ROUTE-A sub-slice N5: releases every overlay
// texture currently held by the session's overlay texture store. An empty
// store is a legal no-op (still reports status=OK).
extern "C" JNIEXPORT jstring JNICALL
Java_com_connects_vanguard_1media_1engine_bridge_VanguardNativeBridge_clearAndroidTimelineVulkanExportOverlayTextures(
    JNIEnv*  env,
    jobject  /* this */,
    jstring  sessionIdJ) {

    char status[256];

    if (!sessionIdJ) {
        std::snprintf(status, sizeof(status),
            "status=FAIL;sessionId=none;reason=invalid_args");
        return env->NewStringUTF(status);
    }

    const char* sidCStr = env->GetStringUTFChars(sessionIdJ, nullptr);
    std::string sid(sidCStr ? sidCStr : "");
    if (sidCStr) env->ReleaseStringUTFChars(sessionIdJ, sidCStr);

    VulkanExportSession* session = nullptr;
    {
        std::lock_guard<std::mutex> lock(gVulkanExportSessionMutex);
        auto it = gVulkanExportSessions.find(sid);
        if (it != gVulkanExportSessions.end()) {
            session = it->second;
            session->activeRenderCount++;
        }
    }

    if (!session) {
        std::snprintf(status, sizeof(status),
            "status=FAIL;sessionId=%s;reason=session_not_found", sid.c_str());
        return env->NewStringUTF(status);
    }

    struct ReleaseGuard {
        VulkanExportSession* s;
        ~ReleaseGuard() {
            std::lock_guard<std::mutex> lock(gVulkanExportSessionMutex);
            if (--s->activeRenderCount == 0) {
                gVulkanExportSessionIdleCv.notify_all();
            }
        }
    } releaseGuard{session};

    if (!session->initialized || !session->surfaceAttached) {
        std::snprintf(status, sizeof(status),
            "status=FAIL;sessionId=%s;reason=session_not_ready", sid.c_str());
        return env->NewStringUTF(status);
    }

    {
        std::lock_guard<std::mutex> lane(session->backendLaneMutex);
        session->backend.clearOverlayTextures();
    }

    std::snprintf(status, sizeof(status), "status=OK;sessionId=%s", sid.c_str());
    return env->NewStringUTF(status);
}

// ---------------------------------------------------------------------------
// JNI: destroyAndroidTimelineVulkanExportSession
// ---------------------------------------------------------------------------
extern "C" JNIEXPORT jstring JNICALL
Java_com_connects_vanguard_1media_1engine_bridge_VanguardNativeBridge_destroyAndroidTimelineVulkanExportSession(
    JNIEnv*  env,
    jobject  /* this */,
    jstring  sessionIdJ) {

    char status[256];

    if (!sessionIdJ) {
        std::snprintf(status, sizeof(status),
            "status=FAIL;reason=null_session_id");
        return env->NewStringUTF(status);
    }

    const char* sidCStr = env->GetStringUTFChars(sessionIdJ, nullptr);
    std::string sid(sidCStr ? sidCStr : "");
    if (sidCStr) env->ReleaseStringUTFChars(sessionIdJ, sidCStr);

    VulkanExportSession* session = nullptr;
    {
        std::unique_lock<std::mutex> lock(gVulkanExportSessionMutex);
        auto it = gVulkanExportSessions.find(sid);
        if (it != gVulkanExportSessions.end()) {
            session = it->second;
            // Remove from the registry first so any render call that has
            // not already claimed this session (i.e. has not yet looked it
            // up under this same lock) fails with session_not_found instead
            // of racing the cleanup below.
            gVulkanExportSessions.erase(it);
            // Any render call that claimed the session before this erase
            // is still holding an activeRenderCount reference; wait for it
            // to finish (releasing the lock while waiting) before this
            // function is allowed to touch the backend or delete session.
            gVulkanExportSessionIdleCv.wait(
                lock, [session] { return session->activeRenderCount == 0; });
        }
    }

    if (!session) {
        std::snprintf(status, sizeof(status),
            "status=FAIL;reason=session_not_found;sessionId=%s", sid.c_str());
        return env->NewStringUTF(status);
    }

    // No render call can be using this session's backend at this point:
    // it is no longer reachable from the registry, and the wait above
    // confirmed activeRenderCount reached zero. Backend calls below
    // intentionally run without holding gVulkanExportSessionMutex.
    const int renderedFrames = session->renderedFrames;

    try {
        if (session->surfaceAttached) {
            session->backend.detachSurface();
        }
        if (session->initialized) {
            session->backend.shutdown();
        }
    } catch (...) {}

    if (session->nativeWindow) {
        ANativeWindow_release(session->nativeWindow);
        session->nativeWindow = nullptr;
    }

    delete session;

    std::snprintf(status, sizeof(status),
        "status=OK;sessionId=%s;renderedFrames=%d",
        sid.c_str(), renderedFrames);
    return env->NewStringUTF(status);
}
