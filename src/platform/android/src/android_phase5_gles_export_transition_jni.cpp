// android_phase5_gles_export_transition_jni.cpp
// P5-GLES-EXPORT-TRANSITION-PRODUCTION-ROUTE-A: production native transition
// composite seam for the narrow GLES-transition-eligible export route
// (AndroidTimelineGlesTransitionVideoEncoder). AndroidTimelineGlesTransition-
// VideoEncoder calls this once per rendered transition-overlap pair -- after
// resolving both decoded OES frames (with their own SurfaceTexture transform
// matrices applied) into their own canvas-sized GL_TEXTURE_2D rasters and
// clearing its own encoder-surface framebuffer -- to composite the crossfade
// mix onto the caller's already-current GLES export EGL surface.
//
// This translation unit creates and destroys NOTHING GL/EGL-related: no EGL
// context, no EGL surface, no GL texture, no MediaCodec/SurfaceTexture. It
// only validates the caller-supplied scalar arguments (mirroring the
// P5-GLES-EXPORT-DUAL-OES-PRERESOLVE-TRANSITION-READINESS diagnostic seam,
// android_phase5_gles_dual_oes_transition_jni.cpp) and forwards them to the
// same private vanguard::render::GlesTimelineTransitionCompositor::
// drawTransition helper, which validates/draws/restores GL state on the
// thread's already-current context and hands control straight back.
// GlesTimelineTransitionCompositor itself is untouched by this slice.
//
// This slice only implements a safe crossfade mix draw: [transitionTypeCode]
// must equal AndroidTimelineTransitionDescriptor.Type.CROSSFADE.nativeCode
// (1); any other code -- including hard-cut's 0, or a slide/wipe family --
// fails closed before any GL call with a precise unsupported-type reason
// rather than attempt geometry this route does not yet implement safely.
// Both viewports/crops stay at their identity defaults (matching the
// diagnostic seam's fixed-midpoint proof), which is exactly the shape the
// compositor's mix draw requires.
//
// Production route only for the narrow GLES-transition-eligible shape gated
// by AndroidExportRenderBackendSelector.ExportRenderScope.glesTransitionEligible
// (video-only, non-reversed, non-beauty clips; no overlays; zero rotation) --
// any wider transition shape still requires Vulkan and never reaches this
// seam. Unlike the diagnostic seam, this production route returns a compact
// "status=OK;..." / "status=FAIL;reason=<reason>" string (the same key=value
// convention as android_vulkan_export_jni.cpp's and
// android_phase5_gles_export_overlay_jni.cpp's production routes), not a
// JSON object, and carries no diagnostic proofBoundary. This helper never
// clears the framebuffer -- the Kotlin caller owns frame clear/pre-resolve.
//
// JNI entry point (matching VanguardNativeBridge.kt declaration):
//   drawAndroidTimelineGlesTransitionExportFrame -> jstring (compact status)

#include <jni.h>

#include <cmath>
#include <cstdint>
#include <cstdio>
#include <string>

#include "gles_timeline_transition_compositor.h"

namespace {

using vanguard::render::GlesTimelineTransitionCompositor;
using vanguard::render::GlesTimelineTransitionGeometry;

constexpr uint32_t kTargetOes = 0x8D65;  // GL_TEXTURE_EXTERNAL_OES
constexpr uint32_t kTarget2d = 0x0DE1;   // GL_TEXTURE_2D

// Must match AndroidTimelineTransitionDescriptor.Type.CROSSFADE.nativeCode.
// This slice only implements the crossfade mix draw; kept as a local
// constant (deliberately duplicated per-TU; see sibling diagnostic/
// production JNI translation units for the same pattern) rather than
// depending on a shared enum header.
constexpr jint kCrossfadeTypeCode = 1;

bool IsSupportedTextureTarget(uint32_t target) {
    return target == kTargetOes || target == kTarget2d;
}

std::string BuildStatus(bool ok, const std::string& detail) {
    return ok ? ("status=OK;" + detail) : ("status=FAIL;reason=" + detail);
}

}  // namespace

extern "C" JNIEXPORT jstring JNICALL
Java_com_connects_vanguard_1media_1engine_bridge_VanguardNativeBridge_drawAndroidTimelineGlesTransitionExportFrame(
    JNIEnv* env,
    jobject /* this */,
    jint fromTextureId,
    jint fromTextureTarget,
    jint toTextureId,
    jint toTextureTarget,
    jint surfaceWidth,
    jint surfaceHeight,
    jint transitionTypeCode,
    jdouble progress) {

    if (fromTextureId <= 0 || toTextureId <= 0) {
        return env->NewStringUTF(BuildStatus(false, "invalid_texture").c_str());
    }
    if (surfaceWidth <= 0 || surfaceHeight <= 0) {
        return env->NewStringUTF(BuildStatus(false, "invalid_dimensions").c_str());
    }
    if (!IsSupportedTextureTarget(static_cast<uint32_t>(fromTextureTarget)) ||
        !IsSupportedTextureTarget(static_cast<uint32_t>(toTextureTarget))) {
        return env->NewStringUTF(BuildStatus(false, "unsupported_texture_target").c_str());
    }
    if (!std::isfinite(static_cast<double>(progress)) || progress < 0.0 || progress > 1.0) {
        return env->NewStringUTF(BuildStatus(false, "invalid_progress").c_str());
    }
    if (transitionTypeCode != kCrossfadeTypeCode) {
        char reason[64];
        std::snprintf(reason, sizeof(reason), "unsupported_transition_type:code=%d",
                      static_cast<int>(transitionTypeCode));
        return env->NewStringUTF(BuildStatus(false, reason).c_str());
    }

    const double blendWeightTo = static_cast<double>(progress);
    const double blendWeightFrom = 1.0 - blendWeightTo;

    GlesTimelineTransitionGeometry geometry;
    geometry.progress = static_cast<double>(progress);
    geometry.blendWeightFrom = blendWeightFrom;
    geometry.blendWeightTo = blendWeightTo;
    // fromViewport/toViewport/fromCrop/toCrop stay at their identity
    // defaults (x=0,y=0,width=1,height=1) -- the full-canvas crossfade mix
    // draw this route performs requires exactly that.

    GlesTimelineTransitionCompositor compositor;
    std::string drawError;
    const bool ok = compositor.drawTransition(
        static_cast<uint32_t>(fromTextureId), static_cast<uint32_t>(fromTextureTarget),
        static_cast<uint32_t>(toTextureId), static_cast<uint32_t>(toTextureTarget),
        static_cast<uint32_t>(surfaceWidth), static_cast<uint32_t>(surfaceHeight),
        geometry, &drawError);

    if (!ok) {
        return env->NewStringUTF(
            BuildStatus(false, drawError.empty() ? "draw_transition_failed" : drawError).c_str());
    }

    char detail[96];
    std::snprintf(detail, sizeof(detail), "blendWeightFrom=%.9g;blendWeightTo=%.9g", blendWeightFrom, blendWeightTo);
    return env->NewStringUTF(BuildStatus(true, detail).c_str());
}
