// android_phase5_gles_export_beauty_seam_jni.cpp
// P5-GLES-EXPORT-OES-2D-BEAUTY-RESOLVE-READINESS: diagnostic-only native
// seam proving that a caller-current, current-verified GLES ES3 context
// already holding a resolved GL_TEXTURE_2D RGBA8 frame (a REAL
// MediaCodec-decoded GL_TEXTURE_EXTERNAL_OES frame, resolved to 2D by the
// Kotlin harness through its own FBO blit -- OES sampling never happens
// inside GlesBeautyV2Compositor) can still route into
// the exact same private vanguard::render::GlesBeautyV2Compositor::
// DrawBeautyV2 helper the P5-BEAUTY-V2-GLES-RENDER diagnostic already
// exercises against synthetic pbuffer textures.
//
// This translation unit creates and destroys NOTHING GL/EGL-related: no EGL
// context, no EGL surface, no GL texture, no FBO, no MediaCodec/
// SurfaceTexture. It only validates the caller-supplied scalar arguments,
// derives the intensity-ramp parameter set via
// ComputeBeautyV2ParametersFromIntensity, and forwards them to the private
// helper, which validates/draws/restores GL state on the thread's
// already-current context (owned by the Kotlin harness) and hands control
// straight back.
//
// Non-claims: diagnostic seam proof only. No production GLES Beauty export
// route; no AndroidTimelineVideoEncoder.kt / AndroidTimelineExportSession.kt
// / AndroidExportRenderBackendSelector.kt change. GlesBeautyV2Compositor
// itself is untouched and this file never creates or destroys a
// caller-owned EGL context, texture, or FBO.
//
// JNI entry point (matching VanguardNativeBridge.kt declaration):
//   drawAndroidDagPhase5GlesExportBeautySeam -> jstring (JSON)

#include <jni.h>

#include <cmath>
#include <cstdint>
#include <cstdio>
#include <sstream>
#include <string>

#include "gles_beauty_v2_compositor.h"

namespace {

using vanguard::render::ComputeBeautyV2ParametersFromIntensity;
using vanguard::render::GlesBeautyV2Compositor;
using vanguard::render::GlesBeautyV2Parameters;

constexpr const char* kProofBoundary =
    "native_gles_export_beauty_seam_caller_current_context_diagnostic_only_no_production_export";

const char* BoolStr(bool v) { return v ? "true" : "false"; }

std::string JsonEscape(const std::string& in) {
    std::string out;
    out.reserve(in.size() + 8);
    for (const char c : in) {
        switch (c) {
            case '"':  out += "\\\""; break;
            case '\\': out += "\\\\"; break;
            case '\n': out += "\\n";  break;
            case '\r': out += "\\r";  break;
            case '\t': out += "\\t";  break;
            default:
                if (static_cast<unsigned char>(c) < 0x20) {
                    char buf[8];
                    std::snprintf(buf, sizeof(buf), "\\u%04x", static_cast<unsigned>(c));
                    out += buf;
                } else {
                    out += c;
                }
        }
    }
    return out;
}

std::string BuildResult(bool pass,
                        const std::string& failureReason,
                        jint width,
                        jint height,
                        jfloat intensity) {
    std::ostringstream oss;
    oss << "{"
        << "\"status\":\"" << (pass ? "PASS" : "FAIL") << "\","
        << "\"pass\":" << BoolStr(pass) << ","
        << "\"failureReason\":\"" << JsonEscape(failureReason) << "\","
        << "\"width\":" << width << ","
        << "\"height\":" << height << ","
        << "\"intensity\":" << intensity << ","
        << "\"proofBoundary\":\"" << kProofBoundary << "\""
        << "}";
    return oss.str();
}

}  // namespace

extern "C" JNIEXPORT jstring JNICALL
Java_com_connects_vanguard_1media_1engine_bridge_VanguardNativeBridge_drawAndroidDagPhase5GlesExportBeautySeam(
    JNIEnv* env,
    jobject /* this */,
    jint inputTextureId,
    jint targetFbo,
    jint width,
    jint height,
    jfloat intensity) {

    auto fail = [&](const std::string& reason) {
        return env->NewStringUTF(BuildResult(false, reason, width, height, intensity).c_str());
    };

    if (width <= 0 || height <= 0) {
        return fail("invalid_surface_dimensions");
    }
    if (inputTextureId <= 0) {
        return fail("invalid_input_texture");
    }
    if (targetFbo < 0) {
        return fail("invalid_target_fbo");
    }
    if (!std::isfinite(static_cast<float>(intensity)) || intensity < 0.0f || intensity > 1.0f) {
        return fail("invalid_intensity");
    }

    GlesBeautyV2Parameters params;
    std::string rampErr;
    if (!ComputeBeautyV2ParametersFromIntensity(
            static_cast<float>(intensity),
            static_cast<uint32_t>(width),
            static_cast<uint32_t>(height),
            &params,
            &rampErr)) {
        return fail(rampErr.empty() ? "compute_beauty_v2_parameters_failed" : rampErr);
    }

    GlesBeautyV2Compositor compositor;
    std::string drawErr;
    const bool ok = compositor.DrawBeautyV2(
        static_cast<uint32_t>(inputTextureId),
        static_cast<uint32_t>(targetFbo),
        static_cast<uint32_t>(width),
        static_cast<uint32_t>(height),
        params,
        &drawErr);
    if (!ok) {
        return fail(drawErr.empty() ? "draw_beauty_v2_failed" : drawErr);
    }

    return env->NewStringUTF(BuildResult(true, "", width, height, intensity).c_str());
}
