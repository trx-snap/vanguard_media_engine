// gles_texture_frame_renderer.cpp
// Phase 1 Unit Z: GlesTextureFrameRenderer implementation.
//
// Android-only real implementation is inside #if defined(__ANDROID__).
// Non-Android translation unit compiles to a safe stub that performs no GL
// calls and reports unavailable, matching the style of
// GlesHardwareBufferImports' host stub.

#include "gles_texture_frame_renderer.h"

#if defined(__ANDROID__)
#include <EGL/egl.h>
#include <GLES2/gl2.h>
#endif

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
    if (outError) {
        outError->clear();
    }

#if defined(__ANDROID__)
    if (texture == 0 || width == 0 || height == 0) {
        if (outError) *outError = "gles_texture_frame_renderer_invalid_argument";
        return false;
    }

    GLuint vertexShader = compileUnitZShader(GL_VERTEX_SHADER, kUnitZVertexShaderSrc);
    GLuint fragmentShader = 0;
    GLuint program = 0;
    GLuint vertexBuffer = 0;
    bool ok = true;

    if (vertexShader == 0) {
        ok = false;
    } else {
        fragmentShader = compileUnitZShader(GL_FRAGMENT_SHADER, kUnitZFragmentShaderSrc);
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
        // Full-window NDC quad interleaved with [0,0]..[1,1] UVs as
        // (x, y, u, v) per vertex, triangle-strip order. No orientation
        // correction in this slice.
        static const GLfloat kQuadVertices[] = {
            -1.0f, -1.0f, 0.0f, 0.0f,
             1.0f, -1.0f, 1.0f, 0.0f,
            -1.0f,  1.0f, 0.0f, 1.0f,
             1.0f,  1.0f, 1.0f, 1.0f,
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
            glBindTexture(GL_TEXTURE_2D, texture);
            glUniform1i(textureLoc, 0);

            glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);

            if (glGetError() != GL_NO_ERROR) {
                ok = false;
                if (outError) *outError = "gles_texture_frame_renderer_draw_failed";
            }

            glBindTexture(GL_TEXTURE_2D, 0);
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
    (void)width;
    (void)height;
    if (outError) {
        *outError = "gles_texture_frame_renderer_unavailable_on_host";
    }
    return false;
#endif
}

} // namespace render
} // namespace vanguard
