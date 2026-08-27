// gles_texture_frame_renderer.cpp
// Phase 1 Unit Z/AA: GlesTextureFrameRenderer implementation.
//
// Android-only real implementation is inside #if defined(__ANDROID__).
// Non-Android translation unit compiles to a safe stub that performs no GL
// calls and reports unavailable, matching the style of
// GlesHardwareBufferImports' host stub.
//
// Unit AA: UV coordinates for the four base corners [0,0], [1,0], [0,1],
// [1,1] are remapped through VideoTransformPushConstants (see
// makeVideoTransformPushConstants in render_transform.h) before upload,
// supporting rotationDegrees 0/90/180/270 plus mirrorHorizontal. No pixel
// readback/content proof, no fence sync, no product wiring.
//
// Unit AR: drawTexturedQuad() gains a textureTarget parameter. GL_TEXTURE_2D
// keeps the existing sampler2D fragment shader; GL_TEXTURE_EXTERNAL_OES uses
// a separate fragment shader sampling via samplerExternalOES, for the
// GlesHardwareBufferImports YUV/implementation-defined import foundation.
// No color-correct YUV->RGB conversion, Camera2 product wiring, or
// multi-node DAG composition is claimed.

#include "gles_texture_frame_renderer.h"

#if defined(__ANDROID__)
#include <EGL/egl.h>
#include <GLES2/gl2.h>
#endif

namespace {
// Raw GLenum values for the texture targets this renderer accepts, kept
// independent of platform headers so the legacy convenience overloads'
// delegation (shared by Android and non-Android builds) compiles without
// needing GLES headers outside the #if defined(__ANDROID__) block. Match
// GL_TEXTURE_2D / GL_TEXTURE_EXTERNAL_OES exactly.
constexpr uint32_t kTextureTarget2D = 0x0DE1;
constexpr uint32_t kTextureTargetExternalOes = 0x8D65;
} // namespace

