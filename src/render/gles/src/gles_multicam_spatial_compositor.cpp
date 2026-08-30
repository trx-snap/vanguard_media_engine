// gles_multicam_spatial_compositor.cpp
// P3-MULTICAM-NODE: GlesMultiCamSpatialCompositor implementation.
//
// Android-only real implementation is inside #if defined(__ANDROID__).
// Non-Android translation unit compiles to a safe stub that performs no GL
// calls and reports unavailable, matching the style of
// GlesTextureFrameRenderer/GlesTwoTextureCompositor's host stubs.
//
// Each of the two draws reuses the same full NDC (-1..1) triangle-strip
// quad; the destination rectangle on screen is entirely determined by the
// glViewport() call issued immediately before that draw, exactly like
// GlesTextureFrameRenderer's single-viewport draw. No blending: GL_BLEND is
// never enabled, so the second (secondary) draw fully overwrites whatever
// the first (primary) draw left in any overlapping pixels -- an opaque
// paint-over, not a mix().

#include "gles_multicam_spatial_compositor.h"

#if defined(__ANDROID__)
#include <EGL/egl.h>
#include <GLES2/gl2.h>
#endif

namespace {
// Raw GLenum values for the texture targets this compositor accepts, kept
// independent of platform headers so validation (shared by Android and
// non-Android builds) compiles without needing GLES headers outside the
// #if defined(__ANDROID__) block. Match GL_TEXTURE_2D / GL_TEXTURE_EXTERNAL_OES
// exactly.
constexpr uint32_t kTextureTarget2D = 0x0DE1;
constexpr uint32_t kTextureTargetExternalOes = 0x8D65;
} // namespace

