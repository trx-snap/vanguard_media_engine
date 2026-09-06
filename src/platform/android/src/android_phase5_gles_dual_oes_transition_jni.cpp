// android_phase5_gles_dual_oes_transition_jni.cpp
// P5-GLES-EXPORT-DUAL-OES-PRERESOLVE-TRANSITION-READINESS: diagnostic-only
// native seam proving that two textures already populated with real decoded
// content (each already updateTexImage()'d and, per the strengthened Kotlin
// harness, pre-resolved from its own SurfaceTexture-backed
// GL_TEXTURE_EXTERNAL_OES source into a canvas-sized GL_TEXTURE_2D raster
// with the SurfaceTexture transform matrix applied) can be composed by the
// private vanguard::render::GlesTimelineTransitionCompositor::drawTransition
// helper at a fixed crossfade midpoint (progress 0.5, blendWeightFrom ==
// blendWeightTo == 0.5, identity crops/viewports). GL_TEXTURE_2D and
// GL_TEXTURE_EXTERNAL_OES are independently accepted for fromTextureTarget/
// toTextureTarget (matching the compositor's own contract), so this seam
// stays usable both by the pre-resolved-2D harness above and by any other
// caller that still hands it raw OES textures directly.
//
// This translation unit creates and destroys NOTHING EGL/SurfaceTexture/
// MediaCodec-related: no EGL context, no EGL surface, no Java Surface, no
// SurfaceTexture, no MediaCodec. It only validates the caller-supplied
// scalar arguments, builds the fixed-midpoint transition geometry, forwards
// it to the private compositor helper (which draws into the already-current
// EGL surface and restores GL state per its own contract), then reads back a
// small pixel sample and re-verifies GL state itself before returning.
//
// Non-claims: diagnostic proof only. No production export route; no
// AndroidTimelineVideoEncoder.kt / AndroidTimelineExportSession.kt /
// AndroidExportRenderBackendSelector.kt change. GlesTimelineTransitionCompositor
// itself is untouched.
//
// JNI entry point (matching VanguardNativeBridge.kt declaration):
//   drawAndroidDagPhase5GlesDualOesTransition -> jstring (JSON)

#include <jni.h>

#include <GLES2/gl2.h>
#include <GLES2/gl2ext.h>

#include <cmath>
#include <cstdint>
#include <cstdio>
#include <string>
#include <vector>

#include "gles_timeline_transition_compositor.h"