namespace vanguard {
namespace render {

GlesTextureFrameRenderer::GlesTextureFrameRenderer() = default;
GlesTextureFrameRenderer::~GlesTextureFrameRenderer() = default;

#if defined(__ANDROID__)
namespace {

const char* kUnitZVertexShaderSrc =
    "attribute vec2 aPosition;\n"
    "attribute vec2 aTexCoord;\n"
    "varying vec2 vTexCoord;\n"
    "void main() {\n"
    "    vTexCoord = aTexCoord;\n"
    "    gl_Position = vec4(aPosition, 0.0, 1.0);\n"
    "}\n";

const char* kUnitZFragmentShaderSrc =
    "precision mediump float;\n"
    "varying vec2 vTexCoord;\n"
    "uniform sampler2D uTexture;\n"
    "void main() {\n"
    "    gl_FragColor = texture2D(uTexture, vTexCoord);\n"
    "}\n";

// Unit AR: GL_TEXTURE_EXTERNAL_OES fragment shader. The #extension directive
// must be the shader's first line.
const char* kUnitArExternalOesFragmentShaderSrc =
    "#extension GL_OES_EGL_image_external : require\n"
    "precision mediump float;\n"
    "varying vec2 vTexCoord;\n"
    "uniform samplerExternalOES uTexture;\n"
    "void main() {\n"
    "    gl_FragColor = texture2D(uTexture, vTexCoord);\n"
    "}\n";

// Compiles a shader of the given type; returns 0 on failure (deleting the
// shader object before returning).
GLuint compileUnitZShader(GLenum type, const char* source) {
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

} // namespace
#endif

bool GlesTextureFrameRenderer::drawTexturedQuad(uint32_t texture,
                                                uint32_t width,
                                                uint32_t height,
                                                std::string* outError) {
    return drawTexturedQuad(texture, width, height, VideoFrameTransform{}, outError);
}

bool GlesTextureFrameRenderer::drawTexturedQuad(uint32_t texture,
                                                uint32_t width,
                                                uint32_t height,
                                                const VideoFrameTransform& transform,
                                                std::string* outError) {
    return drawTexturedQuad(texture, kTextureTarget2D, width, height, transform, outError);
}

bool GlesTextureFrameRenderer::drawTexturedQuad(uint32_t texture,
                                                uint32_t textureTarget,
                                                uint32_t width,
                                                uint32_t height,
                                                const VideoFrameTransform& transform,
                                                std::string* outError) {
    if (outError) {
        outError->clear();
    }

#if defined(__ANDROID__)
    if (texture == 0 || width == 0 || height == 0) {
        if (outError) *outError = "gles_texture_frame_renderer_invalid_argument";
        return false;
    }
    if (textureTarget != kTextureTarget2D && textureTarget != kTextureTargetExternalOes) {
        if (outError) *outError = "gles_texture_frame_renderer_invalid_texture_target";
        return false;
    }
    const GLenum glTextureTarget = static_cast<GLenum>(textureTarget);
    const char* fragmentShaderSrc = (textureTarget == kTextureTargetExternalOes)
        ? kUnitArExternalOesFragmentShaderSrc
        : kUnitZFragmentShaderSrc;

    GLuint vertexShader = compileUnitZShader(GL_VERTEX_SHADER, kUnitZVertexShaderSrc);
    GLuint fragmentShader = 0;
    GLuint program = 0;
    GLuint vertexBuffer = 0;
    bool ok = true;

    if (vertexShader == 0) {
        ok = false;
    } else {
        fragmentShader = compileUnitZShader(GL_FRAGMENT_SHADER, fragmentShaderSrc);
        if (fragmentShader == 0) {
            ok = false;
        }
    }
    if (!ok && outError) {
        *outError = "gles_texture_frame_renderer_shader_compile_failed";
    }

    if (ok) {
        program = glCreateProgram();
        if (program == 0) {
            ok = false;
            if (outError) *outError = "gles_texture_frame_renderer_program_link_failed";
        } else {
            glAttachShader(program, vertexShader);
            glAttachShader(program, fragmentShader);
            glLinkProgram(program);
            GLint linked = GL_FALSE;
            glGetProgramiv(program, GL_LINK_STATUS, &linked);
            if (linked != GL_TRUE) {
                ok = false;
                if (outError) *outError = "gles_texture_frame_renderer_program_link_failed";
            }
        }
    }

    if (ok) {
        // Full-window NDC quad interleaved with UVs as (x, y, u, v) per
        // vertex, triangle-strip order. Base UVs [0,0], [1,0], [0,1], [1,1]
        // are remapped through the shared VideoTransformPushConstants rows
        // for the requested rotation/mirror.
        const VideoTransformPushConstants pc = makeVideoTransformPushConstants(transform);
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
            if (outError) *outError = "gles_texture_frame_renderer_draw_failed";
        } else {
            glBindBuffer(GL_ARRAY_BUFFER, vertexBuffer);
            glBufferData(GL_ARRAY_BUFFER, sizeof(kQuadVertices), kQuadVertices, GL_STATIC_DRAW);
            if (glGetError() != GL_NO_ERROR) {
                ok = false;
                if (outError) *outError = "gles_texture_frame_renderer_draw_failed";
            }
        }
    }

    GLint positionLoc = -1;
    GLint texCoordLoc = -1;

    if (ok) {
        glViewport(0, 0, static_cast<GLsizei>(width), static_cast<GLsizei>(height));
        glUseProgram(program);

        positionLoc = glGetAttribLocation(program, "aPosition");
        texCoordLoc = glGetAttribLocation(program, "aTexCoord");
        GLint textureLoc = glGetUniformLocation(program, "uTexture");
        if (positionLoc < 0 || texCoordLoc < 0 || textureLoc < 0) {
            ok = false;
            if (outError) *outError = "gles_texture_frame_renderer_draw_failed";
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
                if (outError) *outError = "gles_texture_frame_renderer_draw_failed";
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
#else
    (void)texture;
    (void)textureTarget;
    (void)width;
    (void)height;
    (void)transform;
    if (outError) {
        *outError = "gles_texture_frame_renderer_unavailable_on_host";
    }
    return false;
#endif
}

} // namespace render
} // namespace vanguard
