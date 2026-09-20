// gles_beauty_v2_compositor.cpp
// P5-BEAUTY-V2-GLES-RENDER: GlesBeautyV2Compositor implementation.
//
// Android-only real implementation is inside #if defined(__ANDROID__).
// Non-Android translation unit compiles to a safe stub that performs no GL
// calls and reports unavailable, matching GlesOverlayCompositor's style. The
// pure validation and ramp math (ValidateBeautyV2Parameters /
// ComputeBeautyV2ParametersFromIntensity) compiles on every platform.
//
// Every DrawBeautyV2 call: validates arguments (no GL call until validation
// passes), snapshots the GL state it will touch, forces a clean render
// state, creates two per-call intermediate FBOs/textures plus two per-call
// programs (blur, composite), runs Pass 1 (blur_h) -> Pass 2 (blur_v) ->
// Pass 3 (composite), deletes every object it created, and restores the
// snapshot on every path.

#include "gles_beauty_v2_compositor.h"

#if defined(__ANDROID__)
#include <EGL/egl.h>
#include <GLES3/gl3.h>
#endif

#include <algorithm>
#include <cmath>

namespace {

// kErrInvalidArgument documents the wire contract's "null output pointers"
// error string, but this library can never report it: when outError itself
// is null, there is nothing to write it into (the function just returns
// false). Kept for parity with the frozen error-string catalog; the
// diagnostic JNI harness defines its own copy for lane bookkeeping.
[[maybe_unused]] constexpr const char* kErrInvalidArgument = "gles_beauty_v2_invalid_argument";
constexpr const char* kErrInvalidDimensions  = "gles_beauty_v2_invalid_dimensions";
constexpr const char* kErrInvalidTexture     = "gles_beauty_v2_invalid_texture";
constexpr const char* kErrInvalidIntensity   = "gles_beauty_v2_invalid_intensity";
constexpr const char* kErrInvalidParameters  = "gles_beauty_v2_invalid_parameters";
[[maybe_unused]] constexpr const char* kErrUnavailableOnHost = "gles_beauty_v2_unavailable_on_host";
[[maybe_unused]] constexpr const char* kErrShaderCompileFailed = "gles_beauty_v2_shader_compile_failed";
[[maybe_unused]] constexpr const char* kErrProgramLinkFailed   = "gles_beauty_v2_program_link_failed";
[[maybe_unused]] constexpr const char* kErrFboIncomplete       = "gles_beauty_v2_fbo_incomplete";
[[maybe_unused]] constexpr const char* kErrDrawFailed          = "gles_beauty_v2_draw_failed";

void SetError(std::string* outError, const char* reason) {
    if (outError) *outError = reason;
}

bool ParamsFinite(const vanguard::render::GlesBeautyV2Parameters& p) {
    return std::isfinite(p.sigma) && std::isfinite(p.rangeSigma) &&
           std::isfinite(p.smoothStrength) && std::isfinite(p.sharpenStrength) &&
           std::isfinite(p.theta) && std::isfinite(p.detailDamping) &&
           std::isfinite(p.toneStrength) && std::isfinite(p.midtoneLift);
}

bool ParamsInRange(const vanguard::render::GlesBeautyV2Parameters& p) {
    return p.radius >= 1 && p.sigma >= 1.0f && p.rangeSigma >= 0.01f &&
           p.theta >= 0.001f && p.smoothStrength >= 0.0f && p.sharpenStrength >= 0.0f &&
           p.detailDamping >= 0.0f && p.toneStrength >= 0.0f && p.midtoneLift >= 0.0f;
}

} // namespace

