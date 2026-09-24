// gles_timeline_transition_compositor.cpp
// P5-COMPOSITOR-TRANS (sub-slice GLES-RENDER): GlesTimelineTransitionCompositor
// implementation.
//
// Android-only real implementation is inside #if defined(__ANDROID__).
// Non-Android translation unit compiles to a safe stub that performs no GL
// calls and reports unavailable, matching the style of
// GlesTwoTextureCompositor / GlesMultiCamSpatialCompositor host stubs. The
// pure placement math (ResolveTimelineLayerPlacement) compiles on every
// platform.
//
// Every draw compiles/links a temporary minimal ES2 program (single-sampler
// opaque layer draw, or two-sampler mix draw), uploads a temporary VBO,
// draws, and deletes everything it created before returning on every path.
// GL_BLEND is never enabled: a layered slide/wipe is an opaque paint-over and
// a crossfade is a single mix() in the fragment shader.

#include "gles_timeline_transition_compositor.h"

#if defined(__ANDROID__)
#include <EGL/egl.h>
#include <GLES2/gl2.h>
#endif

#include <algorithm>
#include <cmath>

namespace {
// Raw GLenum values for the texture targets this compositor accepts, kept
// independent of platform headers so validation compiles without GLES
// headers outside the #if defined(__ANDROID__) block. Match GL_TEXTURE_2D /
// GL_TEXTURE_EXTERNAL_OES exactly.
[[maybe_unused]] constexpr uint32_t kTextureTarget2D = 0x0DE1;
[[maybe_unused]] constexpr uint32_t kTextureTargetExternalOes = 0x8D65;

constexpr double kRectEpsilon = 1e-9;

bool IsFiniteRect(const vanguard::render::GlesTimelineNormalizedRect& r) {
    return std::isfinite(r.x) && std::isfinite(r.y) &&
           std::isfinite(r.width) && std::isfinite(r.height);
}

[[maybe_unused]] bool HasNonNegativeExtent(const vanguard::render::GlesTimelineNormalizedRect& r) {
    return r.width >= 0.0 && r.height >= 0.0;
}

[[maybe_unused]] bool IsCropInsideUnit(const vanguard::render::GlesTimelineNormalizedRect& r) {
    return r.x >= -kRectEpsilon && r.y >= -kRectEpsilon &&
           (r.x + r.width) <= 1.0 + kRectEpsilon &&
           (r.y + r.height) <= 1.0 + kRectEpsilon;
}

[[maybe_unused]] bool IsIdentityRect(const vanguard::render::GlesTimelineNormalizedRect& r) {
    return std::fabs(r.x) <= kRectEpsilon && std::fabs(r.y) <= kRectEpsilon &&
           std::fabs(r.width - 1.0) <= kRectEpsilon && std::fabs(r.height - 1.0) <= kRectEpsilon;
}

double ClampUnit(double v) {
    return std::min(1.0, std::max(0.0, v));
}
} // namespace

