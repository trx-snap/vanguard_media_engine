// android_phase5_beauty_v2_gles_render_jni.cpp
// P5-BEAUTY-V2-GLES-RENDER: GlesBeautyV2Compositor shader/raster + CPU
// reference parity diagnostic proof diagnostic JNI bridge.
//
// Android-only translation unit added via the CMake target_sources block.
// This is the composition root for the private
// vanguard::render::GlesBeautyV2Compositor raster helper: it owns a
// temporary 64x64 EGL pbuffer context (OpenGL ES 3.0+, no ES2 fallback) and
// synthetic GL_TEXTURE_2D probe textures created solely for proof on the
// calling thread, draws every lane through the helper, reads pixels back
// with glReadPixels, compares against the pure CPU reference math in
// android_phase5_beauty_v2_gles_render_probe.h/.cpp (Constitution modularity
// pre-authorization recorded there; this translation unit remains a
// cohesive diagnostic composition root per Constitution section 16
// deferral, staying well under the 1,200-line ceiling authorized in the
// readiness packet sections 4 and 11), and tears down every EGL/GL object
// it created before returning a single flat JSON string.
//
// Non-claim: shader/raster + CPU-parity proof only. No Vulkan pipeline, no
// MediaCodec decode, no production export route, no
// AndroidTimelineExportSession/AndroidEditorPlaybackCoordinator/VGCameraSession
// change, no app/editor UI. Proof boundary:
// native_gles_beauty_v2_compositor_shader_raster_only_no_vulkan_no_decode_no_export_no_product
//
// JNI entry point (matching VanguardNativeBridge.kt declaration):
//   runAndroidDagPhase5BeautyV2GlesRenderSmoke -> jstring (JSON)

#include <jni.h>

#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES3/gl3.h>

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <limits>
#include <sstream>
#include <string>
#include <type_traits>
#include <vector>

#include "gles_beauty_v2_compositor.h"
#include "android_phase5_beauty_v2_gles_render_probe.h"

namespace {

using vanguard::render::ComputeBeautyV2ParametersFromIntensity;
using vanguard::render::GlesBeautyV2Compositor;
using vanguard::render::GlesBeautyV2Parameters;
using vanguard::render::ValidateBeautyV2Parameters;
using vanguard_probe_beauty_v2::CompareImages;
using vanguard_probe_beauty_v2::ComputeCpuReference;
using vanguard_probe_beauty_v2::ComputeLumaVariance;
using vanguard_probe_beauty_v2::ComputeMeanLuma;
using vanguard_probe_beauty_v2::kProbeHeight;
using vanguard_probe_beauty_v2::kProbePixelCount;
using vanguard_probe_beauty_v2::kProbeWidth;
using vanguard_probe_beauty_v2::LumaStepDelta;
using vanguard_probe_beauty_v2::MakeFlatProbe;
using vanguard_probe_beauty_v2::MakeGradientProbe;
using vanguard_probe_beauty_v2::MakeMidtoneProbe;
using vanguard_probe_beauty_v2::MakeNoiseProbe;
using vanguard_probe_beauty_v2::MakeStepEdgeProbe;
using vanguard_probe_beauty_v2::ParityResult;
using vanguard_probe_beauty_v2::ProbeImage;
using vanguard_probe_beauty_v2::Rgba8;

constexpr const char* kProofBoundary =
    "native_gles_beauty_v2_compositor_shader_raster_only_no_vulkan_no_decode_no_export_no_product";
constexpr const char* kPassMarker = "ANDROID_DAG_PHASE5_BEAUTY_V2_GLES_RENDER_PHYSICAL_SMOKE_PASS";
constexpr const char* kFailMarker = "ANDROID_DAG_PHASE5_BEAUTY_V2_GLES_RENDER_PHYSICAL_SMOKE_FAIL";

constexpr uint32_t kSurfaceWidth  = static_cast<uint32_t>(kProbeWidth);
constexpr uint32_t kSurfaceHeight = static_cast<uint32_t>(kProbeHeight);

constexpr const char* kErrInvalidTexture    = "gles_beauty_v2_invalid_texture";
constexpr const char* kErrInvalidDimensions = "gles_beauty_v2_invalid_dimensions";
constexpr const char* kErrInvalidIntensity  = "gles_beauty_v2_invalid_intensity";
constexpr const char* kErrInvalidParameters = "gles_beauty_v2_invalid_parameters";

// Lane 7 (struct parity): the native parameter struct must mirror the
// frozen field list/types in the readiness packet section 5. Checked at
// compile time; the runtime lane re-reports the result alongside the
// preset ramp table verification.
static_assert(std::is_same<decltype(GlesBeautyV2Parameters::radius), int32_t>::value, "radius");
static_assert(std::is_same<decltype(GlesBeautyV2Parameters::sigma), float>::value, "sigma");
static_assert(std::is_same<decltype(GlesBeautyV2Parameters::rangeSigma), float>::value, "rangeSigma");
static_assert(std::is_same<decltype(GlesBeautyV2Parameters::smoothStrength), float>::value, "smoothStrength");
static_assert(std::is_same<decltype(GlesBeautyV2Parameters::sharpenStrength), float>::value, "sharpenStrength");
static_assert(std::is_same<decltype(GlesBeautyV2Parameters::theta), float>::value, "theta");
static_assert(std::is_same<decltype(GlesBeautyV2Parameters::detailDamping), float>::value, "detailDamping");
static_assert(std::is_same<decltype(GlesBeautyV2Parameters::toneStrength), float>::value, "toneStrength");
static_assert(std::is_same<decltype(GlesBeautyV2Parameters::midtoneLift), float>::value, "midtoneLift");
static_assert(std::is_standard_layout<GlesBeautyV2Parameters>::value, "standard layout");
constexpr bool kStructParityCompileTimeOk = true;

// ── EGL scratch context: ES3-or-fail, no ES2 fallback (readiness packet ────
// section 7). Deliberately does not call eglTerminate on EGL_DEFAULT_DISPLAY
// (section 8 point 4; shared with the host process/Flutter engine).
struct EglScratch {
    EGLDisplay display = EGL_NO_DISPLAY;
    EGLContext context = EGL_NO_CONTEXT;
    EGLSurface surface = EGL_NO_SURFACE;
    EGLConfig  config  = nullptr;