namespace vanguard {
namespace render {

GlesBeautyV2Compositor::GlesBeautyV2Compositor() = default;
GlesBeautyV2Compositor::~GlesBeautyV2Compositor() { Release(); }

// ── Pure validation + ramp math (all platforms) ─────────────────────────────

bool ValidateBeautyV2Parameters(const GlesBeautyV2Parameters& params,
                                uint32_t width,
                                uint32_t height,
                                std::string* outError) {
    if (outError == nullptr) {
        return false;
    }
    if (width == 0 || height == 0) {
        SetError(outError, kErrInvalidDimensions);
        return false;
    }
    if (!ParamsFinite(params) || !ParamsInRange(params)) {
        SetError(outError, kErrInvalidParameters);
        return false;
    }
    outError->clear();
    return true;
}

bool ComputeBeautyV2ParametersFromIntensity(float intensity,
                                            uint32_t width,
                                            uint32_t height,
                                            GlesBeautyV2Parameters* outParams,
                                            std::string* outError) {
    if (outError == nullptr || outParams == nullptr) {
        return false;
    }
    if (width == 0 || height == 0) {
        SetError(outError, kErrInvalidDimensions);
        return false;
    }
    if (!std::isfinite(intensity) || intensity < 0.0f || intensity > 1.0f) {
        SetError(outError, kErrInvalidIntensity);
        return false;
    }

    const float t = intensity;
    // Spatial scale relative to the 1080p canonical reference (identical to
    // iOS BeautyV2FilterGroup.m processEnvelope:); S = 1.0 at 1080p/preview
    // and at this diagnostic's 64x64 proof surface.
    const float scale = std::fmax(
        1.0f, static_cast<float>(std::min(width, height)) / 1080.0f);

    const float baseRadius = 1.0f + t * 11.0f;
    int32_t radius = static_cast<int32_t>(std::lround(baseRadius * scale));
    // radiusCap = 64 on the intensity-ramp path (iOS: `_useIntensityRamp ?
    // 64 : 12`), which this function always represents.
    radius = std::max(1, std::min(radius, 64));

    float sigma = std::fmax((1.0f + t * 7.5f) * scale, 1.0f);
    float smoothStrength = std::min(std::max(t * 1.40f, 0.0f), 1.40f);
    float theta = std::fmax(0.02f + t * 0.03f, 0.001f);
    float sharpenStrength = std::min(std::max(0.35f - t * 0.20f, 0.0f), 0.50f);
    float rangeSigma = std::fmax(0.20f - t * 0.12f, 0.01f);
    float detailDamping = std::min(std::max(1.0f - t * 0.50f, 0.0f), 1.0f);
    float toneStrength = std::min(std::max(t * 0.30f, 0.0f), 1.0f);
    float midtoneLift = std::min(std::max(t * 0.06f, 0.0f), 0.15f);

    outParams->radius = radius;
    outParams->sigma = sigma;
    outParams->rangeSigma = rangeSigma;
    outParams->smoothStrength = smoothStrength;
    outParams->sharpenStrength = sharpenStrength;
    outParams->theta = theta;
    outParams->detailDamping = detailDamping;
    outParams->toneStrength = toneStrength;
    outParams->midtoneLift = midtoneLift;

    outError->clear();
    return true;
}

#if defined(__ANDROID__)
namespace {

// Loop bound cap shared by the blur fragment shader and (mandatorily,
// per readiness packet section 7) the diagnostic CPU reference; every
// preset radius produced by ComputeBeautyV2ParametersFromIntensity at this
// diagnostic's 64x64 scale (1, 7, 9, 12) is <= this cap.
constexpr int kMaxLoopRadius = 16;

const char* kVertexShaderSrc =
    "#version 300 es\n"
    "precision highp float;\n"
    "layout(location = 0) in vec2 aPosition;\n"
    "void main() {\n"
    "    gl_Position = vec4(aPosition, 0.0, 1.0);\n"
    "}\n";

// Shared horizontal/vertical bilateral blur kernel (uAxis selects the tap
// offset dimension); matches vanguard_beauty_blur_h / _blur_v exactly.
const char* kBlurFragmentShaderSrc =
    "#version 300 es\n"
    "precision highp float;\n"
    "precision highp sampler2D;\n"
    "precision highp int;\n"
    "uniform sampler2D uInputTex;\n"
    "uniform int uWidth;\n"
    "uniform int uHeight;\n"
    "uniform int uRadius;\n"
    "uniform int uAxis;\n" // 0 = horizontal, 1 = vertical
    "uniform float uSigma;\n"
    "uniform float uRangeSigma;\n"
    "out vec4 fragColor;\n"
    "const int kMaxLoopRadius = 16;\n"
    "void main() {\n"
    "    ivec2 coord = clamp(ivec2(gl_FragCoord.xy), ivec2(0), ivec2(uWidth - 1, uHeight - 1));\n"
    "    vec4 centreTexel = texelFetch(uInputTex, coord, 0);\n"
    "    vec3 centre = centreTexel.rgb;\n"
    "    float twoSig2 = 2.0 * uSigma * uSigma;\n"
    "    float twoRangeSig2 = 2.0 * uRangeSigma * uRangeSigma;\n"
    "    vec3 acc = vec3(0.0);\n"
    "    float wSum = 0.0;\n"
    "    for (int i = -kMaxLoopRadius; i <= kMaxLoopRadius; i++) {\n"
    "        if (i < -uRadius || i > uRadius) continue;\n"
    "        ivec2 tapCoord = coord;\n"
    "        if (uAxis == 0) {\n"
    "            tapCoord.x = clamp(coord.x + i, 0, uWidth - 1);\n"
    "        } else {\n"
    "            tapCoord.y = clamp(coord.y + i, 0, uHeight - 1);\n"
    "        }\n"
    "        vec3 tap = texelFetch(uInputTex, tapCoord, 0).rgb;\n"
    "        float spatial = exp(-float(i * i) / twoSig2);\n"
    "        vec3 delta = tap - centre;\n"
    "        float range = exp(-dot(delta, delta) / twoRangeSig2);\n"
    "        float w = spatial * range;\n"
    "        acc += tap * w;\n"
    "        wSum += w;\n"
    "    }\n"
    "    vec3 result = (wSum > 1e-6) ? (acc / wSum) : centre;\n"
    "    fragColor = vec4(result, centreTexel.a);\n"
    "}\n";

// Composite: fused highpass, adaptive smoothing gate, tone compression,
// midtone lift, detail add-back, alpha preservation. Matches
// vanguard_beauty_composite Phase 4B.6 math exactly (hasMask=0 route only;
// no FaceAware/mask/feature/enhance/polish layers).
const char* kCompositeFragmentShaderSrc =
    "#version 300 es\n"
    "precision highp float;\n"
    "precision highp sampler2D;\n"
    "precision highp int;\n"
    "uniform sampler2D uOrigTex;\n"
    "uniform sampler2D uMeanTex;\n"
    "uniform int uWidth;\n"
    "uniform int uHeight;\n"
    "uniform float uSmoothStrength;\n"
    "uniform float uSharpenStrength;\n"
    "uniform float uTheta;\n"
    "uniform float uDetailDamping;\n"
    "uniform float uToneStrength;\n"
    "uniform float uMidtoneLift;\n"
    "out vec4 fragColor;\n"
    "void main() {\n"
    "    ivec2 coord = clamp(ivec2(gl_FragCoord.xy), ivec2(0), ivec2(uWidth - 1, uHeight - 1));\n"
    "    vec4 orig = texelFetch(uOrigTex, coord, 0);\n"
    "    vec3 mean = texelFetch(uMeanTex, coord, 0).rgb;\n"
    "    vec3 highPass = clamp(orig.rgb - mean + vec3(0.5), 0.0, 1.0) - vec3(0.5);\n"
    "    float varLuma = (abs(highPass.r) + abs(highPass.g) + abs(highPass.b)) / 3.0;\n"
    "    float k = clamp((1.0 - varLuma / (varLuma + uTheta)) * uSmoothStrength, 0.0, 1.0);\n"
    "    vec3 smoothed = mix(orig.rgb, mean, k);\n"
    "    vec3 dampedDetail = highPass * uDetailDamping;\n"
    "    float luma = dot(smoothed, vec3(0.299, 0.587, 0.114));\n"
    "    float compressed = luma - uToneStrength * 0.08 * sin(luma * 3.14159265);\n"
    "    float toneScale = (luma > 0.001) ? (compressed / luma) : 1.0;\n"
    "    vec3 toned = clamp(smoothed * toneScale, 0.0, 1.0);\n"
    "    float lift = uMidtoneLift * 4.0 * luma * (1.0 - luma);\n"
    "    vec3 lifted = clamp(toned + vec3(lift), 0.0, 1.0);\n"
    "    vec3 beauty = clamp(lifted + uSharpenStrength * dampedDetail * 2.0, 0.0, 1.0);\n"
    "    fragColor = vec4(beauty, orig.a);\n"
    "}\n";

// Full-viewport triangle strip; the fragment shaders address texels purely
// through gl_FragCoord, so no texcoord attribute is needed.
const GLfloat kFullscreenQuad[] = {
    -1.0f, -1.0f,
     1.0f, -1.0f,
    -1.0f,  1.0f,
     1.0f,  1.0f,
};

GLuint CompileShader(GLenum type, const char* source) {
    GLuint shader = glCreateShader(type);
    if (shader == 0) return 0;
    glShaderSource(shader, 1, &source, nullptr);
    glCompileShader(shader);
    GLint compiled = GL_FALSE;
    glGetShaderiv(shader, GL_COMPILE_STATUS, &compiled);
    if (compiled != GL_TRUE) {
        glDeleteShader(shader);
        return 0;
    }
    return shader;
}

struct TemporaryProgram {
    GLuint vertexShader = 0;
    GLuint fragmentShader = 0;
    GLuint program = 0;