namespace {

using vanguard::render::GlesTimelineTransitionCompositor;
using vanguard::render::GlesTimelineTransitionGeometry;

constexpr const char* kProofBoundary =
    "diagnostic_dual_texture_target_2d_or_oes_to_gles_transition_compositor_no_export";
constexpr const char* kPassMarker =
    "ANDROID_DAG_PHASE5_GLES_DUAL_OES_TRANSITION_PHYSICAL_SMOKE_PASS";
constexpr const char* kFailMarker =
    "ANDROID_DAG_PHASE5_GLES_DUAL_OES_TRANSITION_PHYSICAL_SMOKE_FAIL";

constexpr uint32_t kTargetOes = 0x8D65;  // GL_TEXTURE_EXTERNAL_OES
constexpr uint32_t kTarget2d = 0x0DE1;   // GL_TEXTURE_2D
constexpr int kColorTolerance = 8;

bool IsSupportedTextureTarget(uint32_t target) {
    return target == kTargetOes || target == kTarget2d;
}

struct Rgb {
    uint8_t r;
    uint8_t g;
    uint8_t b;
};

constexpr Rgb kSentinel = {40, 40, 40};  // must never survive a full-canvas mix draw

// ── Small helpers (deliberately duplicated per-TU; see sibling diagnostic
//    JNI translation units for the same pattern) ─────────────────────────────

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

const char* BoolStr(bool v) { return v ? "true" : "false"; }

std::string DoubleStr(double v) {
    if (!std::isfinite(v)) return "null";
    char buf[64];
    std::snprintf(buf, sizeof(buf), "%.9g", v);
    return buf;
}

class JsonObjectBuilder {
public:
    void Str(const std::string& key, const std::string& value) {
        Raw(key, "\"" + JsonEscape(value) + "\"");
    }
    void Bool(const std::string& key, bool value) { Raw(key, BoolStr(value)); }
    void I64(const std::string& key, int64_t value) { Raw(key, std::to_string(value)); }
    void Dbl(const std::string& key, double value) { Raw(key, DoubleStr(value)); }
    void Raw(const std::string& key, const std::string& rawValue) {
        entries_.push_back("\"" + JsonEscape(key) + "\":" + rawValue);
    }
    std::string Json() const {
        std::string out = "{";
        for (size_t i = 0; i < entries_.size(); ++i) {
            if (i != 0) out += ",";
            out += entries_[i];
        }
        out += "}";
        return out;
    }

private:
    std::vector<std::string> entries_;
};

void DrainGlErrors() {
    for (int i = 0; i < 16 && glGetError() != GL_NO_ERROR; ++i) {
    }
}

void ClearSentinel(GLsizei width, GLsizei height) {
    glViewport(0, 0, width, height);
    glClearColor(kSentinel.r / 255.0f, kSentinel.g / 255.0f, kSentinel.b / 255.0f, 1.0f);
    glClear(GL_COLOR_BUFFER_BIT);
}

// Reads exactly one small RGBA pixel from the currently-bound read
// framebuffer. Returns false (leaving `outPixel` untouched) on any GL error.
bool ReadOnePixel(GLint x, GLint y, uint8_t outPixel[4]) {
    glReadPixels(x, y, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, outPixel);
    return glGetError() == GL_NO_ERROR;
}

bool NearSentinel(const uint8_t* p) {
    return std::abs(static_cast<int>(p[0]) - kSentinel.r) <= kColorTolerance &&
           std::abs(static_cast<int>(p[1]) - kSentinel.g) <= kColorTolerance &&
           std::abs(static_cast<int>(p[2]) - kSentinel.b) <= kColorTolerance;
}

bool IsBlack(const uint8_t* p) { return p[0] == 0 && p[1] == 0 && p[2] == 0; }

std::string RgbaString(const uint8_t* p) {
    char buf[32];
    std::snprintf(buf, sizeof(buf), "%u,%u,%u,%u", p[0], p[1], p[2], p[3]);
    return buf;
}

}  // namespace