namespace vanguard {
namespace render {

GlesTimelineTransitionCompositor::GlesTimelineTransitionCompositor() = default;
GlesTimelineTransitionCompositor::~GlesTimelineTransitionCompositor() = default;

// ── Pure placement math (all platforms) ─────────────────────────────────────

GlesTimelineLayerPlacement ResolveTimelineLayerPlacement(
    const GlesTimelineNormalizedRect& viewport,
    const GlesTimelineNormalizedRect& crop,
    uint32_t surfaceWidth,
    uint32_t surfaceHeight) {
    GlesTimelineLayerPlacement out;
    if (!IsFiniteRect(viewport) || !IsFiniteRect(crop) ||
        surfaceWidth == 0 || surfaceHeight == 0) {
        return out;
    }

    // Destination canvas rect of the visible (cropped) part of the layer, in
    // top-left normalized canvas coordinates.
    const double x0 = viewport.x + crop.x * viewport.width;
    const double y0 = viewport.y + crop.y * viewport.height;
    const double x1 = x0 + crop.width * viewport.width;
    const double y1 = y0 + crop.height * viewport.height;
    if (!(x1 > x0) || !(y1 > y0)) {
        return out; // zero or negative extent: nothing visible
    }

    // Clip to the canvas.
    const double cx0 = std::max(x0, 0.0);
    const double cy0 = std::max(y0, 0.0);
    const double cx1 = std::min(x1, 1.0);
    const double cy1 = std::min(y1, 1.0);
    if (!(cx1 > cx0) || !(cy1 > cy0)) {
        return out; // fully off-canvas
    }

    // Pixel rect (top-left rows, then converted to bottom-left origin).
    const long pxLeft   = std::lround(cx0 * static_cast<double>(surfaceWidth));
    const long pxRight  = std::lround(cx1 * static_cast<double>(surfaceWidth));
    const long pxTop    = std::lround(cy0 * static_cast<double>(surfaceHeight));
    const long pxBottom = std::lround(cy1 * static_cast<double>(surfaceHeight));
    if (pxRight <= pxLeft || pxBottom <= pxTop) {
        return out; // rounds to zero pixels
    }

    // Advance the sampled crop range by the clipped fractions (top-left
    // texture space), then flip V into GL convention.
    const double fx0 = (cx0 - x0) / (x1 - x0);
    const double fx1 = (cx1 - x0) / (x1 - x0);
    const double fy0 = (cy0 - y0) / (y1 - y0);
    const double fy1 = (cy1 - y0) / (y1 - y0);
    const double u0 = crop.x + fx0 * crop.width;
    const double u1 = crop.x + fx1 * crop.width;
    const double t0 = crop.y + fy0 * crop.height; // top edge (Y-down)
    const double t1 = crop.y + fy1 * crop.height; // bottom edge (Y-down)

    out.visible   = true;
    out.xPx       = static_cast<int32_t>(pxLeft);
    out.yBottomPx = static_cast<int32_t>(static_cast<long>(surfaceHeight) - pxBottom);
    out.widthPx   = static_cast<uint32_t>(pxRight - pxLeft);
    out.heightPx  = static_cast<uint32_t>(pxBottom - pxTop);
    out.u0        = static_cast<float>(ClampUnit(u0));
    out.u1        = static_cast<float>(ClampUnit(u1));
    out.vTop      = static_cast<float>(ClampUnit(1.0 - t0));
    out.vBottom   = static_cast<float>(ClampUnit(1.0 - t1));
    return out;
}

#if defined(__ANDROID__)
namespace {

const char* kSingleVertexShaderSrc =
    "attribute vec2 aPosition;\n"
    "attribute vec2 aTexCoord;\n"
    "varying vec2 vTexCoord;\n"
    "void main() {\n"
    "    vTexCoord = aTexCoord;\n"
    "    gl_Position = vec4(aPosition, 0.0, 1.0);\n"
    "}\n";

const char* kMixVertexShaderSrc =
    "attribute vec2 aPosition;\n"
    "attribute vec2 aTexCoordFrom;\n"
    "attribute vec2 aTexCoordTo;\n"
    "varying vec2 vTexCoordFrom;\n"
    "varying vec2 vTexCoordTo;\n"
    "void main() {\n"
    "    vTexCoordFrom = aTexCoordFrom;\n"
    "    vTexCoordTo = aTexCoordTo;\n"
    "    gl_Position = vec4(aPosition, 0.0, 1.0);\n"
    "}\n";

const char* kOesExtensionDirective = "#extension GL_OES_EGL_image_external : require\n";

// Single-sampler layer fragment shader; sampler type per target. The
// opaque variant (weighted == false) is byte-identical to the pre-fade
// shader. The weighted variant scales the sampled colour by uWeight, i.e.
// the layer composited over black with that weight (fade-through-black
// half-phases); the sampled alpha is passed through unchanged.
std::string BuildSingleFragmentShaderSrc(bool oes, bool weighted) {
    std::string src;
    if (oes) src += kOesExtensionDirective;
    src += "precision mediump float;\n"
           "varying vec2 vTexCoord;\n";
    src += oes ? "uniform samplerExternalOES uTexture;\n"
               : "uniform sampler2D uTexture;\n";
    if (weighted) {
        src += "uniform float uWeight;\n"
               "void main() {\n"
               "    vec4 c = texture2D(uTexture, vTexCoord);\n"
               "    gl_FragColor = vec4(c.rgb * uWeight, c.a);\n"
               "}\n";
    } else {
        src += "void main() {\n"
               "    gl_FragColor = texture2D(uTexture, vTexCoord);\n"
               "}\n";
    }
    return src;
}

// Two-sampler crossfade mix fragment shader; sampler types per permutation.
// The extension directive must be the shader's first line whenever either
// source is OES.
std::string BuildMixFragmentShaderSrc(bool oesFrom, bool oesTo) {
    std::string src;
    if (oesFrom || oesTo) src += kOesExtensionDirective;
    src += "precision mediump float;\n"
           "varying vec2 vTexCoordFrom;\n"
           "varying vec2 vTexCoordTo;\n";
    src += oesFrom ? "uniform samplerExternalOES uTextureFrom;\n"
                   : "uniform sampler2D uTextureFrom;\n";
    src += oesTo ? "uniform samplerExternalOES uTextureTo;\n"
                 : "uniform sampler2D uTextureTo;\n";
    src += "uniform float uWeightTo;\n"
           "void main() {\n"
           "    vec4 colorFrom = texture2D(uTextureFrom, vTexCoordFrom);\n"
           "    vec4 colorTo = texture2D(uTextureTo, vTexCoordTo);\n"
           "    gl_FragColor = mix(colorFrom, colorTo, uWeightTo);\n"
           "}\n";
    return src;
}

// Compiles a shader of the given type; returns 0 on failure (deleting the
// shader object before returning).
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

// Temporary GL objects for one draw; deleted by Release() on every path.
struct TemporaryProgram {
    GLuint vertexShader   = 0;
    GLuint fragmentShader = 0;
    GLuint program        = 0;
    GLuint vertexBuffer   = 0;