    bool Build(const char* fragmentSrc, std::string* outError) {
        vertexShader = CompileShader(GL_VERTEX_SHADER, kVertexShaderSrc);
        if (vertexShader == 0) {
            SetError(outError, kErrShaderCompileFailed);
            return false;
        }
        fragmentShader = CompileShader(GL_FRAGMENT_SHADER, fragmentSrc);
        if (fragmentShader == 0) {
            SetError(outError, kErrShaderCompileFailed);
            return false;
        }
        program = glCreateProgram();
        if (program == 0) {
            SetError(outError, kErrProgramLinkFailed);
            return false;
        }
        glAttachShader(program, vertexShader);
        glAttachShader(program, fragmentShader);
        glLinkProgram(program);
        GLint linked = GL_FALSE;
        glGetProgramiv(program, GL_LINK_STATUS, &linked);
        if (linked != GL_TRUE) {
            SetError(outError, kErrProgramLinkFailed);
            return false;
        }
        return true;
    }

    void Release() {
        if (program != 0) glDeleteProgram(program);
        if (fragmentShader != 0) glDeleteShader(fragmentShader);
        if (vertexShader != 0) glDeleteShader(vertexShader);
        program = fragmentShader = vertexShader = 0;
    }
};

// Full snapshot of every piece of GL state DrawBeautyV2 touches (readiness
// packet section 8, 14 categories).
struct GlStateSnapshot {
    GLint viewport[4] = {0, 0, 0, 0};
    GLint activeTexture = GL_TEXTURE0;
    GLint binding2DUnit0 = 0;
    GLint binding2DUnit1 = 0;
    GLint framebufferBinding = 0;
    GLint renderbufferBinding = 0;
    GLint program = 0;
    GLint vertexArrayBinding = 0;
    GLint arrayBufferBinding = 0;
    GLboolean blendEnabled = GL_FALSE;
    GLint blendEquationRgb = GL_FUNC_ADD;
    GLint blendEquationAlpha = GL_FUNC_ADD;
    GLint blendSrcRgb = GL_ONE;
    GLint blendDstRgb = GL_ZERO;
    GLint blendSrcAlpha = GL_ONE;
    GLint blendDstAlpha = GL_ZERO;
    GLboolean ditherEnabled = GL_TRUE;
    GLboolean scissorEnabled = GL_FALSE;
    GLint scissorBox[4] = {0, 0, 0, 0};
    GLboolean depthTestEnabled = GL_FALSE;
    GLboolean depthWriteMask = GL_TRUE;
    GLboolean stencilTestEnabled = GL_FALSE;
    GLboolean cullFaceEnabled = GL_FALSE;
    GLboolean colorMask[4] = {GL_TRUE, GL_TRUE, GL_TRUE, GL_TRUE};
    GLint packAlignment = 4;
    GLint unpackAlignment = 4;

