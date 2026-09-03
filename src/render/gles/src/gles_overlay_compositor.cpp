// gles_overlay_compositor.cpp
// P5-OVERLAYS-TRANS (sub-slice GLES-RENDER): GlesOverlayCompositor
// implementation.
//
// Android-only real implementation is inside #if defined(__ANDROID__).
// Non-Android translation unit compiles to a safe stub that performs no GL
// calls and reports unavailable, matching the style of
// GlesTimelineTransitionCompositor. The pure validation and transform math
// (ValidateOverlayLayerDescriptor / ComputeOverlayTransform) compiles on every
// platform.
//
// Every drawOverlays call: validates every layer (no GL call until all pass),
// snapshots the GL state it will touch, compiles/links at most one temporary
// ES2 program per sampler kind (2D / OES) plus one temporary unit-quad VBO,
// enables straight-alpha source-over blending, draws each layer with its
// `mat3 uTransform` / `float uOpacity` uniforms, then deletes every object it
// created and restores the snapshot on every path.

#include "gles_overlay_compositor.h"

#if defined(__ANDROID__)
#include <EGL/egl.h>
#include <GLES2/gl2.h>
#include <GLES2/gl2ext.h>
#endif

#include <cmath>

namespace {
// Raw GLenum values for the texture targets this compositor accepts, kept
// independent of platform headers so validation compiles without GLES
// headers outside the #if defined(__ANDROID__) block. Match GL_TEXTURE_2D /
// GL_TEXTURE_EXTERNAL_OES exactly.
constexpr uint32_t kTextureTarget2D          = 0x0DE1;
constexpr uint32_t kTextureTargetExternalOes = 0x8D65;

constexpr const char* kErrInvalidArgument   = "gles_overlay_compositor_invalid_argument";
constexpr const char* kErrInvalidTexture    = "gles_overlay_compositor_invalid_texture";
constexpr const char* kErrUnsupportedTarget = "gles_overlay_compositor_unsupported_texture_target";
constexpr const char* kErrInvalidTransform  = "gles_overlay_compositor_invalid_transform";
constexpr const char* kErrInvalidOpacity    = "gles_overlay_compositor_invalid_opacity";
[[maybe_unused]] constexpr const char* kErrCompileFailed = "gles_overlay_compositor_shader_compile_failed";
[[maybe_unused]] constexpr const char* kErrLinkFailed    = "gles_overlay_compositor_program_link_failed";
[[maybe_unused]] constexpr const char* kErrDrawFailed    = "gles_overlay_compositor_draw_failed";

void SetError(std::string* outError, const char* reason) {
    if (outError) *outError = reason;
}

void FillIdentity(float m[9]) {
    m[0] = 1.0f; m[1] = 0.0f; m[2] = 0.0f;
    m[3] = 0.0f; m[4] = 1.0f; m[5] = 0.0f;
    m[6] = 0.0f; m[7] = 0.0f; m[8] = 1.0f;
}
} // namespace