extern "C" JNIEXPORT jstring JNICALL
Java_com_connects_vanguard_1media_1engine_bridge_VanguardNativeBridge_drawAndroidDagPhase5GlesDualOesTransition(
    JNIEnv* env,
    jobject /* this */,
    jint fromTextureId,
    jint fromTextureTarget,
    jint toTextureId,
    jint toTextureTarget,
    jint surfaceWidth,
    jint surfaceHeight,
    jdouble progress,
    jlong fromPtsUs,
    jlong toPtsUs) {

    std::string failureReason;
    auto fail = [&failureReason](const std::string& reason) {
        if (failureReason.empty()) {
            failureReason = reason;
        }
    };

    JsonObjectBuilder details;
    details.Str("proofBoundary", kProofBoundary);
    details.I64("surfaceWidth", surfaceWidth);
    details.I64("surfaceHeight", surfaceHeight);
    details.I64("colorTolerance", kColorTolerance);
    details.I64("fromPtsUs", fromPtsUs);
    details.I64("toPtsUs", toPtsUs);
    details.Dbl("progress", progress);
    details.I64("textureTargetFrom", fromTextureTarget);
    details.I64("textureTargetTo", toTextureTarget);

    bool argumentValidationOk = false;
    bool nativeTransitionDrawOk = false;
    bool pixelProofOk = false;
    bool stateRestoredOk = false;

    // ── Argument validation (no GL call before this passes) ────────────────
    {
        std::string argError;
        if (fromTextureId <= 0 || toTextureId <= 0) {
            argError = "invalid_texture";
        } else if (surfaceWidth <= 0 || surfaceHeight <= 0) {
            argError = "invalid_dimensions";
        } else if (!IsSupportedTextureTarget(static_cast<uint32_t>(fromTextureTarget)) ||
                   !IsSupportedTextureTarget(static_cast<uint32_t>(toTextureTarget))) {
            argError = "unsupported_texture_target";
        } else if (!std::isfinite(static_cast<double>(progress)) || progress < 0.0 || progress > 1.0) {
            argError = "invalid_progress";
        }
        argumentValidationOk = argError.empty();
        if (!argumentValidationOk) {
            fail("gles_dual_oes_transition_" + argError);
            details.Str("argumentError", argError);
        }
    }

    double blendWeightFrom = 1.0;
    double blendWeightTo = 0.0;

    if (argumentValidationOk) {
        DrainGlErrors();
        ClearSentinel(surfaceWidth, surfaceHeight);

        blendWeightFrom = 1.0 - static_cast<double>(progress);
        blendWeightTo = static_cast<double>(progress);
        GlesTimelineTransitionGeometry geometry;
        geometry.progress = static_cast<double>(progress);
        geometry.blendWeightFrom = blendWeightFrom;
        geometry.blendWeightTo = blendWeightTo;
        // fromViewport/toViewport/fromCrop/toCrop stay at their identity
        // defaults (x=0,y=0,width=1,height=1) -- the full-canvas mix draw
        // this diagnostic exercises requires exactly that.

        GlesTimelineTransitionCompositor compositor;
        std::string drawErr;
        nativeTransitionDrawOk = compositor.drawTransition(
            static_cast<uint32_t>(fromTextureId), static_cast<uint32_t>(fromTextureTarget),
            static_cast<uint32_t>(toTextureId), static_cast<uint32_t>(toTextureTarget),
            static_cast<uint32_t>(surfaceWidth), static_cast<uint32_t>(surfaceHeight),
            geometry, &drawErr);
        details.Dbl("blendWeightFrom", blendWeightFrom);
        details.Dbl("blendWeightTo", blendWeightTo);
        if (!drawErr.empty()) details.Str("drawError", drawErr);
        if (!nativeTransitionDrawOk) {
            fail("native_transition_draw_failed:" + drawErr);
        }

        if (nativeTransitionDrawOk) {
            // ── Pixel proof: a handful of individual reads, not a full
            //    surface readback -- this is a "small pixel sample". ────────
            struct Point { const char* name; GLint x; GLint y; };
            const Point points[] = {
                {"probeCenter", surfaceWidth / 2, surfaceHeight / 2},
                {"probeTl", surfaceWidth / 4, 3 * surfaceHeight / 4},
                {"probeTr", 3 * surfaceWidth / 4, 3 * surfaceHeight / 4},
                {"probeBl", surfaceWidth / 4, surfaceHeight / 4},
                {"probeBr", 3 * surfaceWidth / 4, surfaceHeight / 4},
            };
            // Black is legitimate decoded content (e.g. a dark source
            // frame), so we don't require every sample to be non-black --
            // only that every read succeeded, at least one sample escaped
            // the sentinel clear color (proving a real draw happened), and
            // at least one sample is non-black (proving it isn't a
            // degenerate all-black composite).
            bool allReadsOk = true;
            bool anyNonSentinel = false;
            bool anyNonBlack = false;
            for (const Point& pt : points) {
                uint8_t pixel[4] = {0, 0, 0, 0};
                const bool readOk = ReadOnePixel(pt.x, pt.y, pixel);
                allReadsOk = allReadsOk && readOk;
                if (readOk) {
                    details.Str(pt.name, RgbaString(pixel));
                    if (!NearSentinel(pixel)) anyNonSentinel = true;
                    if (!IsBlack(pixel)) anyNonBlack = true;
                }
            }
            pixelProofOk = allReadsOk && anyNonSentinel && anyNonBlack;
            details.Bool("pixelReadsOk", allReadsOk);
            details.Bool("anyNonSentinelOk", anyNonSentinel);
            details.Bool("anyNonBlackOk", anyNonBlack);
            if (!pixelProofOk) {
                std::string pixelFailReason;
                if (!allReadsOk) {
                    pixelFailReason = "read_failed";
                } else if (!anyNonSentinel) {
                    pixelFailReason = "all_pixels_near_sentinel";
                } else {
                    pixelFailReason = "all_pixels_black";
                }
                fail("pixel_proof_failed:" + pixelFailReason);
            }
        }

        // ── GL state re-verification (compositor contract): viewport back to
        //    (0,0,surfaceWidth,surfaceHeight), program/array-buffer unbound,
        //    both texture units' 2D and external-OES bindings unbound, no
        //    pending GL error. ────────────────────────────────────────────
        GLint viewport[4] = {-1, -1, -1, -1};
        glGetIntegerv(GL_VIEWPORT, viewport);
        const bool viewportOk = viewport[0] == 0 && viewport[1] == 0 &&
                                viewport[2] == surfaceWidth && viewport[3] == surfaceHeight;

        GLint program = -1;
        glGetIntegerv(GL_CURRENT_PROGRAM, &program);
        GLint arrayBuffer = -1;
        glGetIntegerv(GL_ARRAY_BUFFER_BINDING, &arrayBuffer);
        GLint activeTexture = -1;
        glGetIntegerv(GL_ACTIVE_TEXTURE, &activeTexture);

        glActiveTexture(GL_TEXTURE0);
        GLint oesBinding0 = -1;
        glGetIntegerv(GL_TEXTURE_BINDING_EXTERNAL_OES, &oesBinding0);
        GLint tex2dBinding0 = -1;
        glGetIntegerv(GL_TEXTURE_BINDING_2D, &tex2dBinding0);
        glActiveTexture(GL_TEXTURE1);
        GLint oesBinding1 = -1;
        glGetIntegerv(GL_TEXTURE_BINDING_EXTERNAL_OES, &oesBinding1);
        GLint tex2dBinding1 = -1;
        glGetIntegerv(GL_TEXTURE_BINDING_2D, &tex2dBinding1);
        glActiveTexture(GL_TEXTURE0);

        const bool noPendingGlError = glGetError() == GL_NO_ERROR;

        stateRestoredOk = nativeTransitionDrawOk && viewportOk &&
                          program == 0 && arrayBuffer == 0 &&
                          activeTexture == GL_TEXTURE0 &&
                          oesBinding0 == 0 && tex2dBinding0 == 0 &&
                          oesBinding1 == 0 && tex2dBinding1 == 0 &&
                          noPendingGlError;

        details.Bool("viewportRestoredOk", viewportOk);
        details.I64("currentProgramAfterDraw", program);
        details.I64("arrayBufferBindingAfterDraw", arrayBuffer);
        details.I64("textureBindingExternalOesUnit0", oesBinding0);
        details.I64("textureBinding2dUnit0", tex2dBinding0);
        details.I64("textureBindingExternalOesUnit1", oesBinding1);
        details.I64("textureBinding2dUnit1", tex2dBinding1);
        details.Bool("noPendingGlErrorAfterDraw", noPendingGlError);
        if (nativeTransitionDrawOk && !stateRestoredOk) {
            fail("gl_state_not_restored");
        }
    }

    const bool allNativeLanesPass =
        argumentValidationOk && nativeTransitionDrawOk && pixelProofOk && stateRestoredOk;

    JsonObjectBuilder root;
    root.Bool("pass", allNativeLanesPass);
    root.Str("status", allNativeLanesPass ? "PASS" : "FAIL");
    root.Str("marker", allNativeLanesPass ? kPassMarker : kFailMarker);
    root.Str("proofBoundary", kProofBoundary);
    root.Str("failureReason", failureReason);
    root.Bool("argumentValidationOk", argumentValidationOk);
    root.Bool("nativeTransitionDrawOk", nativeTransitionDrawOk);
    root.Bool("pixelProofOk", pixelProofOk);
    root.Bool("stateRestoredOk", stateRestoredOk);
    root.Bool("allNativeLanesPass", allNativeLanesPass);
    root.Bool("nativeAllLanesPass", allNativeLanesPass);
    root.Raw("details", details.Json());

    const std::string resultStr = root.Json();
    return env->NewStringUTF(resultStr.c_str());
}