    void Capture() {
        glGetIntegerv(GL_VIEWPORT, viewport);
        glGetIntegerv(GL_ACTIVE_TEXTURE, &activeTexture);
        glActiveTexture(GL_TEXTURE0);
        glGetIntegerv(GL_TEXTURE_BINDING_2D, &binding2DUnit0);
        glActiveTexture(GL_TEXTURE1);
        glGetIntegerv(GL_TEXTURE_BINDING_2D, &binding2DUnit1);
        glActiveTexture(static_cast<GLenum>(activeTexture));
        glGetIntegerv(GL_FRAMEBUFFER_BINDING, &framebufferBinding);
        glGetIntegerv(GL_RENDERBUFFER_BINDING, &renderbufferBinding);
        glGetIntegerv(GL_CURRENT_PROGRAM, &program);
        glGetIntegerv(GL_VERTEX_ARRAY_BINDING, &vertexArrayBinding);
        glGetIntegerv(GL_ARRAY_BUFFER_BINDING, &arrayBufferBinding);
        blendEnabled = glIsEnabled(GL_BLEND);
        glGetIntegerv(GL_BLEND_EQUATION_RGB, &blendEquationRgb);
        glGetIntegerv(GL_BLEND_EQUATION_ALPHA, &blendEquationAlpha);
        glGetIntegerv(GL_BLEND_SRC_RGB, &blendSrcRgb);
        glGetIntegerv(GL_BLEND_DST_RGB, &blendDstRgb);
        glGetIntegerv(GL_BLEND_SRC_ALPHA, &blendSrcAlpha);
        glGetIntegerv(GL_BLEND_DST_ALPHA, &blendDstAlpha);
        ditherEnabled = glIsEnabled(GL_DITHER);
        scissorEnabled = glIsEnabled(GL_SCISSOR_TEST);
        glGetIntegerv(GL_SCISSOR_BOX, scissorBox);
        depthTestEnabled = glIsEnabled(GL_DEPTH_TEST);
        glGetBooleanv(GL_DEPTH_WRITEMASK, &depthWriteMask);
        stencilTestEnabled = glIsEnabled(GL_STENCIL_TEST);
        cullFaceEnabled = glIsEnabled(GL_CULL_FACE);
        glGetBooleanv(GL_COLOR_WRITEMASK, colorMask);
        glGetIntegerv(GL_PACK_ALIGNMENT, &packAlignment);
        glGetIntegerv(GL_UNPACK_ALIGNMENT, &unpackAlignment);
    }