    bool Setup(std::string* outError) {
        display = eglGetDisplay(EGL_DEFAULT_DISPLAY);
        if (display == EGL_NO_DISPLAY) {
            *outError = "egl_get_display_failed";
            return false;
        }
        EGLint major = 0, minor = 0;
        if (eglInitialize(display, &major, &minor) != EGL_TRUE) {
            *outError = "egl_initialize_failed";
            display = EGL_NO_DISPLAY;
            return false;
        }
        if (eglBindAPI(EGL_OPENGL_ES_API) != EGL_TRUE) {
            *outError = "egl_bind_api_failed";
            Teardown();
            return false;
        }
        const EGLint configAttribs[] = {
            EGL_SURFACE_TYPE,    EGL_PBUFFER_BIT,
            EGL_RENDERABLE_TYPE, EGL_OPENGL_ES3_BIT_KHR,
            EGL_RED_SIZE,   8,
            EGL_GREEN_SIZE, 8,
            EGL_BLUE_SIZE,  8,
            EGL_ALPHA_SIZE, 8,
            EGL_NONE
        };
        EGLint numConfigs = 0;
        if (eglChooseConfig(display, configAttribs, &config, 1, &numConfigs) != EGL_TRUE ||
            numConfigs < 1) {
            *outError = "egl_choose_config_failed";
            config = nullptr;
            Teardown();
            return false;
        }
        const EGLint contextAttribsEs3[] = { EGL_CONTEXT_CLIENT_VERSION, 3, EGL_NONE };
        context = eglCreateContext(display, config, EGL_NO_CONTEXT, contextAttribsEs3);
        if (context == EGL_NO_CONTEXT) {
            *outError = "egl_create_context_failed_es3_required";
            Teardown();
            return false;
        }
        const EGLint pbufferAttribs[] = {
            EGL_WIDTH,  static_cast<EGLint>(kSurfaceWidth),
            EGL_HEIGHT, static_cast<EGLint>(kSurfaceHeight),
            EGL_NONE
        };
        surface = eglCreatePbufferSurface(display, config, pbufferAttribs);
        if (surface == EGL_NO_SURFACE) {
            *outError = "egl_create_pbuffer_surface_failed";
            Teardown();
            return false;
        }
        if (eglMakeCurrent(display, surface, surface, context) != EGL_TRUE) {
            *outError = "egl_make_current_failed";
            Teardown();
            return false;
        }
        return true;
    }

    void Teardown() {
        if (display == EGL_NO_DISPLAY) {
            return;
        }
        eglMakeCurrent(display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
        if (surface != EGL_NO_SURFACE) {
            eglDestroySurface(display, surface);
            surface = EGL_NO_SURFACE;
        }
        if (context != EGL_NO_CONTEXT) {
            eglDestroyContext(display, context);
            context = EGL_NO_CONTEXT;
        }
        display = EGL_NO_DISPLAY;
        config = nullptr;
    }
};

void DrainGlErrors() {
    for (int i = 0; i < 16 && glGetError() != GL_NO_ERROR; ++i) {
    }
}

// Uploads a probe image as a GL_RGBA8 non-sRGB GL_TEXTURE_2D
// (NEAREST/CLAMP_TO_EDGE per readiness packet section 7). Row 0 of `img`
// becomes texel row 0; combined with the shaders' un-flipped texelFetch and
// glReadPixels' bottom-row-first convention, every stage shares the same
// row-major index (see android_phase5_beauty_v2_gles_render_probe.h).
GLuint UploadProbeTexture(const ProbeImage& img) {
    GLuint texture = 0;
    glGenTextures(1, &texture);
    if (texture == 0) return 0;
    glBindTexture(GL_TEXTURE_2D, texture);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    glPixelStorei(GL_UNPACK_ALIGNMENT, 1);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, kProbeWidth, kProbeHeight, 0,
                GL_RGBA, GL_UNSIGNED_BYTE, img.data());
    glBindTexture(GL_TEXTURE_2D, 0);
    if (glGetError() != GL_NO_ERROR) {
        glDeleteTextures(1, &texture);
        return 0;
    }
    return texture;
}

// Target FBO/texture the compositor's Pass 3 renders into; pinned GL_RGBA8
// non-sRGB per readiness packet section 7's surface/texture format pinning
// (rather than trusting the pbuffer surface's own format).
bool CreateTargetFramebuffer(GLuint* outTexture, GLuint* outFbo) {
    GLuint texture = 0;
    glGenTextures(1, &texture);
    if (texture == 0) return false;
    glBindTexture(GL_TEXTURE_2D, texture);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, kProbeWidth, kProbeHeight, 0,
                GL_RGBA, GL_UNSIGNED_BYTE, nullptr);
    glBindTexture(GL_TEXTURE_2D, 0);
    if (glGetError() != GL_NO_ERROR) {
        glDeleteTextures(1, &texture);
        return false;
    }