namespace vanguard {
namespace render {

GlesMultiCamSpatialCompositor::GlesMultiCamSpatialCompositor() = default;
GlesMultiCamSpatialCompositor::~GlesMultiCamSpatialCompositor() = default;

#if defined(__ANDROID__)
namespace {

const char* kVertexShaderSrc =
    "attribute vec2 aPosition;\n"
    "attribute vec2 aTexCoord;\n"
    "varying vec2 vTexCoord;\n"
    "void main() {\n"
    "    vTexCoord = aTexCoord;\n"
    "    gl_Position = vec4(aPosition, 0.0, 1.0);\n"
    "}\n";

const char* kFragmentShaderSrc2D =
    "precision mediump float;\n"
    "varying vec2 vTexCoord;\n"
    "uniform sampler2D uTexture;\n"
    "void main() {\n"
    "    gl_FragColor = texture2D(uTexture, vTexCoord);\n"
    "}\n";

const char* kFragmentShaderSrcExternalOes =
    "#extension GL_OES_EGL_image_external : require\n"
    "precision mediump float;\n"
    "varying vec2 vTexCoord;\n"
    "uniform samplerExternalOES uTexture;\n"
    "void main() {\n"
    "    gl_FragColor = texture2D(uTexture, vTexCoord);\n"
    "}\n";

// Fail-closed bounds check for a single rect against the current surface:
// rejects a zero-size rect, a negative origin, and a rect whose far edge
// (x+width / yBottom+height) exceeds the surface dimensions. Widened to
// int64_t before adding so an int32_t origin plus a uint32_t extent can
// never signed/unsigned-overflow the comparison, regardless of input values.
bool IsRectWithinSurface(const vanguard::render::GlesSpatialViewportRectPx& rect,
                         uint32_t surfaceWidth,
                         uint32_t surfaceHeight) {
    if (rect.width == 0 || rect.height == 0) {
        return false;
    }
    if (rect.x < 0 || rect.yBottom < 0) {
        return false;
    }
    const int64_t right = static_cast<int64_t>(rect.x) + static_cast<int64_t>(rect.width);
    const int64_t top = static_cast<int64_t>(rect.yBottom) + static_cast<int64_t>(rect.height);
    if (right > static_cast<int64_t>(surfaceWidth) || top > static_cast<int64_t>(surfaceHeight)) {
        return false;
    }
    return true;
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

// Draws `texture` as a full-opacity textured quad scoped to the given
// bottom-left-origin pixel viewport rectangle. Compiles/links/uploads/draws/
// cleans up a temporary shader program + VBO on every path; never deletes
// `texture`. Does not touch the viewport on failure paths before shader
// compile/link (nothing has been set yet in that case); the caller
// (drawSpatialComposite) owns restoring the full-surface viewport
// regardless of this function's outcome.
bool DrawSingleTextureAtViewport(GLuint texture,
                                 uint32_t textureTarget,
                                 int32_t viewportX,
                                 int32_t viewportYBottom,
                                 uint32_t viewportWidth,
                                 uint32_t viewportHeight,
                                 const vanguard::render::VideoFrameTransform& transform,
                                 std::string* outError) {
    const GLenum glTextureTarget = static_cast<GLenum>(textureTarget);
    const char* fragmentShaderSrc = (textureTarget == kTextureTargetExternalOes)
        ? kFragmentShaderSrcExternalOes
        : kFragmentShaderSrc2D;

    GLuint vertexShader = CompileShader(GL_VERTEX_SHADER, kVertexShaderSrc);
    GLuint fragmentShader = 0;
    GLuint program = 0;
    GLuint vertexBuffer = 0;
    bool ok = true;

    if (vertexShader == 0) {
        ok = false;
    } else {
        fragmentShader = CompileShader(GL_FRAGMENT_SHADER, fragmentShaderSrc);
        if (fragmentShader == 0) {
            ok = false;
        }
    }
    if (!ok && outError) {
        *outError = "gles_multicam_spatial_compositor_shader_compile_failed";
    }

    if (ok) {
        program = glCreateProgram();
        if (program == 0) {
            ok = false;
            if (outError) *outError = "gles_multicam_spatial_compositor_program_link_failed";
        } else {
            glAttachShader(program, vertexShader);
            glAttachShader(program, fragmentShader);
            glLinkProgram(program);
            GLint linked = GL_FALSE;
            glGetProgramiv(program, GL_LINK_STATUS, &linked);
            if (linked != GL_TRUE) {
                ok = false;
                if (outError) *outError = "gles_multicam_spatial_compositor_program_link_failed";
            }
        }
    }

    if (ok) {
        const vanguard::render::VideoTransformPushConstants pc =
            vanguard::render::makeVideoTransformPushConstants(transform);
        const GLfloat kBaseUvs[4][2] = {
            {0.0f, 0.0f},
            {1.0f, 0.0f},
            {0.0f, 1.0f},
            {1.0f, 1.0f},
        };
        GLfloat mappedUvs[4][2];
        for (int i = 0; i < 4; ++i) {
            const GLfloat baseU = kBaseUvs[i][0];
            const GLfloat baseV = kBaseUvs[i][1];
            mappedUvs[i][0] = pc.uvTransform0[0] * baseU + pc.uvTransform0[1] * baseV + pc.uvTransform0[3];
            mappedUvs[i][1] = pc.uvTransform1[0] * baseU + pc.uvTransform1[1] * baseV + pc.uvTransform1[3];
        }

        const GLfloat kQuadVertices[] = {
            -1.0f, -1.0f, mappedUvs[0][0], mappedUvs[0][1],
             1.0f, -1.0f, mappedUvs[1][0], mappedUvs[1][1],
            -1.0f,  1.0f, mappedUvs[2][0], mappedUvs[2][1],
             1.0f,  1.0f, mappedUvs[3][0], mappedUvs[3][1],
        };

        glGenBuffers(1, &vertexBuffer);
        if (vertexBuffer == 0) {
            ok = false;
            if (outError) *outError = "gles_multicam_spatial_compositor_draw_failed";
        } else {
            glBindBuffer(GL_ARRAY_BUFFER, vertexBuffer);
            glBufferData(GL_ARRAY_BUFFER, sizeof(kQuadVertices), kQuadVertices, GL_STATIC_DRAW);
            if (glGetError() != GL_NO_ERROR) {
                ok = false;
                if (outError) *outError = "gles_multicam_spatial_compositor_draw_failed";
            }
        }
    }

    GLint positionLoc = -1;
    GLint texCoordLoc = -1;

    if (ok) {
        glViewport(static_cast<GLint>(viewportX), static_cast<GLint>(viewportYBottom),
                   static_cast<GLsizei>(viewportWidth), static_cast<GLsizei>(viewportHeight));
        glUseProgram(program);

        positionLoc = glGetAttribLocation(program, "aPosition");
        texCoordLoc = glGetAttribLocation(program, "aTexCoord");
        GLint textureLoc = glGetUniformLocation(program, "uTexture");
        if (positionLoc < 0 || texCoordLoc < 0 || textureLoc < 0) {
            ok = false;
            if (outError) *outError = "gles_multicam_spatial_compositor_draw_failed";
        } else {
            glEnableVertexAttribArray(static_cast<GLuint>(positionLoc));
            glVertexAttribPointer(static_cast<GLuint>(positionLoc), 2, GL_FLOAT, GL_FALSE,
                                  4 * sizeof(GLfloat), nullptr);
            glEnableVertexAttribArray(static_cast<GLuint>(texCoordLoc));
            glVertexAttribPointer(static_cast<GLuint>(texCoordLoc), 2, GL_FLOAT, GL_FALSE,
                                  4 * sizeof(GLfloat),
                                  reinterpret_cast<const void*>(2 * sizeof(GLfloat)));

            glActiveTexture(GL_TEXTURE0);
            glBindTexture(glTextureTarget, texture);
            glUniform1i(textureLoc, 0);

            glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);

            if (glGetError() != GL_NO_ERROR) {
                ok = false;
                if (outError) *outError = "gles_multicam_spatial_compositor_draw_failed";
            }

            glBindTexture(glTextureTarget, 0);
            glDisableVertexAttribArray(static_cast<GLuint>(texCoordLoc));
            glDisableVertexAttribArray(static_cast<GLuint>(positionLoc));
        }

        glBindBuffer(GL_ARRAY_BUFFER, 0);
        glUseProgram(0);
    }

    if (vertexBuffer != 0) {
        glDeleteBuffers(1, &vertexBuffer);
    }
    if (program != 0) {
        glDeleteProgram(program);
    }
    if (fragmentShader != 0) {
        glDeleteShader(fragmentShader);
    }
    if (vertexShader != 0) {
        glDeleteShader(vertexShader);
    }

    return ok;
}

} // namespace
#endif

bool GlesMultiCamSpatialCompositor::drawSpatialComposite(
    uint32_t textureA,
    uint32_t textureTargetA,
    uint32_t textureB,
    uint32_t textureTargetB,
    uint32_t surfaceWidth,
    uint32_t surfaceHeight,
    const GlesSpatialViewportRectPx& rectA,
    const GlesSpatialViewportRectPx& rectB,
    const VideoFrameTransform& transformA,
    const VideoFrameTransform& transformB,
    std::string* outError) {
    if (outError) {
        outError->clear();
    }

#if defined(__ANDROID__)
    auto restoreFullViewport = [surfaceWidth, surfaceHeight]() {
        glViewport(0, 0, static_cast<GLsizei>(surfaceWidth), static_cast<GLsizei>(surfaceHeight));
    };

    if (textureA == 0 || textureB == 0 || surfaceWidth == 0 || surfaceHeight == 0) {
        if (outError) *outError = "gles_multicam_spatial_compositor_invalid_argument";
        restoreFullViewport();
        return false;
    }
    if (!IsRectWithinSurface(rectA, surfaceWidth, surfaceHeight) ||
        !IsRectWithinSurface(rectB, surfaceWidth, surfaceHeight)) {
        if (outError) *outError = "gles_multicam_spatial_compositor_invalid_rect";
        restoreFullViewport();
        return false;
    }
    const bool targetAValid = textureTargetA == kTextureTarget2D || textureTargetA == kTextureTargetExternalOes;
    const bool targetBValid = textureTargetB == kTextureTarget2D || textureTargetB == kTextureTargetExternalOes;
    if (!targetAValid || !targetBValid) {
        if (outError) *outError = "gles_multicam_spatial_compositor_unsupported_texture_target";
        restoreFullViewport();
        return false;
    }

    const bool drawAOk = DrawSingleTextureAtViewport(
        textureA, textureTargetA, rectA.x, rectA.yBottom, rectA.width, rectA.height, transformA, outError);
    if (!drawAOk) {
        restoreFullViewport();
        return false;
    }

    const bool drawBOk = DrawSingleTextureAtViewport(
        textureB, textureTargetB, rectB.x, rectB.yBottom, rectB.width, rectB.height, transformB, outError);

    restoreFullViewport();
    return drawBOk;
#else
    (void)textureA;
    (void)textureTargetA;
    (void)textureB;
    (void)textureTargetB;
    (void)surfaceWidth;
    (void)surfaceHeight;
    (void)rectA;
    (void)rectB;
    (void)transformA;
    (void)transformB;
    if (outError) {
        *outError = "gles_multicam_spatial_compositor_unavailable_on_host";
    }
    return false;
#endif
}

} // namespace render
} // namespace vanguard