    void Restore() const {
        glActiveTexture(GL_TEXTURE1);
        glBindTexture(GL_TEXTURE_2D, static_cast<GLuint>(binding2DUnit1));
        glActiveTexture(GL_TEXTURE0);
        glBindTexture(GL_TEXTURE_2D, static_cast<GLuint>(binding2DUnit0));
        glActiveTexture(static_cast<GLenum>(activeTexture));
        glBindFramebuffer(GL_FRAMEBUFFER, static_cast<GLuint>(framebufferBinding));
        glBindRenderbuffer(GL_RENDERBUFFER, static_cast<GLuint>(renderbufferBinding));
        glUseProgram(static_cast<GLuint>(program));
        glBindVertexArray(static_cast<GLuint>(vertexArrayBinding));
        glBindBuffer(GL_ARRAY_BUFFER, static_cast<GLuint>(arrayBufferBinding));
        if (blendEnabled == GL_TRUE) glEnable(GL_BLEND); else glDisable(GL_BLEND);
        glBlendEquationSeparate(static_cast<GLenum>(blendEquationRgb),
                                static_cast<GLenum>(blendEquationAlpha));
        glBlendFuncSeparate(static_cast<GLenum>(blendSrcRgb), static_cast<GLenum>(blendDstRgb),
                            static_cast<GLenum>(blendSrcAlpha), static_cast<GLenum>(blendDstAlpha));
        if (ditherEnabled == GL_TRUE) glEnable(GL_DITHER); else glDisable(GL_DITHER);
        if (scissorEnabled == GL_TRUE) glEnable(GL_SCISSOR_TEST); else glDisable(GL_SCISSOR_TEST);
        glScissor(scissorBox[0], scissorBox[1], scissorBox[2], scissorBox[3]);
        if (depthTestEnabled == GL_TRUE) glEnable(GL_DEPTH_TEST); else glDisable(GL_DEPTH_TEST);
        glDepthMask(depthWriteMask);
        if (stencilTestEnabled == GL_TRUE) glEnable(GL_STENCIL_TEST); else glDisable(GL_STENCIL_TEST);
        if (cullFaceEnabled == GL_TRUE) glEnable(GL_CULL_FACE); else glDisable(GL_CULL_FACE);
        glColorMask(colorMask[0], colorMask[1], colorMask[2], colorMask[3]);
        glPixelStorei(GL_PACK_ALIGNMENT, packAlignment);
        glPixelStorei(GL_UNPACK_ALIGNMENT, unpackAlignment);
        glViewport(viewport[0], viewport[1], viewport[2], viewport[3]);
    }
};

GLuint CreateBeautyTexture(uint32_t width, uint32_t height) {
    GLuint texture = 0;
    glGenTextures(1, &texture);
    if (texture == 0) return 0;
    glBindTexture(GL_TEXTURE_2D, texture);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, static_cast<GLsizei>(width),
                static_cast<GLsizei>(height), 0, GL_RGBA, GL_UNSIGNED_BYTE, nullptr);
    glBindTexture(GL_TEXTURE_2D, 0);
    if (glGetError() != GL_NO_ERROR) {
        glDeleteTextures(1, &texture);
        return 0;
    }
    return texture;
}

// Creates an FBO with `texture` bound to COLOR_ATTACHMENT0 and leaves it
// bound (caller rebinds/unbinds as needed). Returns 0 (deleting any created
// FBO) if incomplete.
GLuint CreateBeautyFramebuffer(GLuint texture) {
    GLuint fbo = 0;
    glGenFramebuffers(1, &fbo);
    if (fbo == 0) return 0;
    glBindFramebuffer(GL_FRAMEBUFFER, fbo);
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, texture, 0);
    if (glCheckFramebufferStatus(GL_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE) {
        glBindFramebuffer(GL_FRAMEBUFFER, 0);
        glDeleteFramebuffers(1, &fbo);
        return 0;
    }
    return fbo;
}

void DrainGlErrors() {
    for (int i = 0; i < 16 && glGetError() != GL_NO_ERROR; ++i) {
    }
}

// True only when the current context reports OpenGL ES 3.0+ (GL_MAJOR_VERSION
// is an ES3 query; GL_INVALID_ENUM on an ES2 context signals unavailability).
bool CurrentContextIsGles3OrAbove() {
    DrainGlErrors();
    GLint major = 0;
    glGetIntegerv(GL_MAJOR_VERSION, &major);
    if (glGetError() != GL_NO_ERROR) {
        return false;
    }
    return major >= 3;
}

} // namespace
#endif // defined(__ANDROID__)

bool GlesBeautyV2Compositor::DrawBeautyV2(uint32_t inputTexture,
                                          uint32_t targetFbo,
                                          uint32_t width,
                                          uint32_t height,
                                          const GlesBeautyV2Parameters& params,
                                          std::string* outError) {
    // ── Fail-closed validation (evaluation order 1-5); zero GL calls until
    // every check passes.
    if (outError == nullptr) {
        return false;
    }
    outError->clear();
    if (width == 0 || height == 0) {
        SetError(outError, kErrInvalidDimensions);
        return false;
    }
    if (inputTexture == 0) {
        SetError(outError, kErrInvalidTexture);
        return false;
    }
    if (!ParamsFinite(params) || !ParamsInRange(params)) {
        SetError(outError, kErrInvalidParameters);
        return false;
    }

#if defined(__ANDROID__)
    if (!CurrentContextIsGles3OrAbove()) {
        SetError(outError, kErrUnavailableOnHost);
        return false;
    }

    // ── Snapshot GL state before any mutation. ──────────────────────────────
    GlStateSnapshot snapshot;
    snapshot.Capture();
    DrainGlErrors();

    // ── Clean render state for the three passes. ────────────────────────────
    glDisable(GL_BLEND);
    glDisable(GL_DITHER);
    glDisable(GL_SCISSOR_TEST);
    glDisable(GL_DEPTH_TEST);
    glDisable(GL_STENCIL_TEST);
    glDisable(GL_CULL_FACE);
    glColorMask(GL_TRUE, GL_TRUE, GL_TRUE, GL_TRUE);
    glPixelStorei(GL_PACK_ALIGNMENT, 1);
    glPixelStorei(GL_UNPACK_ALIGNMENT, 1);
    glViewport(0, 0, static_cast<GLsizei>(width), static_cast<GLsizei>(height));

    bool ok = true;
    std::string stageError;

    // ── Lazy shader compilation (once per compositor lifetime). ─────────────
    if (blurProgram_ == 0 && ok) {
        GLuint vs = CompileShader(GL_VERTEX_SHADER, kVertexShaderSrc);
        if (vs == 0) {
            ok = false;
            SetError(&stageError, kErrShaderCompileFailed);
        } else {
            GLuint fs = CompileShader(GL_FRAGMENT_SHADER, kBlurFragmentShaderSrc);
            if (fs == 0) {
                glDeleteShader(vs);
                ok = false;
                SetError(&stageError, kErrShaderCompileFailed);
            } else {
                GLuint prog = glCreateProgram();
                if (prog == 0) {
                    glDeleteShader(fs);
                    glDeleteShader(vs);
                    ok = false;
                    SetError(&stageError, kErrProgramLinkFailed);
                } else {
                    glAttachShader(prog, vs);
                    glAttachShader(prog, fs);
                    glLinkProgram(prog);
                    GLint linked = GL_FALSE;
                    glGetProgramiv(prog, GL_LINK_STATUS, &linked);
                    if (linked != GL_TRUE) {
                        glDeleteProgram(prog);
                        glDeleteShader(fs);
                        glDeleteShader(vs);
                        ok = false;
                        SetError(&stageError, kErrProgramLinkFailed);
                    } else {
                        blurVertexShader_ = vs;
                        blurFragmentShader_ = fs;
                        blurProgram_ = prog;
                    }
                }
            }
        }
    }

    if (compositeProgram_ == 0 && ok) {
        GLuint vs = CompileShader(GL_VERTEX_SHADER, kVertexShaderSrc);
        if (vs == 0) {
            ok = false;
            SetError(&stageError, kErrShaderCompileFailed);
        } else {
            GLuint fs = CompileShader(GL_FRAGMENT_SHADER, kCompositeFragmentShaderSrc);
            if (fs == 0) {
                glDeleteShader(vs);
                ok = false;
                SetError(&stageError, kErrShaderCompileFailed);
            } else {
                GLuint prog = glCreateProgram();
                if (prog == 0) {
                    glDeleteShader(fs);
                    glDeleteShader(vs);
                    ok = false;
                    SetError(&stageError, kErrProgramLinkFailed);
                } else {
                    glAttachShader(prog, vs);
                    glAttachShader(prog, fs);
                    glLinkProgram(prog);
                    GLint linked = GL_FALSE;
                    glGetProgramiv(prog, GL_LINK_STATUS, &linked);
                    if (linked != GL_TRUE) {
                        glDeleteProgram(prog);
                        glDeleteShader(fs);
                        glDeleteShader(vs);
                        ok = false;
                        SetError(&stageError, kErrProgramLinkFailed);
                    } else {
                        compositeVertexShader_ = vs;
                        compositeFragmentShader_ = fs;
                        compositeProgram_ = prog;
                    }
                }
            }
        }
    }

    // ── Lazy FBO/texture allocation (re-created on dimension change). ───────
    if (ok && (cachedWidth_ != width || cachedHeight_ != height)) {
        // Dimension change: delete old FBOs/textures if they exist.
        if (fboA_ != 0) { glDeleteFramebuffers(1, &fboA_); fboA_ = 0; }
        if (fboB_ != 0) { glDeleteFramebuffers(1, &fboB_); fboB_ = 0; }
        if (texA_ != 0) { glDeleteTextures(1, &texA_); texA_ = 0; }
        if (texB_ != 0) { glDeleteTextures(1, &texB_); texB_ = 0; }

        GLuint tA = CreateBeautyTexture(width, height);
        GLuint tB = CreateBeautyTexture(width, height);
        if (tA == 0 || tB == 0) {
            if (tA != 0) glDeleteTextures(1, &tA);
            if (tB != 0) glDeleteTextures(1, &tB);
            ok = false;
            SetError(&stageError, kErrDrawFailed);
        } else {
            GLuint fA = CreateBeautyFramebuffer(tA);
            if (fA == 0) {
                glDeleteTextures(1, &tA);
                glDeleteTextures(1, &tB);
                ok = false;
                SetError(&stageError, kErrFboIncomplete);
            } else {
                GLuint fB = CreateBeautyFramebuffer(tB);
                if (fB == 0) {
                    glDeleteFramebuffers(1, &fA);
                    glDeleteTextures(1, &tA);
                    glDeleteTextures(1, &tB);
                    ok = false;
                    SetError(&stageError, kErrFboIncomplete);
                } else {
                    texA_ = tA;
                    texB_ = tB;
                    fboA_ = fA;
                    fboB_ = fB;
                    cachedWidth_ = width;
                    cachedHeight_ = height;
                }
            }
        }
    }

    // ── Lazy VAO/VBO creation (once per compositor lifetime). ────────────────
    if (vao_ == 0 && ok) {
        GLuint vao = 0, vbo = 0;
        glGenVertexArrays(1, &vao);
        glGenBuffers(1, &vbo);
        if (vao == 0 || vbo == 0) {
            if (vbo != 0) glDeleteBuffers(1, &vbo);
            if (vao != 0) glDeleteVertexArrays(1, &vao);
            ok = false;
            SetError(&stageError, kErrDrawFailed);
        } else {
            glBindVertexArray(vao);
            glBindBuffer(GL_ARRAY_BUFFER, vbo);
            glBufferData(GL_ARRAY_BUFFER, sizeof(kFullscreenQuad), kFullscreenQuad, GL_STATIC_DRAW);
            glEnableVertexAttribArray(0);
            glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, 0, nullptr);
            if (glGetError() != GL_NO_ERROR) {
                glBindBuffer(GL_ARRAY_BUFFER, 0);
                glBindVertexArray(0);
                glDeleteBuffers(1, &vbo);
                glDeleteVertexArrays(1, &vao);
                ok = false;
                SetError(&stageError, kErrDrawFailed);
            } else {
                vao_ = vao;
                vbo_ = vbo;
            }
        }
    }