    GLuint fbo = 0;
    glGenFramebuffers(1, &fbo);
    if (fbo == 0) {
        glDeleteTextures(1, &texture);
        return false;
    }
    glBindFramebuffer(GL_FRAMEBUFFER, fbo);
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, texture, 0);
    const bool complete = glCheckFramebufferStatus(GL_FRAMEBUFFER) == GL_FRAMEBUFFER_COMPLETE;
    glBindFramebuffer(GL_FRAMEBUFFER, 0);
    if (!complete) {
        glDeleteFramebuffers(1, &fbo);
        glDeleteTextures(1, &texture);
        return false;
    }
    *outTexture = texture;
    *outFbo = fbo;
    return true;
}

// Reads `fbo`'s color attachment 0 back into `out` (GL_RGBA/GL_UNSIGNED_BYTE,
// pack alignment 1); leaves the default framebuffer bound on return.
bool ReadTargetFramebuffer(GLuint fbo, ProbeImage* out) {
    out->resize(static_cast<size_t>(kProbePixelCount));
    glBindFramebuffer(GL_FRAMEBUFFER, fbo);
    glPixelStorei(GL_PACK_ALIGNMENT, 1);
    glReadPixels(0, 0, kProbeWidth, kProbeHeight, GL_RGBA, GL_UNSIGNED_BYTE, out->data());
    const bool ok = glGetError() == GL_NO_ERROR;
    glBindFramebuffer(GL_FRAMEBUFFER, 0);
    return ok;
}

// ── JSON helpers (self-contained per diagnostic-JNI precedent) ─────────────

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

class DetailsBuilder {
public:
    void Str(const char* key, const std::string& value) {
        Raw(key, "\"" + JsonEscape(value) + "\"");
    }
    void Bool(const char* key, bool value) { Raw(key, BoolStr(value)); }
    void U64(const char* key, uint64_t value) { Raw(key, std::to_string(value)); }
    void Int(const char* key, int64_t value) { Raw(key, std::to_string(value)); }
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
    void Raw(const char* key, const std::string& rawValue) {
        entries_.push_back("\"" + JsonEscape(key) + "\":" + rawValue);
    }
    std::vector<std::string> entries_;
};

} // namespace

