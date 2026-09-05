// android_phase5_gles_export_overlay_jni.cpp
// P5-GLES-EXPORT-OVERLAY-PRODUCTION-ROUTE-A: production native overlay
// composite seam for the GLES export route. AndroidTimelineVideoEncoder
// calls this once per rendered base frame -- after its own base draw and
// attribute-array disable, before EGLExt.eglPresentationTimeANDROID /
// eglSwapBuffers -- to composite every overlay active at that frame onto the
// caller's already-current GLES export EGL surface.
//
// This translation unit creates and destroys NOTHING GL/EGL-related: no EGL
// context, no EGL surface, no GL texture. It only parses caller-supplied
// layer descriptor arrays (already-placed GL_TEXTURE_2D overlay textures
// uploaded by AndroidTimelineGlesOverlayRenderSession), validates their
// shape exactly like the P5-GLES-EXPORT-OVERLAY-SEAM-A diagnostic seam
// (android_phase5_gles_export_overlay_seam_jni.cpp), and forwards them to
// the same private vanguard::render::GlesOverlayCompositor::drawOverlays
// helper, which validates/draws/restores GL state on the thread's
// already-current context and hands control straight back.
// GlesOverlayCompositor itself is untouched by this slice.
//
// Production route only for the narrow GLES-overlay-eligible shape gated by
// AndroidExportRenderBackendSelector.glesOverlayEligible (video-only,
// non-reversed, non-beauty clips; hard-cut-only transitions) -- any wider
// overlay shape still requires Vulkan and never reaches this seam. Unlike
// the diagnostic seam, this production route returns a compact
// "status=OK;overlayCount=N" / "status=FAIL;reason=<reason>" string (the
// same key=value convention as android_vulkan_export_jni.cpp's production
// routes), not a JSON object, and carries no diagnostic proofBoundary.
//
// JNI entry point (matching VanguardNativeBridge.kt declaration):
//   drawAndroidTimelineGlesExportOverlays -> jstring (compact status string)

#include <jni.h>

#include <cstdint>
#include <cstdio>
#include <string>
#include <vector>

#include "gles_overlay_compositor.h"

namespace {

using vanguard::render::GlesOverlayCompositor;
using vanguard::render::GlesOverlayLayerDescriptor;

// Per-layer geometry fields packed into the flat `geometry` DoubleArray, in
// this exact order: x, y, width, height, rotation, scale, opacity.
constexpr int kFieldsPerLayer = 7;

// Mirrors the Vulkan overlay route's per-call cap
// (android_vulkan_export_jni.cpp kMaxOverlayCount) and the Kotlin export
// session's MAX_OVERLAY_COUNT -- a single frame never composites more than
// the export's own overlay-list ceiling.
constexpr jint kMaxOverlayCount = 128;

}  // namespace

extern "C" JNIEXPORT jstring JNICALL
Java_com_connects_vanguard_1media_1engine_bridge_VanguardNativeBridge_drawAndroidTimelineGlesExportOverlays(
    JNIEnv* env,
    jobject /* this */,
    jintArray textureIds,
    jintArray textureTargets,
    jdoubleArray geometry,
    jintArray zIndices,
    jint overlayCount,
    jint surfaceWidth,
    jint surfaceHeight) {

    char status[256];

    if (surfaceWidth <= 0 || surfaceHeight <= 0) {
        std::snprintf(status, sizeof(status), "status=FAIL;reason=invalid_surface_dimensions");
        return env->NewStringUTF(status);
    }
    if (overlayCount < 0 || overlayCount > kMaxOverlayCount) {
        std::snprintf(status, sizeof(status),
            "status=FAIL;reason=invalid_overlay_count:count=%d", static_cast<int>(overlayCount));
        return env->NewStringUTF(status);
    }

    GlesOverlayCompositor compositor;

    if (overlayCount == 0) {
        // A legal no-op draw: every array argument may be null.
        std::string err;
        const bool ok = compositor.drawOverlays(
            nullptr, 0, static_cast<uint32_t>(surfaceWidth), static_cast<uint32_t>(surfaceHeight), &err);
        if (!ok) {
            std::snprintf(status, sizeof(status), "status=FAIL;reason=%s",
                err.empty() ? "empty_layer_list_draw_failed" : err.c_str());
            return env->NewStringUTF(status);
        }
        std::snprintf(status, sizeof(status), "status=OK;overlayCount=0");
        return env->NewStringUTF(status);
    }

    if (textureIds == nullptr || textureTargets == nullptr || geometry == nullptr || zIndices == nullptr) {
        std::snprintf(status, sizeof(status), "status=FAIL;reason=null_array_argument");
        return env->NewStringUTF(status);
    }

    const jsize idsLen = env->GetArrayLength(textureIds);
    const jsize targetsLen = env->GetArrayLength(textureTargets);
    const jsize zLen = env->GetArrayLength(zIndices);
    const jsize geomLen = env->GetArrayLength(geometry);

    if (idsLen != overlayCount || targetsLen != overlayCount || zLen != overlayCount ||
        geomLen != static_cast<jsize>(overlayCount) * kFieldsPerLayer) {
        std::snprintf(status, sizeof(status), "status=FAIL;reason=array_length_mismatch");
        return env->NewStringUTF(status);
    }

    std::vector<jint> ids(static_cast<size_t>(overlayCount));
    std::vector<jint> targets(static_cast<size_t>(overlayCount));
    std::vector<jint> zs(static_cast<size_t>(overlayCount));
    std::vector<jdouble> geom(static_cast<size_t>(geomLen));

    env->GetIntArrayRegion(textureIds, 0, overlayCount, ids.data());
    env->GetIntArrayRegion(textureTargets, 0, overlayCount, targets.data());
    env->GetIntArrayRegion(zIndices, 0, overlayCount, zs.data());
    env->GetDoubleArrayRegion(geometry, 0, geomLen, geom.data());

    std::vector<GlesOverlayLayerDescriptor> layers(static_cast<size_t>(overlayCount));
    for (jint i = 0; i < overlayCount; ++i) {
        GlesOverlayLayerDescriptor& d = layers[static_cast<size_t>(i)];
        d.texture       = static_cast<uint32_t>(ids[static_cast<size_t>(i)]);
        d.textureTarget = static_cast<uint32_t>(targets[static_cast<size_t>(i)]);
        const size_t base = static_cast<size_t>(i) * kFieldsPerLayer;
        d.x        = geom[base + 0];
        d.y        = geom[base + 1];
        d.width    = geom[base + 2];
        d.height   = geom[base + 3];
        d.rotation = geom[base + 4];
        d.scale    = geom[base + 5];
        d.opacity  = geom[base + 6];
        d.zIndex   = zs[static_cast<size_t>(i)];
    }

    std::string err;
    const bool ok = compositor.drawOverlays(
        layers.data(), layers.size(),
        static_cast<uint32_t>(surfaceWidth), static_cast<uint32_t>(surfaceHeight), &err);
    if (!ok) {
        std::snprintf(status, sizeof(status), "status=FAIL;reason=%s",
            err.empty() ? "draw_overlays_failed" : err.c_str());
        return env->NewStringUTF(status);
    }

    std::snprintf(status, sizeof(status), "status=OK;overlayCount=%d", static_cast<int>(overlayCount));
    return env->NewStringUTF(status);
}