    // Bind cached VAO for the three render passes.
    if (ok) {
        glBindVertexArray(static_cast<GLuint>(vao_));
    }

    const GLint w = static_cast<GLint>(width);
    const GLint h = static_cast<GLint>(height);

    // ── Pass 1: blur_h — inputTexture -> fboA (texA). ───────────────────────
    if (ok) {
        glBindFramebuffer(GL_FRAMEBUFFER, static_cast<GLuint>(fboA_));
        glUseProgram(static_cast<GLuint>(blurProgram_));
        glActiveTexture(GL_TEXTURE0);
        glBindTexture(GL_TEXTURE_2D, inputTexture);
        glUniform1i(glGetUniformLocation(static_cast<GLuint>(blurProgram_), "uInputTex"), 0);
        glUniform1i(glGetUniformLocation(static_cast<GLuint>(blurProgram_), "uWidth"), w);
        glUniform1i(glGetUniformLocation(static_cast<GLuint>(blurProgram_), "uHeight"), h);
        glUniform1i(glGetUniformLocation(static_cast<GLuint>(blurProgram_), "uRadius"), params.radius);
        glUniform1i(glGetUniformLocation(static_cast<GLuint>(blurProgram_), "uAxis"), 0);
        glUniform1f(glGetUniformLocation(static_cast<GLuint>(blurProgram_), "uSigma"), params.sigma);
        glUniform1f(glGetUniformLocation(static_cast<GLuint>(blurProgram_), "uRangeSigma"), params.rangeSigma);
        glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
        if (glGetError() != GL_NO_ERROR) {
            ok = false;
            SetError(&stageError, kErrDrawFailed);
        }
    }