    void Release() {
        if (vertexBuffer != 0)   glDeleteBuffers(1, &vertexBuffer);
        if (program != 0)        glDeleteProgram(program);
        if (fragmentShader != 0) glDeleteShader(fragmentShader);
        if (vertexShader != 0)   glDeleteShader(vertexShader);
        vertexBuffer = program = fragmentShader = vertexShader = 0;
    }
};

// Compiles + links; on failure sets outError and returns false (objects
// already created remain in `tmp` for the caller's Release()).
bool BuildProgram(const char* vertexSrc,
                  const std::string& fragmentSrc,
                  TemporaryProgram& tmp,
                  std::string* outError) {
    tmp.vertexShader = CompileShader(GL_VERTEX_SHADER, vertexSrc);
    if (tmp.vertexShader == 0) {
        if (outError) *outError = "gles_timeline_transition_compositor_shader_compile_failed";
        return false;
    }
    tmp.fragmentShader = CompileShader(GL_FRAGMENT_SHADER, fragmentSrc.c_str());
    if (tmp.fragmentShader == 0) {
        if (outError) *outError = "gles_timeline_transition_compositor_shader_compile_failed";
        return false;
    }
    tmp.program = glCreateProgram();
    if (tmp.program == 0) {
        if (outError) *outError = "gles_timeline_transition_compositor_program_link_failed";
        return false;
    }
    glAttachShader(tmp.program, tmp.vertexShader);
    glAttachShader(tmp.program, tmp.fragmentShader);
    glLinkProgram(tmp.program);
    GLint linked = GL_FALSE;
    glGetProgramiv(tmp.program, GL_LINK_STATUS, &linked);
    if (linked != GL_TRUE) {
        if (outError) *outError = "gles_timeline_transition_compositor_program_link_failed";
        return false;
    }
    return true;
}

// Uploads interleaved vertex data into a fresh VBO left bound to
// GL_ARRAY_BUFFER; false on failure.
bool UploadQuad(const GLfloat* data, GLsizeiptr bytes, TemporaryProgram& tmp, std::string* outError) {
    glGenBuffers(1, &tmp.vertexBuffer);
    if (tmp.vertexBuffer == 0) {
        if (outError) *outError = "gles_timeline_transition_compositor_draw_failed";
        return false;
    }
    glBindBuffer(GL_ARRAY_BUFFER, tmp.vertexBuffer);
    glBufferData(GL_ARRAY_BUFFER, bytes, data, GL_STATIC_DRAW);
    if (glGetError() != GL_NO_ERROR) {
        if (outError) *outError = "gles_timeline_transition_compositor_draw_failed";
        return false;
    }
    return true;
}

// Draws one layer scoped to its resolved placement. [colorWeight] >= 1.0
// draws the layer opaque through the unchanged single-sampler shader;
// [colorWeight] < 1.0 draws it through the weighted shader (layer colour
// scaled by the weight == the layer composited over black), which is how a
// fade half-phase renders. Does nothing (and succeeds) when the placement is
// not visible. Leaves the viewport at the layer rect; the caller restores
// the full-surface viewport.
bool DrawOpaqueLayer(GLuint texture,
                     uint32_t textureTarget,
                     const vanguard::render::GlesTimelineLayerPlacement& placement,
                     float colorWeight,
                     std::string* outError) {
    if (!placement.visible) {
        return true;
    }
    const bool weighted = colorWeight < 1.0f;
    const GLenum glTarget = static_cast<GLenum>(textureTarget);
    TemporaryProgram tmp;
    bool ok = BuildProgram(kSingleVertexShaderSrc,
                           BuildSingleFragmentShaderSrc(textureTarget == kTextureTargetExternalOes,
                                                        weighted),
                           tmp, outError);

    if (ok) {
        // Full NDC quad (triangle strip) interleaved as (x, y, u, v); the
        // destination rectangle is set purely by glViewport below.
        const GLfloat quad[] = {
            -1.0f, -1.0f, placement.u0, placement.vBottom,
             1.0f, -1.0f, placement.u1, placement.vBottom,
            -1.0f,  1.0f, placement.u0, placement.vTop,
             1.0f,  1.0f, placement.u1, placement.vTop,
        };
        ok = UploadQuad(quad, sizeof(quad), tmp, outError);
    }

    if (ok) {
        glViewport(static_cast<GLint>(placement.xPx), static_cast<GLint>(placement.yBottomPx),
                   static_cast<GLsizei>(placement.widthPx), static_cast<GLsizei>(placement.heightPx));
        glUseProgram(tmp.program);

        const GLint positionLoc = glGetAttribLocation(tmp.program, "aPosition");
        const GLint texCoordLoc = glGetAttribLocation(tmp.program, "aTexCoord");
        const GLint textureLoc  = glGetUniformLocation(tmp.program, "uTexture");
        const GLint weightLoc   = weighted ? glGetUniformLocation(tmp.program, "uWeight") : 0;
        if (positionLoc < 0 || texCoordLoc < 0 || textureLoc < 0 || weightLoc < 0) {
            ok = false;
            if (outError) *outError = "gles_timeline_transition_compositor_draw_failed";
        } else {
            const GLsizei stride = 4 * sizeof(GLfloat);
            glEnableVertexAttribArray(static_cast<GLuint>(positionLoc));
            glVertexAttribPointer(static_cast<GLuint>(positionLoc), 2, GL_FLOAT, GL_FALSE, stride, nullptr);
            glEnableVertexAttribArray(static_cast<GLuint>(texCoordLoc));
            glVertexAttribPointer(static_cast<GLuint>(texCoordLoc), 2, GL_FLOAT, GL_FALSE, stride,
                                  reinterpret_cast<const void*>(2 * sizeof(GLfloat)));

            glActiveTexture(GL_TEXTURE0);
            glBindTexture(glTarget, texture);
            glUniform1i(textureLoc, 0);
            if (weighted) {
                glUniform1f(weightLoc, colorWeight < 0.0f ? 0.0f : colorWeight);
            }

            glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
            if (glGetError() != GL_NO_ERROR) {
                ok = false;
                if (outError) *outError = "gles_timeline_transition_compositor_draw_failed";
            }

            glBindTexture(glTarget, 0);
            glDisableVertexAttribArray(static_cast<GLuint>(texCoordLoc));
            glDisableVertexAttribArray(static_cast<GLuint>(positionLoc));
        }
    }

    glBindBuffer(GL_ARRAY_BUFFER, 0);
    glUseProgram(0);
    tmp.Release();
    return ok;
}

// Draws the full-canvas crossfade mix(from, to, weightTo) using each layer's
// crop as its UV range.
bool DrawMixedLayers(GLuint textureFrom,
                     uint32_t textureTargetFrom,
                     GLuint textureTo,
                     uint32_t textureTargetTo,
                     const vanguard::render::GlesTimelineNormalizedRect& fromCrop,
                     const vanguard::render::GlesTimelineNormalizedRect& toCrop,
                     float weightTo,
                     uint32_t surfaceWidth,
                     uint32_t surfaceHeight,
                     std::string* outError) {
    const GLenum glTargetFrom = static_cast<GLenum>(textureTargetFrom);
    const GLenum glTargetTo   = static_cast<GLenum>(textureTargetTo);
    TemporaryProgram tmp;
    bool ok = BuildProgram(kMixVertexShaderSrc,
                           BuildMixFragmentShaderSrc(textureTargetFrom == kTextureTargetExternalOes,
                                                     textureTargetTo == kTextureTargetExternalOes),
                           tmp, outError);

    if (ok) {
        // Crop -> GL UVs (V flipped), identity viewports by contract.
        const GLfloat fu0 = static_cast<GLfloat>(ClampUnit(fromCrop.x));
        const GLfloat fu1 = static_cast<GLfloat>(ClampUnit(fromCrop.x + fromCrop.width));
        const GLfloat fvT = static_cast<GLfloat>(ClampUnit(1.0 - fromCrop.y));
        const GLfloat fvB = static_cast<GLfloat>(ClampUnit(1.0 - (fromCrop.y + fromCrop.height)));
        const GLfloat tu0 = static_cast<GLfloat>(ClampUnit(toCrop.x));
        const GLfloat tu1 = static_cast<GLfloat>(ClampUnit(toCrop.x + toCrop.width));
        const GLfloat tvT = static_cast<GLfloat>(ClampUnit(1.0 - toCrop.y));
        const GLfloat tvB = static_cast<GLfloat>(ClampUnit(1.0 - (toCrop.y + toCrop.height)));
        // Interleaved (x, y, uFrom, vFrom, uTo, vTo), triangle-strip order.
        const GLfloat quad[] = {
            -1.0f, -1.0f, fu0, fvB, tu0, tvB,
             1.0f, -1.0f, fu1, fvB, tu1, tvB,
            -1.0f,  1.0f, fu0, fvT, tu0, tvT,
             1.0f,  1.0f, fu1, fvT, tu1, tvT,
        };
        ok = UploadQuad(quad, sizeof(quad), tmp, outError);
    }

    if (ok) {
        glViewport(0, 0, static_cast<GLsizei>(surfaceWidth), static_cast<GLsizei>(surfaceHeight));
        glUseProgram(tmp.program);

        const GLint positionLoc     = glGetAttribLocation(tmp.program, "aPosition");
        const GLint texCoordFromLoc = glGetAttribLocation(tmp.program, "aTexCoordFrom");
        const GLint texCoordToLoc   = glGetAttribLocation(tmp.program, "aTexCoordTo");
        const GLint textureFromLoc  = glGetUniformLocation(tmp.program, "uTextureFrom");
        const GLint textureToLoc    = glGetUniformLocation(tmp.program, "uTextureTo");
        const GLint weightToLoc     = glGetUniformLocation(tmp.program, "uWeightTo");
        if (positionLoc < 0 || texCoordFromLoc < 0 || texCoordToLoc < 0 ||
            textureFromLoc < 0 || textureToLoc < 0 || weightToLoc < 0) {
            ok = false;
            if (outError) *outError = "gles_timeline_transition_compositor_draw_failed";
        } else {
            const GLsizei stride = 6 * sizeof(GLfloat);
            glEnableVertexAttribArray(static_cast<GLuint>(positionLoc));
            glVertexAttribPointer(static_cast<GLuint>(positionLoc), 2, GL_FLOAT, GL_FALSE, stride, nullptr);
            glEnableVertexAttribArray(static_cast<GLuint>(texCoordFromLoc));
            glVertexAttribPointer(static_cast<GLuint>(texCoordFromLoc), 2, GL_FLOAT, GL_FALSE, stride,
                                  reinterpret_cast<const void*>(2 * sizeof(GLfloat)));
            glEnableVertexAttribArray(static_cast<GLuint>(texCoordToLoc));
            glVertexAttribPointer(static_cast<GLuint>(texCoordToLoc), 2, GL_FLOAT, GL_FALSE, stride,
                                  reinterpret_cast<const void*>(4 * sizeof(GLfloat)));

            glActiveTexture(GL_TEXTURE0);
            glBindTexture(glTargetFrom, textureFrom);
            glUniform1i(textureFromLoc, 0);

            glActiveTexture(GL_TEXTURE1);
            glBindTexture(glTargetTo, textureTo);
            glUniform1i(textureToLoc, 1);

            glUniform1f(weightToLoc, weightTo);

            glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
            if (glGetError() != GL_NO_ERROR) {
                ok = false;
                if (outError) *outError = "gles_timeline_transition_compositor_draw_failed";
            }

            glDisableVertexAttribArray(static_cast<GLuint>(texCoordToLoc));
            glDisableVertexAttribArray(static_cast<GLuint>(texCoordFromLoc));
            glDisableVertexAttribArray(static_cast<GLuint>(positionLoc));
        }

        glActiveTexture(GL_TEXTURE1);
        glBindTexture(glTargetTo, 0);
        glActiveTexture(GL_TEXTURE0);
        glBindTexture(glTargetFrom, 0);
    }

    glBindBuffer(GL_ARRAY_BUFFER, 0);
    glUseProgram(0);
    tmp.Release();
    return ok;
}

} // namespace
#endif

bool GlesTimelineTransitionCompositor::drawTransition(uint32_t textureFrom,
                                                      uint32_t textureTargetFrom,
                                                      uint32_t textureTo,
                                                      uint32_t textureTargetTo,
                                                      uint32_t surfaceWidth,
                                                      uint32_t surfaceHeight,
                                                      const GlesTimelineTransitionGeometry& geometry,
                                                      std::string* outError) {
    if (outError) {
        outError->clear();
    }

#if defined(__ANDROID__)
    // ── Fail-closed validation: no GL call is issued until every check passes.
    if (textureFrom == 0 || textureTo == 0 || surfaceWidth == 0 || surfaceHeight == 0) {
        if (outError) *outError = "gles_timeline_transition_compositor_invalid_argument";
        return false;
    }
    if (!std::isfinite(geometry.progress)) {
        if (outError) *outError = "gles_timeline_transition_compositor_invalid_progress";
        return false;
    }
    if (!std::isfinite(geometry.blendWeightFrom) || !std::isfinite(geometry.blendWeightTo)) {
        if (outError) *outError = "gles_timeline_transition_compositor_invalid_blend_weight";
        return false;
    }
    if (!IsFiniteRect(geometry.fromViewport) || !IsFiniteRect(geometry.toViewport) ||
        !IsFiniteRect(geometry.fromCrop) || !IsFiniteRect(geometry.toCrop) ||
        !HasNonNegativeExtent(geometry.fromViewport) || !HasNonNegativeExtent(geometry.toViewport) ||
        !HasNonNegativeExtent(geometry.fromCrop) || !HasNonNegativeExtent(geometry.toCrop) ||
        !IsCropInsideUnit(geometry.fromCrop) || !IsCropInsideUnit(geometry.toCrop)) {
        if (outError) *outError = "gles_timeline_transition_compositor_invalid_geometry";
        return false;
    }
    const bool targetFromValid =
        textureTargetFrom == kTextureTarget2D || textureTargetFrom == kTextureTargetExternalOes;
    const bool targetToValid =
        textureTargetTo == kTextureTarget2D || textureTargetTo == kTextureTargetExternalOes;
    if (!targetFromValid || !targetToValid) {
        if (outError) *outError = "gles_timeline_transition_compositor_unsupported_texture_target";
        return false;
    }

    const double weightFrom = ClampUnit(geometry.blendWeightFrom);
    const double weightTo   = ClampUnit(geometry.blendWeightTo);

    // Draw model from the weights alone (never a family enum). A single-sided
    // PARTIAL weight (the other side <= 0, this side < 1) is a fade half-phase:
    // that layer is drawn scaled by its weight over black instead of opaque,
    // so fade-through-black is honoured rather than collapsing to from-only /
    // to-only. Hard cut (1,0), crossfade endpoints (1,0)/(0,1), crossfade
    // interior (mix) and the opaque slide/wipe pair (1,1) resolve exactly as
    // before.
    enum class DrawMode { kFromOnly, kToOnly, kLayeredOpaque, kMix, kFromFade, kToFade };
    DrawMode mode;
    if (weightTo <= 0.0) {
        mode = weightFrom >= 1.0 ? DrawMode::kFromOnly : DrawMode::kFromFade;
    } else if (weightFrom <= 0.0) {
        mode = weightTo >= 1.0 ? DrawMode::kToOnly : DrawMode::kToFade;
    } else if (weightFrom >= 1.0 && weightTo >= 1.0) {
        mode = DrawMode::kLayeredOpaque;
    } else {
        mode = DrawMode::kMix;
    }
    const bool requiresIdentityViewports =
        mode == DrawMode::kMix || mode == DrawMode::kFromFade || mode == DrawMode::kToFade;
    if (requiresIdentityViewports &&
        (!IsIdentityRect(geometry.fromViewport) || !IsIdentityRect(geometry.toViewport))) {
        if (outError) *outError = "gles_timeline_transition_compositor_unsupported_geometry";
        return false;
    }

    // ── GL work. Full-surface viewport is restored on every path below.
    auto restoreFullViewport = [surfaceWidth, surfaceHeight]() {
        glViewport(0, 0, static_cast<GLsizei>(surfaceWidth), static_cast<GLsizei>(surfaceHeight));
    };

    bool ok = true;
    switch (mode) {
        case DrawMode::kFromOnly: {
            const GlesTimelineLayerPlacement placement = ResolveTimelineLayerPlacement(
                geometry.fromViewport, geometry.fromCrop, surfaceWidth, surfaceHeight);
            ok = DrawOpaqueLayer(textureFrom, textureTargetFrom, placement, 1.0f, outError);
            break;
        }
        case DrawMode::kToOnly: {
            const GlesTimelineLayerPlacement placement = ResolveTimelineLayerPlacement(
                geometry.toViewport, geometry.toCrop, surfaceWidth, surfaceHeight);
            ok = DrawOpaqueLayer(textureTo, textureTargetTo, placement, 1.0f, outError);
            break;
        }
        case DrawMode::kLayeredOpaque: {
            const GlesTimelineLayerPlacement fromPlacement = ResolveTimelineLayerPlacement(
                geometry.fromViewport, geometry.fromCrop, surfaceWidth, surfaceHeight);
            ok = DrawOpaqueLayer(textureFrom, textureTargetFrom, fromPlacement, 1.0f, outError);
            if (ok) {
                const GlesTimelineLayerPlacement toPlacement = ResolveTimelineLayerPlacement(
                    geometry.toViewport, geometry.toCrop, surfaceWidth, surfaceHeight);
                ok = DrawOpaqueLayer(textureTo, textureTargetTo, toPlacement, 1.0f, outError);
            }
            break;
        }
        case DrawMode::kFromFade: {
            // Fade first half: "from" scaled by its weight over black. Identity
            // viewport by contract, so with an identity crop the draw covers the
            // whole canvas (weight 0 at the midpoint yields a black frame).
            const GlesTimelineLayerPlacement placement = ResolveTimelineLayerPlacement(
                geometry.fromViewport, geometry.fromCrop, surfaceWidth, surfaceHeight);
            ok = DrawOpaqueLayer(textureFrom, textureTargetFrom, placement,
                                 static_cast<float>(weightFrom), outError);
            break;
        }
        case DrawMode::kToFade: {
            // Fade second half: "to" scaled by its weight over black.
            const GlesTimelineLayerPlacement placement = ResolveTimelineLayerPlacement(
                geometry.toViewport, geometry.toCrop, surfaceWidth, surfaceHeight);
            ok = DrawOpaqueLayer(textureTo, textureTargetTo, placement,
                                 static_cast<float>(weightTo), outError);
            break;
        }
        case DrawMode::kMix:
            ok = DrawMixedLayers(textureFrom, textureTargetFrom, textureTo, textureTargetTo,
                                 geometry.fromCrop, geometry.toCrop,
                                 static_cast<float>(weightTo),
                                 surfaceWidth, surfaceHeight, outError);
            break;
    }

    restoreFullViewport();
    return ok;
#else
    (void)textureFrom;
    (void)textureTargetFrom;
    (void)textureTo;
    (void)textureTargetTo;
    (void)surfaceWidth;
    (void)surfaceHeight;
    (void)geometry;
    if (outError) {
        *outError = "gles_timeline_transition_compositor_unavailable_on_host";
    }
    return false;
#endif
}

} // namespace render
} // namespace vanguard
