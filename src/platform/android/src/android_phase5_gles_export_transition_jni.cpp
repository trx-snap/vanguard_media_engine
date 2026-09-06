// android_phase5_gles_export_transition_jni.cpp
// P5-GLES-EXPORT-TRANSITION-PRODUCTION-ROUTE-A, widened by
// P5-GLES-EXPORT-TRANSITION-SLIDE-WIPE: production native transition
// composite seam for the narrow GLES-transition-eligible export route
// (AndroidTimelineGlesTransitionVideoEncoder). AndroidTimelineGlesTransition-
// VideoEncoder calls this once per rendered transition-overlap pair -- after
// resolving both decoded OES frames (with their own SurfaceTexture transform
// matrices applied) into their own canvas-sized GL_TEXTURE_2D rasters and
// clearing its own encoder-surface framebuffer -- to composite the resolved
// transition draw onto the caller's already-current GLES export EGL surface.
//
// This translation unit creates and destroys NOTHING GL/EGL-related: no EGL
// context, no EGL surface, no GL texture, no MediaCodec/SurfaceTexture. It
// only validates the caller-supplied scalar arguments (mirroring the
// P5-GLES-EXPORT-DUAL-OES-PRERESOLVE-TRANSITION-READINESS diagnostic seam,
// android_phase5_gles_dual_oes_transition_jni.cpp), maps [transitionTypeCode]
// to a vanguard::compositors::TransitionType, evaluates the same
// compositor-owned pure math the shader/raster diagnostic proof
// (android_phase5_timeline_transition_gles_render_jni.cpp) already validated
// physically for every family -- vanguard::compositors::
// ComputeTransitionGeometry() -- and forwards the resolved geometry to the
// same private vanguard::render::GlesTimelineTransitionCompositor::
// drawTransition helper, which validates/draws/restores GL state on the
// thread's already-current context and hands control straight back. Neither
// GlesTimelineTransitionCompositor nor VGTimelineCompositorNode /
// ComputeTransitionGeometry are touched by this slice; this JNI translation
// unit is one of the composition roots that links the compositors and
// vanguard_render_gles libraries together (they never include each other).
//
// [transitionTypeCode] must be one of the nine wire codes
// AndroidTimelineTransitionDescriptor.Type defines for a non-hard-cut
// transition (1=crossfade, 2..5=wipeLeft/Right/Up/Down, 6..9=slideLeft/
// Right/Up/Down; 0/hard-cut is never sent to this route by the Kotlin
// caller). Any other value fails closed before any GL call with
// "unsupported_transition_type:code=<n>".
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
#include "vanguard/compositors/vg_timeline_compositor_node.h"

namespace {

using vanguard::compositors::ComputeTransitionGeometry;
using vanguard::compositors::TimelineNormalizedRect;
using vanguard::compositors::TimelineTransitionProgress;
using vanguard::compositors::TransitionType;
using vanguard::render::GlesTimelineNormalizedRect;
using vanguard::render::GlesTimelineTransitionCompositor;
using vanguard::render::GlesTimelineTransitionGeometry;

constexpr uint32_t kTargetOes = 0x8D65;  // GL_TEXTURE_EXTERNAL_OES
constexpr uint32_t kTarget2d = 0x0DE1;   // GL_TEXTURE_2D

bool IsSupportedTextureTarget(uint32_t target) {
    return target == kTargetOes || target == kTarget2d;
}

std::string BuildStatus(bool ok, const std::string& detail) {
    return ok ? ("status=OK;" + detail) : ("status=FAIL;reason=" + detail);
}

// Maps AndroidTimelineTransitionDescriptor.Type.nativeCode (1..9) to the
// matching vanguard::compositors::TransitionType. Returns false (leaving
// *outType untouched) for 0 (hard cut, never sent to this route by the
// Kotlin caller) or any code outside the closed wire set.
bool TransitionTypeFromWireCode(jint code, TransitionType* outType) {
    switch (code) {
        case 1: *outType = TransitionType::kCrossfade;  return true;
        case 2: *outType = TransitionType::kWipeLeft;   return true;
        case 3: *outType = TransitionType::kWipeRight;  return true;
        case 4: *outType = TransitionType::kWipeUp;     return true;
        case 5: *outType = TransitionType::kWipeDown;   return true;
        case 6: *outType = TransitionType::kSlideLeft;  return true;
        case 7: *outType = TransitionType::kSlideRight; return true;
        case 8: *outType = TransitionType::kSlideUp;    return true;
        case 9: *outType = TransitionType::kSlideDown;  return true;
        default: return false;
    }
}

GlesTimelineNormalizedRect ToGlesRect(const TimelineNormalizedRect& r) {
    GlesTimelineNormalizedRect out;
    out.x      = r.x;
    out.y      = r.y;
    out.width  = r.width;
    out.height = r.height;
    return out;
}

GlesTimelineTransitionGeometry ToGlesGeometry(const TimelineTransitionProgress& p) {
    GlesTimelineTransitionGeometry g;
    g.progress        = p.progress;
    g.blendWeightFrom = p.blendWeightFrom;
    g.blendWeightTo   = p.blendWeightTo;
    g.fromViewport    = ToGlesRect(p.fromViewport);
    g.toViewport      = ToGlesRect(p.toViewport);
    g.fromCrop        = ToGlesRect(p.fromCrop);
    g.toCrop          = ToGlesRect(p.toCrop);
    return g;
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
    TransitionType type = TransitionType::kNone;
    if (!TransitionTypeFromWireCode(transitionTypeCode, &type)) {
        char reason[64];
        std::snprintf(reason, sizeof(reason), "unsupported_transition_type:code=%d",
                      static_cast<int>(transitionTypeCode));
        return env->NewStringUTF(BuildStatus(false, reason).c_str());
    }

    const GlesTimelineTransitionGeometry geometry =
        ToGlesGeometry(ComputeTransitionGeometry(type, static_cast<double>(progress)));

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

    char detail[160];
    std::snprintf(detail, sizeof(detail),
                  "transitionTypeCode=%d;progress=%.9g;blendWeightFrom=%.9g;blendWeightTo=%.9g",
                  static_cast<int>(transitionTypeCode), geometry.progress,
                  geometry.blendWeightFrom, geometry.blendWeightTo);
    return env->NewStringUTF(BuildStatus(true, detail).c_str());
}