    // ── Pass 2: blur_v — texA -> fboB (texB). ───────────────────────────────
    if (ok) {
        glBindFramebuffer(GL_FRAMEBUFFER, static_cast<GLuint>(fboB_));
        glUseProgram(static_cast<GLuint>(blurProgram_));
        glActiveTexture(GL_TEXTURE0);
        glBindTexture(GL_TEXTURE_2D, static_cast<GLuint>(texA_));
        glUniform1i(glGetUniformLocation(static_cast<GLuint>(blurProgram_), "uInputTex"), 0);
        glUniform1i(glGetUniformLocation(static_cast<GLuint>(blurProgram_), "uWidth"), w);
        glUniform1i(glGetUniformLocation(static_cast<GLuint>(blurProgram_), "uHeight"), h);
        glUniform1i(glGetUniformLocation(static_cast<GLuint>(blurProgram_), "uRadius"), params.radius);
        glUniform1i(glGetUniformLocation(static_cast<GLuint>(blurProgram_), "uAxis"), 1);
        glUniform1f(glGetUniformLocation(static_cast<GLuint>(blurProgram_), "uSigma"), params.sigma);
        glUniform1f(glGetUniformLocation(static_cast<GLuint>(blurProgram_), "uRangeSigma"), params.rangeSigma);
        glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
        if (glGetError() != GL_NO_ERROR) {
            ok = false;
            SetError(&stageError, kErrDrawFailed);
        }
    }

