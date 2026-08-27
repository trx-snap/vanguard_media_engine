// gles_two_texture_compositor.cpp
// Phase 1 Unit AS: GlesTwoTextureCompositor implementation.
//
// Android-only real implementation is inside #if defined(__ANDROID__).
// Non-Android translation unit compiles to a safe stub that performs no GL
// calls and reports unavailable, matching the style of
// GlesTextureFrameRenderer's host stub.
//
// Unit AS originally scoped this to two-texture GL_TEXTURE_2D composition
// only, rejecting any non-GL_TEXTURE_2D target (including
// GL_TEXTURE_EXTERNAL_OES or 0) closed, performing no GL calls. Each
// texture's UVs are mapped independently through its own
// VideoTransformPushConstants (see makeVideoTransformPushConstants), and the
// fragment shader blends the two sampled colors via
// mix(colorA, colorB, weightB).
//
// Unit AT: drawCompositedQuad() now accepts GL_TEXTURE_EXTERNAL_OES
// independently for each of textureTargetA/textureTargetB, alongside
// GL_TEXTURE_2D, giving all four target permutations (2D+2D, OES+2D,
// 2D+OES, OES+OES). The fragment shader is selected per permutation:
// samplerExternalOES (with the required "#extension
// GL_OES_EGL_image_external : require" directive) is used for whichever of
// uTextureA/uTextureB is OES, sampler2D otherwise. Each texture is bound to
// its own actual target on its texture unit and unbound the same way
// afterward. No color-correct YUV conversion policy, timeline DAG
// integration, transitions/PiP, or product UI is added.

#include "gles_two_texture_compositor.h"

#if defined(__ANDROID__)
#include <EGL/egl.h>
#include <GLES2/gl2.h>
#endif

#include <cmath>

namespace {
// Raw GLenum values for the texture targets Unit AT accepts, kept
// independent of platform headers so validation (shared by Android and
// non-Android builds) compiles without needing GLES headers outside the
// #if defined(__ANDROID__) block. Match GL_TEXTURE_2D / GL_TEXTURE_EXTERNAL_OES
// exactly.
constexpr uint32_t kTextureTarget2D = 0x0DE1;
constexpr uint32_t kTextureTargetExternalOes = 0x8D65;
} // namespace

