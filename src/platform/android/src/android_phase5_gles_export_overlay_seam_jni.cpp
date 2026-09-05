// android_phase5_gles_export_overlay_seam_jni.cpp
// P5-GLES-EXPORT-OVERLAY-SEAM-A: diagnostic-only native seam proving that a
// caller-current GLES context already holding a REAL MediaCodec-decoded
// GL_TEXTURE_EXTERNAL_OES frame (drawn to the caller's own surface by Kotlin,
// mirroring AndroidTimelineVideoEncoder.kt's decode -> SurfaceTexture ->
// GL_TEXTURE_EXTERNAL_OES pipeline) can still route into the exact same
// private vanguard::render::GlesOverlayCompositor::drawOverlays helper the
// P5-OVERLAYS-TRANS diagnostic already exercises against a synthetic pbuffer.
//
// This translation unit creates and destroys NOTHING GL/EGL-related: no EGL
// context, no EGL surface, no GL texture, no MediaCodec/SurfaceTexture. It
// only parses caller-supplied layer descriptor arrays, validates their shape,
// and forwards them to the private helper, which validates/draws/restores GL
// state on the thread's already-current context (owned by the Kotlin
// harness) and hands control straight back.
//
// Non-claims: diagnostic seam proof only. No production export/session/
// backend-selector/encoder change; GlesOverlayCompositor itself is untouched
// and this file never creates or destroys a caller-owned EGL context or
// texture.
//
// JNI entry point (matching VanguardNativeBridge.kt declaration):
//   drawAndroidDagPhase5GlesExportOverlaySeam -> jstring (JSON)

#include <jni.h>

#include <cstdint>
#include <cstdio>
#include <sstream>
#include <string>
#include <vector>

#include "gles_overlay_compositor.h"

namespace {

using vanguard::render::GlesOverlayCompositor;
using vanguard::render::GlesOverlayLayerDescriptor;

constexpr const char* kProofBoundary =
    "native_gles_export_overlay_seam_caller_current_context_diagnostic_only_no_production_export";

// Per-layer geometry fields packed into the flat `geometry` DoubleArray, in
// this exact order: x, y, width, height, rotation, scale, opacity.
constexpr int kFieldsPerLayer = 7;

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
                        jint overlayCount,
                        jint surfaceWidth,
                        jint surfaceHeight) {
    std::ostringstream oss;
    oss << "{"
        << "\"status\":\"" << (pass ? "PASS" : "FAIL") << "\","
        << "\"pass\":" << BoolStr(pass) << ","
        << "\"failureReason\":\"" << JsonEscape(failureReason) << "\","
        << "\"overlayCount\":" << overlayCount << ","
        << "\"surfaceWidth\":" << surfaceWidth << ","
        << "\"surfaceHeight\":" << surfaceHeight << ","
        << "\"proofBoundary\":\"" << kProofBoundary << "\""
        << "}";
    return oss.str();
}

}  // namespace

extern "C" JNIEXPORT jstring JNICALL
Java_com_connects_vanguard_1media_1engine_bridge_VanguardNativeBridge_drawAndroidDagPhase5GlesExportOverlaySeam(
    JNIEnv* env,
    jobject /* this */,
    jintArray textureIds,
    jintArray textureTargets,
    jdoubleArray geometry,
    jintArray zIndices,
    jint overlayCount,
    jint surfaceWidth,
    jint surfaceHeight) {

    auto fail = [&](const std::string& reason) {
        return env->NewStringUTF(
            BuildResult(false, reason, overlayCount, surfaceWidth, surfaceHeight).c_str());
    };

    if (surfaceWidth <= 0 || surfaceHeight <= 0) {
        return fail("invalid_surface_dimensions");
    }
    if (overlayCount < 0) {
        return fail("invalid_overlay_count");
    }

    GlesOverlayCompositor compositor;

    if (overlayCount == 0) {
        // A legal no-op draw: every array argument may be null.
        std::string err;
        const bool ok = compositor.drawOverlays(
            nullptr, 0, static_cast<uint32_t>(surfaceWidth), static_cast<uint32_t>(surfaceHeight), &err);
        if (!ok) {
            return fail(err.empty() ? "empty_layer_list_draw_failed" : err);
        }
        return env->NewStringUTF(
            BuildResult(true, "", overlayCount, surfaceWidth, surfaceHeight).c_str());
    }

    if (textureIds == nullptr || textureTargets == nullptr || geometry == nullptr || zIndices == nullptr) {
        return fail("null_array_argument");
    }

    const jsize idsLen = env->GetArrayLength(textureIds);
    const jsize targetsLen = env->GetArrayLength(textureTargets);
    const jsize zLen = env->GetArrayLength(zIndices);
    const jsize geomLen = env->GetArrayLength(geometry);

    if (idsLen != overlayCount || targetsLen != overlayCount || zLen != overlayCount ||
        geomLen != static_cast<jsize>(overlayCount) * kFieldsPerLayer) {
        return fail("array_length_mismatch");
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
        return fail(err.empty() ? "draw_overlays_failed" : err);
    }

    return env->NewStringUTF(
        BuildResult(true, "", overlayCount, surfaceWidth, surfaceHeight).c_str());
}