    // ── Pass 3: composite — inputTexture + texB -> targetFbo. ───────────────
    if (ok) {
        glBindFramebuffer(GL_FRAMEBUFFER, static_cast<GLuint>(targetFbo));
        glUseProgram(static_cast<GLuint>(compositeProgram_));
        glActiveTexture(GL_TEXTURE0);
        glBindTexture(GL_TEXTURE_2D, inputTexture);
        glActiveTexture(GL_TEXTURE1);
        glBindTexture(GL_TEXTURE_2D, static_cast<GLuint>(texB_));
        glUniform1i(glGetUniformLocation(static_cast<GLuint>(compositeProgram_), "uOrigTex"), 0);
        glUniform1i(glGetUniformLocation(static_cast<GLuint>(compositeProgram_), "uMeanTex"), 1);
        glUniform1i(glGetUniformLocation(static_cast<GLuint>(compositeProgram_), "uWidth"), w);
        glUniform1i(glGetUniformLocation(static_cast<GLuint>(compositeProgram_), "uHeight"), h);
        glUniform1f(glGetUniformLocation(static_cast<GLuint>(compositeProgram_), "uSmoothStrength"), params.smoothStrength);
        glUniform1f(glGetUniformLocation(static_cast<GLuint>(compositeProgram_), "uSharpenStrength"), params.sharpenStrength);
        glUniform1f(glGetUniformLocation(static_cast<GLuint>(compositeProgram_), "uTheta"), params.theta);
        glUniform1f(glGetUniformLocation(static_cast<GLuint>(compositeProgram_), "uDetailDamping"), params.detailDamping);
        glUniform1f(glGetUniformLocation(static_cast<GLuint>(compositeProgram_), "uToneStrength"), params.toneStrength);
        glUniform1f(glGetUniformLocation(static_cast<GLuint>(compositeProgram_), "uMidtoneLift"), params.midtoneLift);
        glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
        if (glGetError() != GL_NO_ERROR) {
            ok = false;
            SetError(&stageError, kErrDrawFailed);
        }
    }

    // ── Unbind transient state; cached objects are NOT deleted. ──────────────
    glBindTexture(GL_TEXTURE_2D, 0);
    glActiveTexture(GL_TEXTURE0);
    glBindTexture(GL_TEXTURE_2D, 0);
    glBindBuffer(GL_ARRAY_BUFFER, 0);
    glBindVertexArray(0);
    glUseProgram(0);
    glBindFramebuffer(GL_FRAMEBUFFER, 0);
    DrainGlErrors();

    // On failure, release all cached state so the next call gets a clean
    // retry instead of reusing potentially-corrupt handles.
    if (!ok) {
        Release();
    }

    snapshot.Restore();

    if (!ok) {
        SetError(outError, stageError.empty() ? kErrDrawFailed : stageError.c_str());
        return false;
    }
    outError->clear();
    return true;
#else
    (void)inputTexture;
    (void)targetFbo;
    SetError(outError, kErrUnavailableOnHost);
    return false;
#endif
}

// ── Explicit GL resource release ────────────────────────────────────────────

void GlesBeautyV2Compositor::Release() {
#if defined(__ANDROID__)
    if (blurProgram_ != 0) {
        glDeleteProgram(static_cast<GLuint>(blurProgram_));
        blurProgram_ = 0;
    }
    if (blurFragmentShader_ != 0) {
        glDeleteShader(static_cast<GLuint>(blurFragmentShader_));
        blurFragmentShader_ = 0;
    }
    if (blurVertexShader_ != 0) {
        glDeleteShader(static_cast<GLuint>(blurVertexShader_));
        blurVertexShader_ = 0;
    }
    if (compositeProgram_ != 0) {
        glDeleteProgram(static_cast<GLuint>(compositeProgram_));
        compositeProgram_ = 0;
    }
    if (compositeFragmentShader_ != 0) {
        glDeleteShader(static_cast<GLuint>(compositeFragmentShader_));
        compositeFragmentShader_ = 0;
    }
    if (compositeVertexShader_ != 0) {
        glDeleteShader(static_cast<GLuint>(compositeVertexShader_));
        compositeVertexShader_ = 0;
    }
    if (fboA_ != 0) {
        GLuint fbo = static_cast<GLuint>(fboA_);
        glDeleteFramebuffers(1, &fbo);
        fboA_ = 0;
    }
    if (fboB_ != 0) {
        GLuint fbo = static_cast<GLuint>(fboB_);
        glDeleteFramebuffers(1, &fbo);
        fboB_ = 0;
    }
    if (texA_ != 0) {
        GLuint tex = static_cast<GLuint>(texA_);
        glDeleteTextures(1, &tex);
        texA_ = 0;
    }
    if (texB_ != 0) {
        GLuint tex = static_cast<GLuint>(texB_);
        glDeleteTextures(1, &tex);
        texB_ = 0;
    }
    if (vbo_ != 0) {
        GLuint buf = static_cast<GLuint>(vbo_);
        glDeleteBuffers(1, &buf);
        vbo_ = 0;
    }
    if (vao_ != 0) {
        GLuint arr = static_cast<GLuint>(vao_);
        glDeleteVertexArrays(1, &arr);
        vao_ = 0;
    }
    cachedWidth_ = 0;
    cachedHeight_ = 0;
#endif
}

} // namespace render
} // namespace vanguard