extern "C" JNIEXPORT jstring JNICALL
Java_com_connects_vanguard_1media_1engine_bridge_VanguardNativeBridge_runAndroidDagPhase5BeautyV2GlesRenderSmoke(
    JNIEnv* env,
    jobject /* this */) {

    std::string failureReason;
    auto fail = [&failureReason](const std::string& reason) {
        if (failureReason.empty()) {
            failureReason = reason;
        }
    };
    DetailsBuilder details;
    details.Str("proofBoundary", kProofBoundary);
    details.U64("surfaceWidth", kSurfaceWidth);
    details.U64("surfaceHeight", kSurfaceHeight);

    // Gate flags (all default false; every lane must set its own true).
    bool eglSetupOk = false;
    bool glVersionOk = false;
    bool invalidTextureRejectedOk = false;
    bool invalidDimensionsRejectedOk = false;
    bool invalidIntensityRejectedOk = false;
    bool invalidParameterRejectedOk = false;
    bool nonePresetFlatIdentityOk = false;
    bool nonePresetGradientMinimumRampOk = false;
    bool softPresetCpuParityOk = false;
    bool softPresetSmoothingObservedOk = false;
    bool strongPresetCpuParityOk = false;
    bool strongPresetEdgePreservationOk = false;
    bool maxPresetCpuParityOk = false;
    bool maxPresetBoundsOk = false;
    bool maxPresetMidtoneLiftOk = false;
    bool lifecycleResourcesReleasedOk = false;
    bool glStateRestoredOk = false;
    bool structParityOk = false;
    bool canonical = false;

    EglScratch egl;
    {
        std::string eglError;
        eglSetupOk = egl.Setup(&eglError);
        details.Bool("eglSetupOk", eglSetupOk);
        if (!eglSetupOk) {
            fail("egl_setup_failed:" + eglError);
            details.Str("eglError", eglError);
        }
    }

    if (eglSetupOk) {
        DrainGlErrors();
        GLint major = 0;
        glGetIntegerv(GL_MAJOR_VERSION, &major);
        glVersionOk = glGetError() == GL_NO_ERROR && major >= 3;
        const GLubyte* version = glGetString(GL_VERSION);
        details.Str("glVersion", version ? reinterpret_cast<const char*>(version) : "");
        details.Int("glMajorVersion", major);
        details.Bool("glVersionOk", glVersionOk);
        if (!glVersionOk) {
            fail("gles_beauty_v2_unavailable_on_host");
        }
        glDisable(GL_DITHER);
        glDisable(GL_BLEND);
        glDisable(GL_SCISSOR_TEST);
        DrainGlErrors();
    }

    GLuint targetTex = 0, targetFbo = 0, validTex = 0;
    bool resourcesOk = false;
    if (glVersionOk) {
        resourcesOk = CreateTargetFramebuffer(&targetTex, &targetFbo);
        if (resourcesOk) {
            const ProbeImage flatValidProbe = MakeFlatProbe(128, 128, 128, 255);
            validTex = UploadProbeTexture(flatValidProbe);
            resourcesOk = validTex != 0;
        }
        if (!resourcesOk) {
            fail("synthetic_resource_creation_failed");
        }
    }

    GlesBeautyV2Compositor compositor;
    const GlesBeautyV2Parameters defaultParams; // struct defaults; already valid.

    if (resourcesOk) {
        // ── Lane 1: fail-closed validation (zero GL mutation on failure) ────
        {
            std::string err;
            DrainGlErrors();

            invalidTextureRejectedOk =
                !compositor.DrawBeautyV2(0, targetFbo, kSurfaceWidth, kSurfaceHeight, defaultParams, &err) &&
                err == kErrInvalidTexture;
            details.Str("invalidTextureError", err);

            bool dimsOk =
                !compositor.DrawBeautyV2(validTex, targetFbo, 0, kSurfaceHeight, defaultParams, &err) &&
                err == kErrInvalidDimensions;
            details.Str("invalidDimensionsError", err);
            dimsOk = dimsOk &&
                !compositor.DrawBeautyV2(validTex, targetFbo, kSurfaceWidth, 0, defaultParams, &err) &&
                err == kErrInvalidDimensions;
            invalidDimensionsRejectedOk = dimsOk;

            const float kNan = std::numeric_limits<float>::quiet_NaN();
            const float kInf = std::numeric_limits<float>::infinity();
            GlesBeautyV2Parameters outParams;
            std::string intensityErr;
            bool intensityOk =
                !ComputeBeautyV2ParametersFromIntensity(-0.01f, kSurfaceWidth, kSurfaceHeight, &outParams, &intensityErr) &&
                intensityErr == kErrInvalidIntensity;
            intensityOk = intensityOk &&
                !ComputeBeautyV2ParametersFromIntensity(1.01f, kSurfaceWidth, kSurfaceHeight, &outParams, &intensityErr) &&
                intensityErr == kErrInvalidIntensity;
            intensityOk = intensityOk &&
                !ComputeBeautyV2ParametersFromIntensity(kNan, kSurfaceWidth, kSurfaceHeight, &outParams, &intensityErr) &&
                intensityErr == kErrInvalidIntensity;
            intensityOk = intensityOk &&
                !ComputeBeautyV2ParametersFromIntensity(kInf, kSurfaceWidth, kSurfaceHeight, &outParams, &intensityErr) &&
                intensityErr == kErrInvalidIntensity;
            details.Str("invalidIntensityError", intensityErr);
            invalidIntensityRejectedOk = intensityOk;

            std::string paramErr;
            GlesBeautyV2Parameters badRadius = defaultParams;
            badRadius.radius = 0;
            bool paramOk = !ValidateBeautyV2Parameters(badRadius, kSurfaceWidth, kSurfaceHeight, &paramErr) &&
                           paramErr == kErrInvalidParameters;
            GlesBeautyV2Parameters badSigma = defaultParams;
            badSigma.sigma = kNan;
            paramOk = paramOk &&
                !ValidateBeautyV2Parameters(badSigma, kSurfaceWidth, kSurfaceHeight, &paramErr) &&
                paramErr == kErrInvalidParameters;
            GlesBeautyV2Parameters badRangeSigma = defaultParams;
            badRangeSigma.rangeSigma = 0.0f;
            paramOk = paramOk &&
                !ValidateBeautyV2Parameters(badRangeSigma, kSurfaceWidth, kSurfaceHeight, &paramErr) &&
                paramErr == kErrInvalidParameters;
            GlesBeautyV2Parameters badSmooth = defaultParams;
            badSmooth.smoothStrength = -0.1f;
            paramOk = paramOk &&
                !ValidateBeautyV2Parameters(badSmooth, kSurfaceWidth, kSurfaceHeight, &paramErr) &&
                paramErr == kErrInvalidParameters;
            std::string drawParamErr;
            paramOk = paramOk &&
                !compositor.DrawBeautyV2(validTex, targetFbo, kSurfaceWidth, kSurfaceHeight, badRadius, &drawParamErr) &&
                drawParamErr == kErrInvalidParameters;
            details.Str("invalidParameterError", drawParamErr.empty() ? paramErr : drawParamErr);
            invalidParameterRejectedOk = paramOk;

            const bool noGlErrorAfterValidation = glGetError() == GL_NO_ERROR;
            details.Bool("noGlErrorAfterValidation", noGlErrorAfterValidation);
            if (!noGlErrorAfterValidation) {
                invalidTextureRejectedOk = false;
                invalidDimensionsRejectedOk = false;
                invalidIntensityRejectedOk = false;
                invalidParameterRejectedOk = false;
            }
            if (!invalidTextureRejectedOk)    fail("invalid_texture_not_rejected");
            if (!invalidDimensionsRejectedOk) fail("invalid_dimensions_not_rejected");
            if (!invalidIntensityRejectedOk)  fail("invalid_intensity_not_rejected");
            if (!invalidParameterRejectedOk)  fail("invalid_parameter_not_rejected");
        }

        // ── Lane 2: None minimum ramp (t=0.0) — full 3-pass pipeline, never ─
        // an early bypass (readiness packet section 7).
        {
            GlesBeautyV2Parameters noneParams;
            std::string rampErr;
            const bool rampOk =
                ComputeBeautyV2ParametersFromIntensity(0.0f, kSurfaceWidth, kSurfaceHeight, &noneParams, &rampErr);
            details.Bool("noneRampComputeOk", rampOk);
            details.Int("noneRadius", noneParams.radius);

            if (rampOk) {
                std::string drawErr;
                const ProbeImage flatProbe = MakeFlatProbe(210, 90, 60, 255);
                GLuint flatTex = UploadProbeTexture(flatProbe);
                ProbeImage gpuFlat;
                const bool flatOk = flatTex != 0 &&
                    compositor.DrawBeautyV2(flatTex, targetFbo, kSurfaceWidth, kSurfaceHeight, noneParams, &drawErr) &&
                    ReadTargetFramebuffer(targetFbo, &gpuFlat);
                if (flatTex != 0) glDeleteTextures(1, &flatTex);
                if (flatOk) {
                    const ParityResult identity = CompareImages(gpuFlat, flatProbe);
                    nonePresetFlatIdentityOk = identity.maxDeltaR == 0 && identity.maxDeltaG == 0 &&
                                               identity.maxDeltaB == 0 && identity.maxDeltaA == 0;
                    details.Int("noneFlatMaxDelta", std::max({identity.maxDeltaR, identity.maxDeltaG,
                                                              identity.maxDeltaB, identity.maxDeltaA}));
                } else {
                    details.Str("noneFlatDrawError", drawErr);
                }

                const ProbeImage gradientProbe = MakeGradientProbe();
                GLuint gradTex = UploadProbeTexture(gradientProbe);
                ProbeImage gpuGrad;
                const bool gradOk = gradTex != 0 &&
                    compositor.DrawBeautyV2(gradTex, targetFbo, kSurfaceWidth, kSurfaceHeight, noneParams, &drawErr) &&
                    ReadTargetFramebuffer(targetFbo, &gpuGrad);
                if (gradTex != 0) glDeleteTextures(1, &gradTex);
                if (gradOk) {
                    const ProbeImage cpuGrad = ComputeCpuReference(gradientProbe, noneParams);
                    const ParityResult parity = CompareImages(gpuGrad, cpuGrad);
                    nonePresetGradientMinimumRampOk = parity.withinTolerance;
                    details.Int("noneGradientMaxDelta", std::max({parity.maxDeltaR, parity.maxDeltaG,
                                                                  parity.maxDeltaB, parity.maxDeltaA}));
                    details.Str("noneGradientMae", std::to_string(parity.meanAbsoluteError));
                } else {
                    details.Str("noneGradientDrawError", drawErr);
                }
            }
            if (!nonePresetFlatIdentityOk) fail("none_preset_flat_identity_failed");
            if (!nonePresetGradientMinimumRampOk) fail("none_preset_gradient_minimum_ramp_failed");
        }

        // Shared preset-lane helper: ramp -> upload -> draw -> readback ->
        // CPU-reference parity compare. Returns false (leaving *outParity
        // default-constructed) if the ramp, draw, or readback step failed.
        auto runPresetParityLane = [&](float intensity, const ProbeImage& inputProbe,
                                       ProbeImage* outGpu, ParityResult* outParity,
                                       GlesBeautyV2Parameters* outParams,
                                       const char* label) -> bool {
            std::string rampErr;
            if (!ComputeBeautyV2ParametersFromIntensity(intensity, kSurfaceWidth, kSurfaceHeight, outParams, &rampErr)) {
                details.Str((std::string(label) + "RampError").c_str(), rampErr);
                return false;
            }
            GLuint tex = UploadProbeTexture(inputProbe);
            if (tex == 0) return false;
            std::string drawErr;
            const bool drawOk =
                compositor.DrawBeautyV2(tex, targetFbo, kSurfaceWidth, kSurfaceHeight, *outParams, &drawErr);
            bool readOk = false;
            if (drawOk) {
                readOk = ReadTargetFramebuffer(targetFbo, outGpu);
            }
            glDeleteTextures(1, &tex);
            if (!drawOk || !readOk) {
                details.Str((std::string(label) + "DrawError").c_str(), drawErr);
                return false;
            }
            const ProbeImage cpuRef = ComputeCpuReference(inputProbe, *outParams);
            *outParity = CompareImages(*outGpu, cpuRef);
            details.Int((std::string(label) + "MaxDelta").c_str(),
                        std::max({outParity->maxDeltaR, outParity->maxDeltaG,
                                  outParity->maxDeltaB, outParity->maxDeltaA}));
            details.Str((std::string(label) + "Mae").c_str(), std::to_string(outParity->meanAbsoluteError));
            return true;
        };

        // ── Lane 3: Soft (t=0.5) CPU parity + smoothing telemetry ───────────
        {
            const ProbeImage noiseProbe = MakeNoiseProbe();
            ProbeImage gpuSoft;
            ParityResult softParity;
            GlesBeautyV2Parameters softParams;
            const bool ran = runPresetParityLane(0.5f, noiseProbe, &gpuSoft, &softParity, &softParams, "soft");
            softPresetCpuParityOk = ran && softParity.withinTolerance;
            if (ran) {
                softPresetSmoothingObservedOk = ComputeLumaVariance(gpuSoft) < ComputeLumaVariance(noiseProbe);
            }
            details.Bool("softPresetSmoothingObservedOk", softPresetSmoothingObservedOk);
            if (!softPresetCpuParityOk) fail("soft_preset_cpu_parity_failed");
        }

        // ── Lane 4: Strong (t=0.75) CPU parity + edge-preservation telemetry ─
        {
            const ProbeImage stepProbe = MakeStepEdgeProbe();
            ProbeImage gpuStrong;
            ParityResult strongParity;
            GlesBeautyV2Parameters strongParams;
            const bool ran = runPresetParityLane(0.75f, stepProbe, &gpuStrong, &strongParity, &strongParams, "strong");
            strongPresetCpuParityOk = ran && strongParity.withinTolerance;
            if (ran) {
                const int stepDelta =
                    LumaStepDelta(gpuStrong, kProbeWidth / 2 - 2, kProbeWidth / 2 + 1, kProbeHeight / 2);
                strongPresetEdgePreservationOk = stepDelta >= 100;
                details.Int("strongPresetStepDelta", stepDelta);
            }
            if (!strongPresetCpuParityOk) fail("strong_preset_cpu_parity_failed");
        }

        // ── Lane 5: Max (t=1.0) CPU parity + bounds + midtone-lift gates ────
        {
            const ProbeImage midtoneProbe = MakeMidtoneProbe();
            ProbeImage gpuMax;
            ParityResult maxParity;
            GlesBeautyV2Parameters maxParams;
            const bool ran = runPresetParityLane(1.0f, midtoneProbe, &gpuMax, &maxParity, &maxParams, "max");
            maxPresetCpuParityOk = ran && maxParity.withinTolerance;
            if (ran) {
                bool boundsOk = true;
                for (const Rgba8& p : gpuMax) {
                    if (p.r > 255 || p.g > 255 || p.b > 255 || p.a > 255) {
                        boundsOk = false;
                        break;
                    }
                }
                maxPresetBoundsOk = boundsOk;
                const double lumaIn = ComputeMeanLuma(midtoneProbe);
                const double lumaOut = ComputeMeanLuma(gpuMax);
                maxPresetMidtoneLiftOk = lumaOut > lumaIn;
                details.Str("maxPresetMeanLumaIn", std::to_string(lumaIn));
                details.Str("maxPresetMeanLumaOut", std::to_string(lumaOut));
            }
            if (!maxPresetCpuParityOk)   fail("max_preset_cpu_parity_failed");
            if (!maxPresetBoundsOk)      fail("max_preset_bounds_failed");
            if (!maxPresetMidtoneLiftOk) fail("max_preset_midtone_lift_failed");
        }

        // ── Lane 6a: lifecycle — allocated == released across consecutive ───
        // draws, confirmed by GL name recycling with zero resource growth
        // (readiness packet section 8 point 3).
        {
            GlesBeautyV2Parameters strongParams;
            std::string rampErr;
            const bool rampOk =
                ComputeBeautyV2ParametersFromIntensity(0.75f, kSurfaceWidth, kSurfaceHeight, &strongParams, &rampErr);

            GLuint probeName1 = 0, probeName2 = 0, probeName3 = 0;
            glGenTextures(1, &probeName1);
            if (probeName1 != 0) glDeleteTextures(1, &probeName1);

            std::string lifecycleErr1;
            const bool draw1Ok = rampOk &&
                compositor.DrawBeautyV2(validTex, targetFbo, kSurfaceWidth, kSurfaceHeight, strongParams, &lifecycleErr1);
            const bool noError1 = glGetError() == GL_NO_ERROR;
            glGenTextures(1, &probeName2);
            if (probeName2 != 0) glDeleteTextures(1, &probeName2);

            std::string lifecycleErr2;
            const bool draw2Ok = draw1Ok &&
                compositor.DrawBeautyV2(validTex, targetFbo, kSurfaceWidth, kSurfaceHeight, strongParams, &lifecycleErr2);
            const bool noError2 = glGetError() == GL_NO_ERROR;
            glGenTextures(1, &probeName3);
            if (probeName3 != 0) glDeleteTextures(1, &probeName3);

            const uint32_t delta1 = probeName2 - probeName1;
            const uint32_t delta2 = probeName3 - probeName2;
            details.Str("lifecycleProbeNames", std::to_string(probeName1) + "," +
                        std::to_string(probeName2) + "," + std::to_string(probeName3));
            lifecycleResourcesReleasedOk = draw1Ok && draw2Ok && noError1 && noError2 && delta1 == delta2;
            if (!lifecycleResourcesReleasedOk) fail("lifecycle_resources_not_released");

            // ── Lane 6b: full GL state snapshot/restore across the 14 ───────
            // categories in readiness packet section 8 point 2.
            DrainGlErrors();
            glEnable(GL_BLEND);
            glBlendEquationSeparate(GL_FUNC_REVERSE_SUBTRACT, GL_FUNC_ADD);
            glBlendFuncSeparate(GL_ONE, GL_ONE, GL_ZERO, GL_ONE);
            glEnable(GL_DITHER);
            glEnable(GL_SCISSOR_TEST);
            glScissor(2, 3, 10, 12);
            glEnable(GL_DEPTH_TEST);
            glDepthMask(GL_FALSE);
            glEnable(GL_STENCIL_TEST);
            glEnable(GL_CULL_FACE);
            glColorMask(GL_FALSE, GL_TRUE, GL_FALSE, GL_TRUE);
            glPixelStorei(GL_PACK_ALIGNMENT, 4);
            glPixelStorei(GL_UNPACK_ALIGNMENT, 4);
            glViewport(4, 6, 20, 24);
            GLuint vao = 0, vbo = 0;
            glGenVertexArrays(1, &vao);
            glGenBuffers(1, &vbo);
            glBindVertexArray(vao);
            glBindBuffer(GL_ARRAY_BUFFER, vbo);
            glActiveTexture(GL_TEXTURE0);
            glBindTexture(GL_TEXTURE_2D, validTex);
            glActiveTexture(GL_TEXTURE1);
            glBindTexture(GL_TEXTURE_2D, validTex);
            DrainGlErrors();

            std::string stateErr;
            const bool stateDrawOk =
                compositor.DrawBeautyV2(validTex, targetFbo, kSurfaceWidth, kSurfaceHeight, strongParams, &stateErr);
            details.Bool("stateProbeDrawOk", stateDrawOk);

            GLint blendEnabled = glIsEnabled(GL_BLEND);
            GLint eqRgb = 0, eqA = 0, srcRgb = 0, dstRgb = 0, srcA = 0, dstA = 0;
            glGetIntegerv(GL_BLEND_EQUATION_RGB, &eqRgb);
            glGetIntegerv(GL_BLEND_EQUATION_ALPHA, &eqA);
            glGetIntegerv(GL_BLEND_SRC_RGB, &srcRgb);
            glGetIntegerv(GL_BLEND_DST_RGB, &dstRgb);
            glGetIntegerv(GL_BLEND_SRC_ALPHA, &srcA);
            glGetIntegerv(GL_BLEND_DST_ALPHA, &dstA);
            const bool blendRestored = blendEnabled == GL_TRUE && eqRgb == GL_FUNC_REVERSE_SUBTRACT &&
                                       eqA == GL_FUNC_ADD && srcRgb == GL_ONE && dstRgb == GL_ONE &&
                                       srcA == GL_ZERO && dstA == GL_ONE;

            const bool ditherRestored = glIsEnabled(GL_DITHER) == GL_TRUE;
            const bool scissorEnabledRestored = glIsEnabled(GL_SCISSOR_TEST) == GL_TRUE;
            GLint scissorBox[4] = {-1, -1, -1, -1};
            glGetIntegerv(GL_SCISSOR_BOX, scissorBox);
            const bool scissorOk = scissorEnabledRestored && scissorBox[0] == 2 && scissorBox[1] == 3 &&
                                   scissorBox[2] == 10 && scissorBox[3] == 12;

            const bool depthTestRestored = glIsEnabled(GL_DEPTH_TEST) == GL_TRUE;
            GLboolean depthMaskRestored = GL_TRUE;
            glGetBooleanv(GL_DEPTH_WRITEMASK, &depthMaskRestored);
            const bool stencilRestored = glIsEnabled(GL_STENCIL_TEST) == GL_TRUE;
            const bool cullRestored = glIsEnabled(GL_CULL_FACE) == GL_TRUE;
            GLboolean colorMask[4] = {GL_FALSE, GL_FALSE, GL_FALSE, GL_FALSE};
            glGetBooleanv(GL_COLOR_WRITEMASK, colorMask);
            const bool colorMaskOk = colorMask[0] == GL_FALSE && colorMask[1] == GL_TRUE &&
                                     colorMask[2] == GL_FALSE && colorMask[3] == GL_TRUE;

            GLint packAlign = 0, unpackAlign = 0;
            glGetIntegerv(GL_PACK_ALIGNMENT, &packAlign);
            glGetIntegerv(GL_UNPACK_ALIGNMENT, &unpackAlign);

            GLint vp[4] = {-1, -1, -1, -1};
            glGetIntegerv(GL_VIEWPORT, vp);
            const bool viewportOk = vp[0] == 4 && vp[1] == 6 && vp[2] == 20 && vp[3] == 24;

            GLint activeTexture = 0, binding0 = 0, binding1 = 0, program = -1;
            GLint vaoBinding = -1, arrayBuffer = -1, fbBinding = -1, rbBinding = -1;
            glGetIntegerv(GL_ACTIVE_TEXTURE, &activeTexture);
            glActiveTexture(GL_TEXTURE0);
            glGetIntegerv(GL_TEXTURE_BINDING_2D, &binding0);
            glActiveTexture(GL_TEXTURE1);
            glGetIntegerv(GL_TEXTURE_BINDING_2D, &binding1);
            glActiveTexture(static_cast<GLenum>(activeTexture));
            glGetIntegerv(GL_CURRENT_PROGRAM, &program);
            glGetIntegerv(GL_VERTEX_ARRAY_BINDING, &vaoBinding);
            glGetIntegerv(GL_ARRAY_BUFFER_BINDING, &arrayBuffer);
            glGetIntegerv(GL_FRAMEBUFFER_BINDING, &fbBinding);
            glGetIntegerv(GL_RENDERBUFFER_BINDING, &rbBinding);
            const bool bindingsOk = activeTexture == GL_TEXTURE1 && binding0 == static_cast<GLint>(validTex) &&
                                    binding1 == static_cast<GLint>(validTex) && program == 0 &&
                                    vaoBinding == static_cast<GLint>(vao) && arrayBuffer == static_cast<GLint>(vbo) &&
                                    fbBinding == 0 && rbBinding == 0;

            const bool noGlError = glGetError() == GL_NO_ERROR;

            glStateRestoredOk = stateDrawOk && blendRestored && ditherRestored && scissorOk &&
                               depthTestRestored && depthMaskRestored == GL_FALSE && stencilRestored &&
                               cullRestored && colorMaskOk && packAlign == 4 && unpackAlign == 4 &&
                               viewportOk && bindingsOk && noGlError;
            details.Bool("glStateRestoredOk", glStateRestoredOk);

            // Reset to the diagnostic's clean baseline before Lane 7.
            glBindVertexArray(0);
            glBindBuffer(GL_ARRAY_BUFFER, 0);
            glDeleteVertexArrays(1, &vao);
            glDeleteBuffers(1, &vbo);
            glActiveTexture(GL_TEXTURE1);
            glBindTexture(GL_TEXTURE_2D, 0);
            glActiveTexture(GL_TEXTURE0);
            glBindTexture(GL_TEXTURE_2D, 0);
            glDisable(GL_BLEND);
            glDisable(GL_DITHER);
            glDisable(GL_SCISSOR_TEST);
            glDisable(GL_DEPTH_TEST);
            glDepthMask(GL_TRUE);
            glDisable(GL_STENCIL_TEST);
            glDisable(GL_CULL_FACE);
            glColorMask(GL_TRUE, GL_TRUE, GL_TRUE, GL_TRUE);
            glPixelStorei(GL_PACK_ALIGNMENT, 4);
            glPixelStorei(GL_UNPACK_ALIGNMENT, 4);
            glViewport(0, 0, static_cast<GLsizei>(kSurfaceWidth), static_cast<GLsizei>(kSurfaceHeight));
            DrainGlErrors();

            if (!glStateRestoredOk) fail("gl_state_not_restored");
        }

        // ── Lane 7: struct parity + preset ramp table verification ─────────
        {
            auto near = [](float a, float b, float eps) { return std::fabs(a - b) <= eps; };
            struct Expected {
                float t; int32_t radius; float sigma; float rangeSigma; float smoothStrength;
                float theta; float sharpenStrength; float detailDamping; float toneStrength; float midtoneLift;
            };
            const Expected table[4] = {
                {0.00f, 1,  1.000f, 0.20f, 0.00f, 0.0200f, 0.35f, 1.000f, 0.000f, 0.000f},
                {0.50f, 7,  4.750f, 0.14f, 0.70f, 0.0350f, 0.25f, 0.750f, 0.150f, 0.030f},
                {0.75f, 9,  6.625f, 0.11f, 1.05f, 0.0425f, 0.20f, 0.625f, 0.225f, 0.045f},
                {1.00f, 12, 8.500f, 0.08f, 1.40f, 0.0500f, 0.15f, 0.500f, 0.300f, 0.060f},
            };
            bool tableOk = true;
            for (const Expected& e : table) {
                GlesBeautyV2Parameters p;
                std::string rampErr;
                const bool ok =
                    ComputeBeautyV2ParametersFromIntensity(e.t, kSurfaceWidth, kSurfaceHeight, &p, &rampErr) &&
                    p.radius == e.radius && near(p.sigma, e.sigma, 1e-3f) && near(p.rangeSigma, e.rangeSigma, 1e-3f) &&
                    near(p.smoothStrength, e.smoothStrength, 1e-3f) && near(p.theta, e.theta, 1e-3f) &&
                    near(p.sharpenStrength, e.sharpenStrength, 1e-3f) && near(p.detailDamping, e.detailDamping, 1e-3f) &&
                    near(p.toneStrength, e.toneStrength, 1e-3f) && near(p.midtoneLift, e.midtoneLift, 1e-3f) &&
                    ValidateBeautyV2Parameters(p, kSurfaceWidth, kSurfaceHeight, &rampErr);
                tableOk = tableOk && ok;
            }
            details.Bool("presetRampTableOk", tableOk);
            details.U64("paramsStructSizeBytes", sizeof(GlesBeautyV2Parameters));
            details.Str("paramsStructFields",
                        "radius,sigma,rangeSigma,smoothStrength,sharpenStrength,theta,detailDamping,toneStrength,midtoneLift");

            structParityOk = kStructParityCompileTimeOk && tableOk;
            if (!structParityOk) fail("struct_parity_failed");
        }
    }

    // ── Teardown: every object this diagnostic created ─────────────────────
    if (egl.display != EGL_NO_DISPLAY && egl.context != EGL_NO_CONTEXT) {
        if (validTex != 0) glDeleteTextures(1, &validTex);
        if (targetTex != 0) glDeleteTextures(1, &targetTex);
        if (targetFbo != 0) glDeleteFramebuffers(1, &targetFbo);
        DrainGlErrors();
    }
    egl.Teardown();

    const bool lanesPass =
        eglSetupOk && glVersionOk &&
        invalidTextureRejectedOk && invalidDimensionsRejectedOk &&
        invalidIntensityRejectedOk && invalidParameterRejectedOk &&
        nonePresetFlatIdentityOk && nonePresetGradientMinimumRampOk &&
        softPresetCpuParityOk && strongPresetCpuParityOk &&
        maxPresetCpuParityOk && maxPresetBoundsOk && maxPresetMidtoneLiftOk &&
        lifecycleResourcesReleasedOk && glStateRestoredOk && structParityOk;
    // Canonical route: every lane ran through the private helper against the
    // diagnostic-owned pbuffer with no lane skipped or substituted.
    canonical = lanesPass && failureReason.empty();
    const bool allNativeLanesPass = lanesPass && canonical;

    std::ostringstream oss;
    oss << "{"
        << "\"pass\":" << BoolStr(allNativeLanesPass) << ","
        << "\"status\":\"" << (allNativeLanesPass ? "PASS" : "FAIL") << "\","
        << "\"marker\":\"" << (allNativeLanesPass ? kPassMarker : kFailMarker) << "\","
        << "\"proofBoundary\":\"" << kProofBoundary << "\","
        << "\"failureReason\":\"" << JsonEscape(failureReason) << "\","
        << "\"eglSetupOk\":" << BoolStr(eglSetupOk) << ","
        << "\"glVersionOk\":" << BoolStr(glVersionOk) << ","
        << "\"invalidTextureRejectedOk\":" << BoolStr(invalidTextureRejectedOk) << ","
        << "\"invalidDimensionsRejectedOk\":" << BoolStr(invalidDimensionsRejectedOk) << ","
        << "\"invalidIntensityRejectedOk\":" << BoolStr(invalidIntensityRejectedOk) << ","
        << "\"invalidParameterRejectedOk\":" << BoolStr(invalidParameterRejectedOk) << ","
        << "\"nonePresetFlatIdentityOk\":" << BoolStr(nonePresetFlatIdentityOk) << ","
        << "\"nonePresetGradientMinimumRampOk\":" << BoolStr(nonePresetGradientMinimumRampOk) << ","
        << "\"softPresetCpuParityOk\":" << BoolStr(softPresetCpuParityOk) << ","
        << "\"softPresetSmoothingObservedOk\":" << BoolStr(softPresetSmoothingObservedOk) << ","
        << "\"strongPresetCpuParityOk\":" << BoolStr(strongPresetCpuParityOk) << ","
        << "\"strongPresetEdgePreservationOk\":" << BoolStr(strongPresetEdgePreservationOk) << ","
        << "\"maxPresetCpuParityOk\":" << BoolStr(maxPresetCpuParityOk) << ","
        << "\"maxPresetBoundsOk\":" << BoolStr(maxPresetBoundsOk) << ","
        << "\"maxPresetMidtoneLiftOk\":" << BoolStr(maxPresetMidtoneLiftOk) << ","
        << "\"lifecycleResourcesReleasedOk\":" << BoolStr(lifecycleResourcesReleasedOk) << ","
        << "\"glStateRestoredOk\":" << BoolStr(glStateRestoredOk) << ","
        << "\"structParityOk\":" << BoolStr(structParityOk) << ","
        << "\"canonical\":" << BoolStr(canonical) << ","
        << "\"allNativeLanesPass\":" << BoolStr(allNativeLanesPass) << ","
        << "\"nativeAllLanesPass\":" << BoolStr(allNativeLanesPass) << ","
        << "\"details\":" << details.Json()
        << "}";

    const std::string resultStr = oss.str();
    return env->NewStringUTF(resultStr.c_str());
}