namespace vanguard {
namespace render {

GlesTwoTextureCompositor::GlesTwoTextureCompositor() = default;
GlesTwoTextureCompositor::~GlesTwoTextureCompositor() = default;

#if defined(__ANDROID__)
namespace {

const char* kUnitAsVertexShaderSrc =
    "attribute vec2 aPosition;\n"
    "attribute vec2 aTexCoordA;\n"
    "attribute vec2 aTexCoordB;\n"
    "varying vec2 vTexCoordA;\n"
    "varying vec2 vTexCoordB;\n"
    "void main() {\n"
    "    vTexCoordA = aTexCoordA;\n"
    "    vTexCoordB = aTexCoordB;\n"
    "    gl_Position = vec4(aPosition, 0.0, 1.0);\n"
    "}\n";

const char* kUnitAsFragmentShaderSrc =
    "precision mediump float;\n"
    "varying vec2 vTexCoordA;\n"
    "varying vec2 vTexCoordB;\n"
    "uniform sampler2D uTextureA;\n"
    "uniform sampler2D uTextureB;\n"
    "uniform float uWeightB;\n"
    "void main() {\n"
    "    vec4 colorA = texture2D(uTextureA, vTexCoordA);\n"
    "    vec4 colorB = texture2D(uTextureB, vTexCoordB);\n"
    "    gl_FragColor = mix(colorA, colorB, uWeightB);\n"
    "}\n";

// Unit AT: fragment shader variants for the OES+2D, 2D+OES, and OES+OES
// target permutations. The "#extension GL_OES_EGL_image_external : require"
// directive must be each shader's first line; samplerExternalOES replaces
// sampler2D for whichever of uTextureA/uTextureB samples a
// GL_TEXTURE_EXTERNAL_OES texture.
const char* kUnitAtOesAFragmentShaderSrc =
    "#extension GL_OES_EGL_image_external : require\n"
    "precision mediump float;\n"
    "varying vec2 vTexCoordA;\n"
    "varying vec2 vTexCoordB;\n"
    "uniform samplerExternalOES uTextureA;\n"
    "uniform sampler2D uTextureB;\n"
    "uniform float uWeightB;\n"
    "void main() {\n"
    "    vec4 colorA = texture2D(uTextureA, vTexCoordA);\n"
    "    vec4 colorB = texture2D(uTextureB, vTexCoordB);\n"
    "    gl_FragColor = mix(colorA, colorB, uWeightB);\n"
    "}\n";

const char* kUnitAtOesBFragmentShaderSrc =
    "#extension GL_OES_EGL_image_external : require\n"
    "precision mediump float;\n"
    "varying vec2 vTexCoordA;\n"
    "varying vec2 vTexCoordB;\n"
    "uniform sampler2D uTextureA;\n"
    "uniform samplerExternalOES uTextureB;\n"
    "uniform float uWeightB;\n"
    "void main() {\n"
    "    vec4 colorA = texture2D(uTextureA, vTexCoordA);\n"
    "    vec4 colorB = texture2D(uTextureB, vTexCoordB);\n"
    "    gl_FragColor = mix(colorA, colorB, uWeightB);\n"
    "}\n";

const char* kUnitAtOesBothFragmentShaderSrc =
    "#extension GL_OES_EGL_image_external : require\n"
    "precision mediump float;\n"
    "varying vec2 vTexCoordA;\n"
    "varying vec2 vTexCoordB;\n"
    "uniform samplerExternalOES uTextureA;\n"
    "uniform samplerExternalOES uTextureB;\n"
    "uniform float uWeightB;\n"
    "void main() {\n"
    "    vec4 colorA = texture2D(uTextureA, vTexCoordA);\n"
    "    vec4 colorB = texture2D(uTextureB, vTexCoordB);\n"
    "    gl_FragColor = mix(colorA, colorB, uWeightB);\n"
    "}\n";

// Selects the fragment shader source matching the (textureTargetA,
// textureTargetB) permutation. Callers must have already validated both
// targets are kTextureTarget2D or kTextureTargetExternalOes.
const char* selectFragmentShaderSrc(uint32_t textureTargetA, uint32_t textureTargetB) {
    const bool oesA = textureTargetA == kTextureTargetExternalOes;
    const bool oesB = textureTargetB == kTextureTargetExternalOes;
    if (oesA && oesB) {
        return kUnitAtOesBothFragmentShaderSrc;
    }
    if (oesA) {
        return kUnitAtOesAFragmentShaderSrc;
    }
    if (oesB) {
        return kUnitAtOesBFragmentShaderSrc;
    }
    return kUnitAsFragmentShaderSrc;
}

// Compiles a shader of the given type; returns 0 on failure (deleting the
// shader object before returning).
GLuint compileUnitAsShader(GLenum type, const char* source) {
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

// Maps the four base UV corners [0,0], [1,0], [0,1], [1,1] through the given
// transform's push constants.
void mapCorners(const VideoFrameTransform& transform, GLfloat outUvs[4][2]) {
    const VideoTransformPushConstants pc = makeVideoTransformPushConstants(transform);
    const GLfloat kBaseUvs[4][2] = {
        {0.0f, 0.0f},
        {1.0f, 0.0f},
        {0.0f, 1.0f},
        {1.0f, 1.0f},
    };
    for (int i = 0; i < 4; ++i) {
        const GLfloat baseU = kBaseUvs[i][0];
        const GLfloat baseV = kBaseUvs[i][1];
        outUvs[i][0] = pc.uvTransform0[0] * baseU + pc.uvTransform0[1] * baseV + pc.uvTransform0[3];
        outUvs[i][1] = pc.uvTransform1[0] * baseU + pc.uvTransform1[1] * baseV + pc.uvTransform1[3];
    }
}

} // namespace
#endif

bool GlesTwoTextureCompositor::drawCompositedQuad(uint32_t textureA,
                                                   uint32_t textureTargetA,
                                                   uint32_t textureB,
                                                   uint32_t textureTargetB,
                                                   uint32_t width,
                                                   uint32_t height,
                                                   float weightB,
                                                   const VideoFrameTransform& transformA,
                                                   const VideoFrameTransform& transformB,
                                                   std::string* outError) {
    if (outError) {
        outError->clear();
    }

#if defined(__ANDROID__)
    if (textureA == 0 || textureB == 0 || width == 0 || height == 0) {
        if (outError) *outError = "gles_two_texture_compositor_invalid_argument";
        return false;
    }
    if (!std::isfinite(weightB)) {
        if (outError) *outError = "gles_two_texture_compositor_invalid_weight";
        return false;
    }
    const bool targetAValid = textureTargetA == kTextureTarget2D || textureTargetA == kTextureTargetExternalOes;
    const bool targetBValid = textureTargetB == kTextureTarget2D || textureTargetB == kTextureTargetExternalOes;
    if (!targetAValid || !targetBValid) {
        if (outError) *outError = "gles_two_texture_compositor_unsupported_texture_target";
        return false;
    }
    const GLenum glTextureTargetA = static_cast<GLenum>(textureTargetA);
    const GLenum glTextureTargetB = static_cast<GLenum>(textureTargetB);
    const float clampedWeightB = weightB < 0.0f ? 0.0f : (weightB > 1.0f ? 1.0f : weightB);

    GLuint vertexShader = compileUnitAsShader(GL_VERTEX_SHADER, kUnitAsVertexShaderSrc);
    GLuint fragmentShader = 0;
    GLuint program = 0;
    GLuint vertexBuffer = 0;
    bool ok = true;

    if (vertexShader == 0) {
        ok = false;
    } else {
        fragmentShader = compileUnitAsShader(
            GL_FRAGMENT_SHADER, selectFragmentShaderSrc(textureTargetA, textureTargetB));
        if (fragmentShader == 0) {
            ok = false;
        }
    }
    if (!ok && outError) {
        *outError = "gles_two_texture_compositor_shader_compile_failed";
    }

    if (ok) {
        program = glCreateProgram();
        if (program == 0) {
            ok = false;
            if (outError) *outError = "gles_two_texture_compositor_program_link_failed";
        } else {
            glAttachShader(program, vertexShader);
            glAttachShader(program, fragmentShader);
            glLinkProgram(program);
            GLint linked = GL_FALSE;
            glGetProgramiv(program, GL_LINK_STATUS, &linked);
            if (linked != GL_TRUE) {
                ok = false;
                if (outError) *outError = "gles_two_texture_compositor_program_link_failed";
            }
        }
    }

    if (ok) {
        // Full-window NDC quad interleaved as (x, y, uA, vA, uB, vB) per
        // vertex, triangle-strip order. Each texture's UVs are independently
        // remapped through its own VideoTransformPushConstants rows.
        GLfloat mappedUvsA[4][2];
        GLfloat mappedUvsB[4][2];
        mapCorners(transformA, mappedUvsA);
        mapCorners(transformB, mappedUvsB);

        const GLfloat kQuadVertices[] = {
            -1.0f, -1.0f, mappedUvsA[0][0], mappedUvsA[0][1], mappedUvsB[0][0], mappedUvsB[0][1],
             1.0f, -1.0f, mappedUvsA[1][0], mappedUvsA[1][1], mappedUvsB[1][0], mappedUvsB[1][1],
            -1.0f,  1.0f, mappedUvsA[2][0], mappedUvsA[2][1], mappedUvsB[2][0], mappedUvsB[2][1],
             1.0f,  1.0f, mappedUvsA[3][0], mappedUvsA[3][1], mappedUvsB[3][0], mappedUvsB[3][1],
        };

        glGenBuffers(1, &vertexBuffer);
        if (vertexBuffer == 0) {
            ok = false;
            if (outError) *outError = "gles_two_texture_compositor_draw_failed";
        } else {
            glBindBuffer(GL_ARRAY_BUFFER, vertexBuffer);
            glBufferData(GL_ARRAY_BUFFER, sizeof(kQuadVertices), kQuadVertices, GL_STATIC_DRAW);
            if (glGetError() != GL_NO_ERROR) {
                ok = false;
                if (outError) *outError = "gles_two_texture_compositor_draw_failed";
            }
        }
    }

    GLint positionLoc = -1;
    GLint texCoordALoc = -1;
    GLint texCoordBLoc = -1;

    if (ok) {
        glViewport(0, 0, static_cast<GLsizei>(width), static_cast<GLsizei>(height));
        glUseProgram(program);

        positionLoc = glGetAttribLocation(program, "aPosition");
        texCoordALoc = glGetAttribLocation(program, "aTexCoordA");
        texCoordBLoc = glGetAttribLocation(program, "aTexCoordB");
        GLint textureALoc = glGetUniformLocation(program, "uTextureA");
        GLint textureBLoc = glGetUniformLocation(program, "uTextureB");
        GLint weightBLoc = glGetUniformLocation(program, "uWeightB");
        if (positionLoc < 0 || texCoordALoc < 0 || texCoordBLoc < 0 ||
            textureALoc < 0 || textureBLoc < 0 || weightBLoc < 0) {
            ok = false;
            if (outError) *outError = "gles_two_texture_compositor_draw_failed";
        } else {
            const GLsizei stride = 6 * sizeof(GLfloat);
            glEnableVertexAttribArray(static_cast<GLuint>(positionLoc));
            glVertexAttribPointer(static_cast<GLuint>(positionLoc), 2, GL_FLOAT, GL_FALSE,
                                  stride, nullptr);
            glEnableVertexAttribArray(static_cast<GLuint>(texCoordALoc));
            glVertexAttribPointer(static_cast<GLuint>(texCoordALoc), 2, GL_FLOAT, GL_FALSE,
                                  stride, reinterpret_cast<const void*>(2 * sizeof(GLfloat)));
            glEnableVertexAttribArray(static_cast<GLuint>(texCoordBLoc));
            glVertexAttribPointer(static_cast<GLuint>(texCoordBLoc), 2, GL_FLOAT, GL_FALSE,
                                  stride, reinterpret_cast<const void*>(4 * sizeof(GLfloat)));

            glActiveTexture(GL_TEXTURE0);
            glBindTexture(glTextureTargetA, textureA);
            glUniform1i(textureALoc, 0);

            glActiveTexture(GL_TEXTURE1);
            glBindTexture(glTextureTargetB, textureB);
            glUniform1i(textureBLoc, 1);

            glUniform1f(weightBLoc, clampedWeightB);

            glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);

            if (glGetError() != GL_NO_ERROR) {
                ok = false;
                if (outError) *outError = "gles_two_texture_compositor_draw_failed";
            }

            glDisableVertexAttribArray(static_cast<GLuint>(texCoordBLoc));
            glDisableVertexAttribArray(static_cast<GLuint>(texCoordALoc));
            glDisableVertexAttribArray(static_cast<GLuint>(positionLoc));
        }

        glActiveTexture(GL_TEXTURE1);
        glBindTexture(glTextureTargetB, 0);
        glActiveTexture(GL_TEXTURE0);
        glBindTexture(glTextureTargetA, 0);
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
    (void)textureA;
    (void)textureTargetA;
    (void)textureB;
    (void)textureTargetB;
    (void)width;
    (void)height;
    (void)weightB;
    (void)transformA;
    (void)transformB;
    if (outError) {
        *outError = "gles_two_texture_compositor_unavailable_on_host";
    }
    return false;
#endif
}

} // namespace render
} // namespace vanguard
