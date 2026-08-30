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
//                                                                  Phase 10: optional 20-element raw colorMatrix)
//   destroyAndroidTimelineVulkanExportSession        -> jstring

#include <jni.h>

#include <android/hardware_buffer.h>
#include <android/native_window_jni.h>
#include <dlfcn.h>
#include <unistd.h>

#include <atomic>
#include <condition_variable>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <mutex>
#include <string>
#include <unordered_map>

#include "vanguard/render/vulkan_backend.h"

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
    // Number of in-flight render calls currently using this session's
    // backend. Guarded by gVulkanExportSessionMutex. destroy() waits for
    // this to reach zero (after removing the session from the registry)
    // before touching the backend or freeing the session.
    int                             activeRenderCount{0};
};

// ---------------------------------------------------------------------------
// Session registry (guarded by mutex)
// ---------------------------------------------------------------------------
//
// Lifetime safety: renderAndroidTimelineVulkanExportFrame and
// destroyAndroidTimelineVulkanExportSession both serialize their registry
// lookup/erase and activeRenderCount bookkeeping on gVulkanExportSessionMutex.
// destroy() erases the session from the map before waiting for
// activeRenderCount to drain, so no new render can observe a closing
// session, and no render can still be touching the backend once destroy
// proceeds to detach/shutdown/release/delete. Neither side ever calls into
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
    const auto importResult = session->backend.importHardwareBuffer(
        ahwb, -1, &handle, &descriptor);

    if (importResult != vanguard::render::HardwareBufferImportResult::kSuccess) {
        std::snprintf(status, sizeof(status),
            "status=FAIL;frameIndex=%d;reason=import_failed;importResult=%s",
            static_cast<int>(frameIndex),
            HwBufResultName(importResult));
        return env->NewStringUTF(status);
    }

    const auto renderResult = session->backend.renderFrame(handle);
    const bool renderOk =
        renderResult == vanguard::render::RenderFrameResult::kSuccess ||
        renderResult == vanguard::render::RenderFrameResult::kSuboptimal;

    int releaseFenceFd = -1;
    const auto releaseResult =
        session->backend.releaseHardwareBuffer(handle, &releaseFenceFd);
    if (releaseFenceFd >= 0) {
        ::close(releaseFenceFd);
        releaseFenceFd = -1;
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
    jfloatArray colorMatrix) {

    char status[512];

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
    const auto importResult = session->backend.importHardwareBuffer(
        ahwb, -1, &handle, &descriptor);

    if (importResult != vanguard::render::HardwareBufferImportResult::kSuccess) {
        std::snprintf(status, sizeof(status),
            "status=FAIL;frameIndex=%d;reason=import_failed;importResult=%s",
            static_cast<int>(frameIndex),
            HwBufResultName(importResult));
        return env->NewStringUTF(status);
    }

    // Normalize the crop against the *imported* descriptor -- the
    // authoritative source of truth for the real (possibly padded) buffer
    // geometry, per Opus P0. Any failure past this point still releases the
    // successfully imported buffer before returning.
    const bool cropWithinBuffer =
        descriptor.width > 0 && descriptor.height > 0 &&
        static_cast<uint32_t>(cropRight) <= descriptor.width &&
        static_cast<uint32_t>(cropBottom) <= descriptor.height;

    vanguard::render::RenderFrameResult renderResult =
        vanguard::render::RenderFrameResult::kInvalidBufferHandle;
    bool renderOk = false;

    if (!cropWithinBuffer) {
        // Fall through without rendering; buffer is still released below.
    } else {
        vanguard::render::VideoFrameTransform transform{};
        transform.rotationDegrees = static_cast<uint32_t>(rotationDegrees);
        transform.cropScaleU =
            static_cast<float>(cropRight - cropLeft) / static_cast<float>(descriptor.width);
        transform.cropScaleV =
            static_cast<float>(cropBottom - cropTop) / static_cast<float>(descriptor.height);
        transform.cropBiasU =
            static_cast<float>(cropLeft) / static_cast<float>(descriptor.width);
        transform.cropBiasV =
            static_cast<float>(cropTop) / static_cast<float>(descriptor.height);
        transform.destinationRect.x = static_cast<int32_t>(destFitX);
        transform.destinationRect.y = static_cast<int32_t>(destFitY);
        transform.destinationRect.width = static_cast<int32_t>(destFitWidth);
        transform.destinationRect.height = static_cast<int32_t>(destFitHeight);

        // Phase 10: colorMatrix was already validated (length == 20) before
        // the buffer was imported above; [colorMatrixValues] holds the raw
        // (un-normalized) 4x5 row-major values. Offsets (indices 4, 9, 14,
        // 19) are normalized by /255.0 exactly once here, matching the GLES
        // backend's uColorMatrixOffset upload convention.
        if (hasColorMatrix) {
            transform.colorMatrixEnabled = true;
            transform.colorMatrixRow0[0] = colorMatrixValues[0];
            transform.colorMatrixRow0[1] = colorMatrixValues[1];
            transform.colorMatrixRow0[2] = colorMatrixValues[2];
            transform.colorMatrixRow0[3] = colorMatrixValues[3];
            transform.colorMatrixRow1[0] = colorMatrixValues[5];
            transform.colorMatrixRow1[1] = colorMatrixValues[6];
            transform.colorMatrixRow1[2] = colorMatrixValues[7];
            transform.colorMatrixRow1[3] = colorMatrixValues[8];
            transform.colorMatrixRow2[0] = colorMatrixValues[10];
            transform.colorMatrixRow2[1] = colorMatrixValues[11];
            transform.colorMatrixRow2[2] = colorMatrixValues[12];
            transform.colorMatrixRow2[3] = colorMatrixValues[13];
            transform.colorMatrixRow3[0] = colorMatrixValues[15];
            transform.colorMatrixRow3[1] = colorMatrixValues[16];
            transform.colorMatrixRow3[2] = colorMatrixValues[17];
            transform.colorMatrixRow3[3] = colorMatrixValues[18];
            transform.colorMatrixOffset[0] = colorMatrixValues[4] / 255.0f;
            transform.colorMatrixOffset[1] = colorMatrixValues[9] / 255.0f;
            transform.colorMatrixOffset[2] = colorMatrixValues[14] / 255.0f;
            transform.colorMatrixOffset[3] = colorMatrixValues[19] / 255.0f;
        }

        renderResult = session->backend.renderFrame(handle, transform);
        renderOk =
            renderResult == vanguard::render::RenderFrameResult::kSuccess ||
            renderResult == vanguard::render::RenderFrameResult::kSuboptimal;
    }

    int releaseFenceFd = -1;
    const auto releaseResult =
        session->backend.releaseHardwareBuffer(handle, &releaseFenceFd);
    if (releaseFenceFd >= 0) {
        ::close(releaseFenceFd);
        releaseFenceFd = -1;
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
        "destFit=%d,%d-%dx%d;colorMatrix=%d",
        static_cast<int>(frameIndex),
        static_cast<long long>(timelinePtsUs),
        session->renderedFrames,
        RenderResultName(renderResult),
        HwBufResultName(releaseResult),
        descriptor.width, descriptor.height,
        static_cast<int>(destFitX), static_cast<int>(destFitY),
        static_cast<int>(destFitWidth), static_cast<int>(destFitHeight),
        hasColorMatrix ? 1 : 0);
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