namespace vanguard {
namespace render {

GlesOverlayCompositor::GlesOverlayCompositor() = default;
GlesOverlayCompositor::~GlesOverlayCompositor() = default;

// ── Pure validation + transform math (all platforms) ────────────────────────

bool ValidateOverlayLayerDescriptor(const GlesOverlayLayerDescriptor& layer,
                                    uint32_t surfaceWidth,
                                    uint32_t surfaceHeight,
                                    std::string* outError) {
    if (surfaceWidth == 0 || surfaceHeight == 0) {
        SetError(outError, kErrInvalidArgument);
        return false;
    }
    if (layer.texture == 0) {
        SetError(outError, kErrInvalidTexture);
        return false;
    }
    if (layer.textureTarget != kTextureTarget2D && layer.textureTarget != kTextureTargetExternalOes) {
        SetError(outError, kErrUnsupportedTarget);
        return false;
    }
    if (!std::isfinite(layer.x) || !std::isfinite(layer.y) ||
        !std::isfinite(layer.width) || !std::isfinite(layer.height) ||
        !std::isfinite(layer.rotation) || !std::isfinite(layer.scale) ||
        !(layer.width > 0.0) || !(layer.height > 0.0) || !(layer.scale > 0.0)) {
        SetError(outError, kErrInvalidTransform);
        return false;
    }
    if (!std::isfinite(layer.opacity) || layer.opacity < 0.0 || layer.opacity > 1.0) {
        SetError(outError, kErrInvalidOpacity);
        return false;
    }
    if (outError) outError->clear();
    return true;
}

bool ComputeOverlayTransform(const GlesOverlayLayerDescriptor& layer,
                             uint32_t surfaceWidth,
                             uint32_t surfaceHeight,
                             float outColumnMajor[9]) {
    FillIdentity(outColumnMajor);
    if (surfaceWidth == 0 || surfaceHeight == 0 ||
        !std::isfinite(layer.x) || !std::isfinite(layer.y) ||
        !std::isfinite(layer.width) || !std::isfinite(layer.height) ||
        !std::isfinite(layer.rotation) || !std::isfinite(layer.scale)) {
        return false;
    }

    // Canvas (top-left origin, Y down) geometry.
    const double cx = layer.x + layer.width * 0.5;
    const double cy = layer.y + layer.height * 0.5;
    const double hw = layer.width * layer.scale * 0.5;
    const double hh = layer.height * layer.scale * 0.5;
    const double c  = std::cos(layer.rotation);
    const double s  = std::sin(layer.rotation);

    // local (lx, ly) in [-1,1]² (ly = -1 is the visual top) ->
    //   pixel = centre + R(rotation) * (lx * hw, ly * hh), with
    //   R = [c -s; s c] which is clockwise on a Y-down canvas ->
    //   ndc = (2 * px / W - 1, 1 - 2 * py / H).
    const double sx = 2.0 / static_cast<double>(surfaceWidth);
    const double sy = 2.0 / static_cast<double>(surfaceHeight);

    const double a11 = sx * (hw * c);
    const double a12 = sx * (-hh * s);
    const double a13 = sx * cx - 1.0;
    const double a21 = -sy * (hw * s);
    const double a22 = -sy * (hh * c);
    const double a23 = 1.0 - sy * cy;

    // Column-major: column 0 = (a11, a21, 0), column 1 = (a12, a22, 0),
    // column 2 = (a13, a23, 1).
    outColumnMajor[0] = static_cast<float>(a11);
    outColumnMajor[1] = static_cast<float>(a21);
    outColumnMajor[2] = 0.0f;
    outColumnMajor[3] = static_cast<float>(a12);
    outColumnMajor[4] = static_cast<float>(a22);
    outColumnMajor[5] = 0.0f;
    outColumnMajor[6] = static_cast<float>(a13);
    outColumnMajor[7] = static_cast<float>(a23);
    outColumnMajor[8] = 1.0f;
    return true;
}

#if defined(__ANDROID__)
namespace {

// Opus correction 2: the quad position goes through a mat3 uniform so any
// translation / scale / rotation-about-centre combination is one matrix.
const char* kVertexShaderSrc =
    "attribute vec2 aPosition;\n"
    "attribute vec2 aTexCoord;\n"
    "uniform mat3 uTransform;\n"
    "varying vec2 vTexCoord;\n"
    "void main() {\n"
    "    vTexCoord = aTexCoord;\n"
    "    vec3 p = uTransform * vec3(aPosition, 1.0);\n"
    "    gl_Position = vec4(p.xy, 0.0, 1.0);\n"
    "}\n";

const char* kOesExtensionDirective = "#extension GL_OES_EGL_image_external : require\n";

// Opus correction 3: per-layer opacity scales the sampled alpha; RGB stays
// straight so GL_SRC_ALPHA / GL_ONE_MINUS_SRC_ALPHA is exact source-over.
std::string BuildFragmentShaderSrc(bool oes) {
    std::string src;
    if (oes) src += kOesExtensionDirective;
    src += "precision mediump float;\n"
           "varying vec2 vTexCoord;\n";
    src += oes ? "uniform samplerExternalOES uTexture;\n"
               : "uniform sampler2D uTexture;\n";
    src += "uniform float uOpacity;\n"
           "void main() {\n"
           "    vec4 c = texture2D(uTexture, vTexCoord);\n"
           "    gl_FragColor = vec4(c.rgb, c.a * uOpacity);\n"
           "}\n";
    return src;
}

// Unit quad, triangle strip, interleaved (x, y, u, v). Local (-1,-1) is the
// visual top-left of the overlay and samples the top texel row (v = 1 in GL
// convention); local (+1,+1) is the visual bottom-right and samples v = 0.
const GLfloat kUnitQuad[] = {
    -1.0f, -1.0f, 0.0f, 1.0f,
     1.0f, -1.0f, 1.0f, 1.0f,
    -1.0f,  1.0f, 0.0f, 0.0f,
     1.0f,  1.0f, 1.0f, 0.0f,
};

GLuint CompileShader(GLenum type, const char* source) {
    GLuint shader = glCreateShader(type);
    if (shader == 0) {
        return 0;
    }
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

// One temporary program (per sampler kind) with its resolved locations.
struct TemporaryProgram {
    GLuint vertexShader   = 0;
    GLuint fragmentShader = 0;
    GLuint program        = 0;
    GLint  positionLoc    = -1;
    GLint  texCoordLoc    = -1;
    GLint  transformLoc   = -1;
    GLint  textureLoc     = -1;
    GLint  opacityLoc     = -1;

    bool built() const { return program != 0; }

    void Release() {
        if (program != 0)        glDeleteProgram(program);
        if (fragmentShader != 0) glDeleteShader(fragmentShader);
        if (vertexShader != 0)   glDeleteShader(vertexShader);
        program = fragmentShader = vertexShader = 0;
        positionLoc = texCoordLoc = transformLoc = textureLoc = opacityLoc = -1;
    }
};

bool BuildProgram(bool oes, TemporaryProgram& tmp, std::string* outError) {
    tmp.vertexShader = CompileShader(GL_VERTEX_SHADER, kVertexShaderSrc);
    if (tmp.vertexShader == 0) {
        SetError(outError, kErrCompileFailed);
        return false;
    }
    const std::string fragmentSrc = BuildFragmentShaderSrc(oes);
    tmp.fragmentShader = CompileShader(GL_FRAGMENT_SHADER, fragmentSrc.c_str());
    if (tmp.fragmentShader == 0) {
        SetError(outError, kErrCompileFailed);
        return false;
    }
    tmp.program = glCreateProgram();
    if (tmp.program == 0) {
        SetError(outError, kErrLinkFailed);
        return false;
    }
    glAttachShader(tmp.program, tmp.vertexShader);
    glAttachShader(tmp.program, tmp.fragmentShader);
    glLinkProgram(tmp.program);
    GLint linked = GL_FALSE;
    glGetProgramiv(tmp.program, GL_LINK_STATUS, &linked);
    if (linked != GL_TRUE) {
        SetError(outError, kErrLinkFailed);
        return false;
    }
    tmp.positionLoc  = glGetAttribLocation(tmp.program, "aPosition");
    tmp.texCoordLoc  = glGetAttribLocation(tmp.program, "aTexCoord");
    tmp.transformLoc = glGetUniformLocation(tmp.program, "uTransform");
    tmp.textureLoc   = glGetUniformLocation(tmp.program, "uTexture");
    tmp.opacityLoc   = glGetUniformLocation(tmp.program, "uOpacity");
    if (tmp.positionLoc < 0 || tmp.texCoordLoc < 0 || tmp.transformLoc < 0 ||
        tmp.textureLoc < 0 || tmp.opacityLoc < 0) {
        SetError(outError, kErrLinkFailed);
        return false;
    }
    return true;
}

// Snapshot of every piece of GL state drawOverlays touches (Opus correction
// 1: GL_BLEND lifecycle is owned and restored, together with the rest).
struct GlStateSnapshot {
    GLint     viewport[4]      = {0, 0, 0, 0};
    GLint     activeTexture    = GL_TEXTURE0;
    GLint     binding2D        = 0;
    GLint     bindingOes       = 0;
    bool      oesBindingValid  = false;
    GLint     arrayBuffer      = 0;
    GLint     program          = 0;
    GLboolean blendEnabled     = GL_FALSE;
    GLint     blendEquationRgb   = GL_FUNC_ADD;
    GLint     blendEquationAlpha = GL_FUNC_ADD;
    GLint     blendSrcRgb        = GL_ONE;
    GLint     blendDstRgb        = GL_ZERO;
    GLint     blendSrcAlpha      = GL_ONE;
    GLint     blendDstAlpha      = GL_ZERO;

    void Capture() {
        glGetIntegerv(GL_VIEWPORT, viewport);
        glGetIntegerv(GL_ACTIVE_TEXTURE, &activeTexture);
        glActiveTexture(GL_TEXTURE0);
        glGetIntegerv(GL_TEXTURE_BINDING_2D, &binding2D);
        // The OES binding query is only legal when the extension is present;
        // swallow GL_INVALID_ENUM and skip restoring it in that case.
        while (glGetError() != GL_NO_ERROR) {
        }
        glGetIntegerv(GL_TEXTURE_BINDING_EXTERNAL_OES, &bindingOes);
        oesBindingValid = glGetError() == GL_NO_ERROR;
        if (!oesBindingValid) bindingOes = 0;
        glGetIntegerv(GL_ARRAY_BUFFER_BINDING, &arrayBuffer);
        glGetIntegerv(GL_CURRENT_PROGRAM, &program);
        blendEnabled = glIsEnabled(GL_BLEND);
        glGetIntegerv(GL_BLEND_EQUATION_RGB, &blendEquationRgb);
        glGetIntegerv(GL_BLEND_EQUATION_ALPHA, &blendEquationAlpha);
        glGetIntegerv(GL_BLEND_SRC_RGB, &blendSrcRgb);
        glGetIntegerv(GL_BLEND_DST_RGB, &blendDstRgb);
        glGetIntegerv(GL_BLEND_SRC_ALPHA, &blendSrcAlpha);
        glGetIntegerv(GL_BLEND_DST_ALPHA, &blendDstAlpha);
    }

    void Restore() const {
        glActiveTexture(GL_TEXTURE0);
        glBindTexture(GL_TEXTURE_2D, static_cast<GLuint>(binding2D));
        if (oesBindingValid) {
            glBindTexture(GL_TEXTURE_EXTERNAL_OES, static_cast<GLuint>(bindingOes));
        }
        glActiveTexture(static_cast<GLenum>(activeTexture));
        glBindBuffer(GL_ARRAY_BUFFER, static_cast<GLuint>(arrayBuffer));
        glUseProgram(static_cast<GLuint>(program));
        if (blendEnabled == GL_TRUE) {
            glEnable(GL_BLEND);
        } else {
            glDisable(GL_BLEND);
        }
        glBlendEquationSeparate(static_cast<GLenum>(blendEquationRgb),
                                static_cast<GLenum>(blendEquationAlpha));
        glBlendFuncSeparate(static_cast<GLenum>(blendSrcRgb), static_cast<GLenum>(blendDstRgb),
                            static_cast<GLenum>(blendSrcAlpha), static_cast<GLenum>(blendDstAlpha));
        glViewport(viewport[0], viewport[1], viewport[2], viewport[3]);
    }
};

// Draws one validated layer with an already-built program and a VBO already
// bound to GL_ARRAY_BUFFER. Leaves unit 0 with the layer texture unbound.
bool DrawLayer(const TemporaryProgram& prog,
               const vanguard::render::GlesOverlayLayerDescriptor& layer,
               uint32_t surfaceWidth,
               uint32_t surfaceHeight,
               std::string* outError) {
    float transform[9];
    vanguard::render::ComputeOverlayTransform(layer, surfaceWidth, surfaceHeight, transform);

    const GLenum glTarget = static_cast<GLenum>(layer.textureTarget);
    glUseProgram(prog.program);

    const GLsizei stride = 4 * sizeof(GLfloat);
    glEnableVertexAttribArray(static_cast<GLuint>(prog.positionLoc));
    glVertexAttribPointer(static_cast<GLuint>(prog.positionLoc), 2, GL_FLOAT, GL_FALSE, stride, nullptr);
    glEnableVertexAttribArray(static_cast<GLuint>(prog.texCoordLoc));
    glVertexAttribPointer(static_cast<GLuint>(prog.texCoordLoc), 2, GL_FLOAT, GL_FALSE, stride,
                          reinterpret_cast<const void*>(2 * sizeof(GLfloat)));

    glActiveTexture(GL_TEXTURE0);
    glBindTexture(glTarget, static_cast<GLuint>(layer.texture));
    glUniform1i(prog.textureLoc, 0);
    glUniformMatrix3fv(prog.transformLoc, 1, GL_FALSE, transform);
    glUniform1f(prog.opacityLoc, static_cast<GLfloat>(layer.opacity));

    glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
    const bool ok = glGetError() == GL_NO_ERROR;
    if (!ok) SetError(outError, kErrDrawFailed);

    glBindTexture(glTarget, 0);
    glDisableVertexAttribArray(static_cast<GLuint>(prog.texCoordLoc));
    glDisableVertexAttribArray(static_cast<GLuint>(prog.positionLoc));
    return ok;
}

} // namespace
#endif

bool GlesOverlayCompositor::drawOverlays(const GlesOverlayLayerDescriptor* layers,
                                         size_t layerCount,
                                         uint32_t surfaceWidth,
                                         uint32_t surfaceHeight,
                                         std::string* outError) {
    if (outError) {
        outError->clear();
    }

#if defined(__ANDROID__)
    // ── Fail-closed validation (Opus correction 5): no GL call is issued
    // until every layer passes.
    if (surfaceWidth == 0 || surfaceHeight == 0 || (layers == nullptr && layerCount != 0)) {
        SetError(outError, kErrInvalidArgument);
        return false;
    }
    bool needs2D = false;
    bool needsOes = false;
    for (size_t i = 0; i < layerCount; ++i) {
        if (!ValidateOverlayLayerDescriptor(layers[i], surfaceWidth, surfaceHeight, outError)) {
            return false;
        }
        if (layers[i].textureTarget == kTextureTargetExternalOes) {
            needsOes = true;
        } else {
            needs2D = true;
        }
    }
    if (layerCount == 0) {
        return true; // nothing to draw; no GL state touched
    }

    // ── GL work. Snapshot first; restored on every path below.
    GlStateSnapshot snapshot;
    snapshot.Capture();
    while (glGetError() != GL_NO_ERROR) {
    }

    TemporaryProgram program2D;
    TemporaryProgram programOes;
    GLuint vertexBuffer = 0;
    bool ok = true;

    if (needs2D) ok = BuildProgram(false, program2D, outError);
    if (ok && needsOes) ok = BuildProgram(true, programOes, outError);

    if (ok) {
        glGenBuffers(1, &vertexBuffer);
        if (vertexBuffer == 0) {
            ok = false;
            SetError(outError, kErrDrawFailed);
        } else {
            glBindBuffer(GL_ARRAY_BUFFER, vertexBuffer);
            glBufferData(GL_ARRAY_BUFFER, sizeof(kUnitQuad), kUnitQuad, GL_STATIC_DRAW);
            if (glGetError() != GL_NO_ERROR) {
                ok = false;
                SetError(outError, kErrDrawFailed);
            }
        }
    }

    if (ok) {
        // Straight-alpha Porter-Duff source-over; destination alpha
        // accumulates as srcA + dstA * (1 - srcA).
        glViewport(0, 0, static_cast<GLsizei>(surfaceWidth), static_cast<GLsizei>(surfaceHeight));
        glEnable(GL_BLEND);
        glBlendEquationSeparate(GL_FUNC_ADD, GL_FUNC_ADD);
        glBlendFuncSeparate(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA, GL_ONE, GL_ONE_MINUS_SRC_ALPHA);

        for (size_t i = 0; ok && i < layerCount; ++i) {
            const TemporaryProgram& prog =
                layers[i].textureTarget == kTextureTargetExternalOes ? programOes : program2D;
            ok = DrawLayer(prog, layers[i], surfaceWidth, surfaceHeight, outError);
        }
    }

    // ── Teardown + state restoration (every path).
    glBindBuffer(GL_ARRAY_BUFFER, 0);
    glUseProgram(0);
    if (vertexBuffer != 0) glDeleteBuffers(1, &vertexBuffer);
    programOes.Release();
    program2D.Release();
    snapshot.Restore();
    return ok;
#else
    (void)layers;
    (void)layerCount;
    (void)surfaceWidth;
    (void)surfaceHeight;
    SetError(outError, "gles_overlay_compositor_unavailable_on_host");
    return false;
#endif
}

} // namespace render
} // namespace vanguard
