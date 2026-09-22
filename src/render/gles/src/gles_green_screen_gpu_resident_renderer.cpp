// gles_green_screen_gpu_resident_renderer.cpp
// ANDROID-GREENSCREEN-GPU-RESIDENT: see gles_green_screen_gpu_resident_renderer.h.
//
// Adapted from the RND gpuzero gl_renderer.cpp GPU-resident loop
// (GPU downscale -> NEON float pack -> [interpreter] -> NEON mask pack ->
// guided filter -> optional temporal -> composite -> swap) with the
// AHardwareBuffer / EGLImage / CameraStreamReader ownership removed and all
// fixed RND geometry replaced by state derived from the output size, the
// layout rects and the SurfaceTexture transform matrix.

#include "gles_green_screen_gpu_resident_renderer.h"

#if defined(__ANDROID__)

#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES3/gl31.h>
#include <GLES2/gl2ext.h>
#include <android/log.h>
#include <android/native_window.h>

#if defined(__ARM_NEON) || defined(__ARM_NEON__)
#include <arm_neon.h>
#define VG_GS_GPU_RESIDENT_HAS_NEON 1
#else
#define VG_GS_GPU_RESIDENT_HAS_NEON 0
#endif

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstring>
#include <sstream>

#include "gles_green_screen_gpu_resident_shaders.h"

#ifndef EGL_OPENGL_ES3_BIT_KHR
#define EGL_OPENGL_ES3_BIT_KHR 0x0040
#endif
#ifndef EGL_CONTEXT_MAJOR_VERSION_KHR
#define EGL_CONTEXT_MAJOR_VERSION_KHR 0x3098
#endif
#ifndef EGL_CONTEXT_MINOR_VERSION_KHR
#define EGL_CONTEXT_MINOR_VERSION_KHR 0x30FB
#endif
#ifndef GL_TEXTURE_EXTERNAL_OES
#define GL_TEXTURE_EXTERNAL_OES 0x8D65
#endif

#define VG_GS_GPU_RESIDENT_TAG "VanguardGreenScreenGpuResident"
#define VG_GS_GPU_RESIDENT_LOGI(...) \
    __android_log_print(ANDROID_LOG_INFO, VG_GS_GPU_RESIDENT_TAG, __VA_ARGS__)
#define VG_GS_GPU_RESIDENT_LOGW(...) \
    __android_log_print(ANDROID_LOG_WARN, VG_GS_GPU_RESIDENT_TAG, __VA_ARGS__)

namespace vanguard {
namespace render {

namespace {

constexpr int kMaxAlphaLongSide = 1280;
constexpr int kMinAlphaLongSide = 64;
constexpr int kMinAlphaShortSide = 16;
constexpr int kComputeLocalSize = 16;

// Deterministic placeholder fill for the camera rect while green-screen is
// disabled and no camera frame has arrived (matches
// AndroidGreenScreenPreviewCompositor's CAMERA_PLACEHOLDER_*).
constexpr float kPlaceholderR = 0.13f;
constexpr float kPlaceholderG = 0.14f;
constexpr float kPlaceholderB = 0.17f;

using Clock = std::chrono::steady_clock;

float ElapsedMs(Clock::time_point start) {
    return std::chrono::duration<float, std::milli>(Clock::now() - start).count();
}

void SetError(std::string* error, const std::string& message) {
    if (error) *error = message;
    VG_GS_GPU_RESIDENT_LOGW("ANDROID_GREENSCREEN_GPU_RESIDENT_NATIVE_ERROR %s", message.c_str());
}

std::string EglErrorString(const char* where) {
    std::ostringstream ss;
    ss << where << " failed: egl=0x" << std::hex << eglGetError();
    return ss.str();
}

std::string GlErrorString(const char* where) {
    std::ostringstream ss;
    ss << where << " failed: gl=0x" << std::hex << glGetError();
    return ss.str();
}

GLuint CompileShader(GLenum type, const char* source, std::string* error) {
    GLuint shader = glCreateShader(type);
    if (shader == 0) {
        SetError(error, GlErrorString("glCreateShader"));
        return 0;
    }
    glShaderSource(shader, 1, &source, nullptr);
    glCompileShader(shader);
    GLint compiled = GL_FALSE;
    glGetShaderiv(shader, GL_COMPILE_STATUS, &compiled);
    if (compiled != GL_TRUE) {
        GLint logLength = 0;
        glGetShaderiv(shader, GL_INFO_LOG_LENGTH, &logLength);
        std::string log;
        if (logLength > 1) {
            log.resize(static_cast<size_t>(logLength));
            glGetShaderInfoLog(shader, logLength, nullptr, &log[0]);
        }
        std::ostringstream ss;
        ss << "shader compile failed (type=0x" << std::hex << type << "): " << log;
        SetError(error, ss.str());
        glDeleteShader(shader);
        return 0;
    }
    return shader;
}

GLuint LinkProgram(GLuint vertexOrCompute, GLuint fragment, std::string* error) {
    GLuint program = glCreateProgram();
    if (program == 0) {
        SetError(error, GlErrorString("glCreateProgram"));
        return 0;
    }
    glAttachShader(program, vertexOrCompute);
    if (fragment != 0) glAttachShader(program, fragment);
    glLinkProgram(program);
    GLint linked = GL_FALSE;
    glGetProgramiv(program, GL_LINK_STATUS, &linked);
    if (linked != GL_TRUE) {
        GLint logLength = 0;
        glGetProgramiv(program, GL_INFO_LOG_LENGTH, &logLength);
        std::string log;
        if (logLength > 1) {
            log.resize(static_cast<size_t>(logLength));
            glGetProgramInfoLog(program, logLength, nullptr, &log[0]);
        }
        SetError(error, "program link failed: " + log);
        glDeleteProgram(program);
        return 0;
    }
    return program;
}

GLuint CreateComputeProgram(const char* source, std::string* error) {
    GLuint shader = CompileShader(GL_COMPUTE_SHADER, source, error);
    if (shader == 0) return 0;
    GLuint program = LinkProgram(shader, 0, error);
    glDeleteShader(shader);
    return program;
}

GLuint CreateGraphicsProgram(const char* vertexSource, const char* fragmentSource, std::string* error) {
    GLuint vertex = CompileShader(GL_VERTEX_SHADER, vertexSource, error);
    if (vertex == 0) return 0;
    GLuint fragment = CompileShader(GL_FRAGMENT_SHADER, fragmentSource, error);
    if (fragment == 0) {
        glDeleteShader(vertex);
        return 0;
    }
    GLuint program = LinkProgram(vertex, fragment, error);
    glDeleteShader(vertex);
    glDeleteShader(fragment);
    return program;
}

bool HasGlExtension(const char* name) {
    GLint count = 0;
    glGetIntegerv(GL_NUM_EXTENSIONS, &count);
    for (GLint i = 0; i < count; ++i) {
        const GLubyte* ext = glGetStringi(GL_EXTENSIONS, static_cast<GLuint>(i));
        if (ext != nullptr && std::strcmp(reinterpret_cast<const char*>(ext), name) == 0) {
            return true;
        }
    }
    return false;
}

void SetTexture2DParams(GLenum minMag) {
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, static_cast<GLint>(minMag));
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, static_cast<GLint>(minMag));
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
}

void DeleteTextureQuietly(uint32_t* texture) {
    if (*texture != 0) {
        GLuint id = *texture;
        glDeleteTextures(1, &id);
        *texture = 0;
    }
}

void DeleteProgramQuietly(uint32_t* program) {
    if (*program != 0) {
        glDeleteProgram(*program);
        *program = 0;
    }
}

// RGBA8 (row-major, top-down) -> normalized float RGB (NHWC). NEON path
// mirrors RND rgba8ToRgbFloatNeon; the scalar tail also serves non-NEON ABIs.
void Rgba8ToRgbFloat(const uint8_t* rgba, float* rgbFloat, size_t numPixels) {
    const float scale = 1.0f / 255.0f;
    size_t i = 0;
#if VG_GS_GPU_RESIDENT_HAS_NEON
    for (; i + 8 <= numPixels; i += 8) {
        uint8x8x4_t rgbaVec = vld4_u8(rgba + i * 4);

        uint16x8_t r16 = vmovl_u8(rgbaVec.val[0]);
        uint16x8_t g16 = vmovl_u8(rgbaVec.val[1]);
        uint16x8_t b16 = vmovl_u8(rgbaVec.val[2]);

        float32x4_t rLo = vmulq_n_f32(vcvtq_f32_u32(vmovl_u16(vget_low_u16(r16))), scale);
        float32x4_t gLo = vmulq_n_f32(vcvtq_f32_u32(vmovl_u16(vget_low_u16(g16))), scale);
        float32x4_t bLo = vmulq_n_f32(vcvtq_f32_u32(vmovl_u16(vget_low_u16(b16))), scale);

        float32x4_t rHi = vmulq_n_f32(vcvtq_f32_u32(vmovl_u16(vget_high_u16(r16))), scale);
        float32x4_t gHi = vmulq_n_f32(vcvtq_f32_u32(vmovl_u16(vget_high_u16(g16))), scale);
        float32x4_t bHi = vmulq_n_f32(vcvtq_f32_u32(vmovl_u16(vget_high_u16(b16))), scale);

        float32x4x3_t rgbLo = {{rLo, gLo, bLo}};
        float32x4x3_t rgbHi = {{rHi, gHi, bHi}};
        vst3q_f32(rgbFloat + i * 3, rgbLo);
        vst3q_f32(rgbFloat + (i + 4) * 3, rgbHi);
    }
#endif
    for (; i < numPixels; ++i) {
        rgbFloat[i * 3 + 0] = static_cast<float>(rgba[i * 4 + 0]) * scale;
        rgbFloat[i * 3 + 1] = static_cast<float>(rgba[i * 4 + 1]) * scale;
        rgbFloat[i * 3 + 2] = static_cast<float>(rgba[i * 4 + 2]) * scale;
    }
}

// float32 mask in [0,1] -> uint8 (clamped). No row inversion: the shaders
// sample the coarse mask with a flipped v instead.
void FloatToU8Clamped(const float* in, uint8_t* out, size_t count) {
    size_t i = 0;
#if VG_GS_GPU_RESIDENT_HAS_NEON
    const float32x4_t zero = vdupq_n_f32(0.0f);
    const float32x4_t one = vdupq_n_f32(1.0f);
    for (; i + 8 <= count; i += 8) {
        float32x4_t f0 = vld1q_f32(in + i);
        float32x4_t f1 = vld1q_f32(in + i + 4);
        f0 = vminq_f32(vmaxq_f32(f0, zero), one);
        f1 = vminq_f32(vmaxq_f32(f1, zero), one);
        uint32x4_t u0 = vcvtq_u32_f32(vmulq_n_f32(f0, 255.0f));
        uint32x4_t u1 = vcvtq_u32_f32(vmulq_n_f32(f1, 255.0f));
        uint16x8_t u16 = vcombine_u16(vqmovn_u32(u0), vqmovn_u32(u1));
        uint8x8_t u8 = vqmovn_u16(u16);
        vst1_u8(out + i, u8);
    }
#endif
    for (; i < count; ++i) {
        float v = in[i];
        if (!(v >= 0.0f)) v = 0.0f;  // also maps NaN to 0
        if (v > 1.0f) v = 1.0f;
        out[i] = static_cast<uint8_t>(v * 255.0f);
    }
}

}  // namespace

// ---------------------------------------------------------------------------
// Construction / destruction
// ---------------------------------------------------------------------------

GlesGreenScreenGpuResidentRenderer::GlesGreenScreenGpuResidentRenderer() {
    for (int i = 0; i < 16; ++i) cameraStMatrix_[i] = (i % 5 == 0) ? 1.0f : 0.0f;
    for (int i = 0; i < 16; ++i) backgroundVideoStMatrix_[i] = (i % 5 == 0) ? 1.0f : 0.0f;
}

GlesGreenScreenGpuResidentRenderer::~GlesGreenScreenGpuResidentRenderer() {
    Destroy();
}

// ---------------------------------------------------------------------------
// Lifecycle
// ---------------------------------------------------------------------------

bool GlesGreenScreenGpuResidentRenderer::Initialize(std::string* error) {
    if (initialized_) return true;
    if (!CreateEglCore(error)) {
        Destroy();
        return false;
    }
    if (!CreatePrograms(error) || !CreateStaticObjects(error)) {
        Destroy();
        return false;
    }
    GLenum glErr = glGetError();
    if (glErr != GL_NO_ERROR) {
        std::ostringstream ss;
        ss << "GL error after bootstrap: 0x" << std::hex << glErr;
        SetError(error, ss.str());
        Destroy();
        return false;
    }
    initialized_ = true;
    VG_GS_GPU_RESIDENT_LOGI(
        "ANDROID_GREENSCREEN_GPU_RESIDENT_NATIVE_READY cameraTexture=%u neon=%d",
        cameraTexture_, VG_GS_GPU_RESIDENT_HAS_NEON);
    return true;
}

bool GlesGreenScreenGpuResidentRenderer::CreateEglCore(std::string* error) {
    EGLDisplay display = eglGetDisplay(EGL_DEFAULT_DISPLAY);
    if (display == EGL_NO_DISPLAY) {
        SetError(error, EglErrorString("eglGetDisplay"));
        return false;
    }
    EGLint major = 0;
    EGLint minor = 0;
    if (!eglInitialize(display, &major, &minor)) {
        SetError(error, EglErrorString("eglInitialize"));
        return false;
    }
    eglDisplay_ = display;

    const EGLint configAttribs[] = {
        EGL_RENDERABLE_TYPE, EGL_OPENGL_ES3_BIT_KHR,
        EGL_SURFACE_TYPE, EGL_WINDOW_BIT | EGL_PBUFFER_BIT,
        EGL_RED_SIZE, 8,
        EGL_GREEN_SIZE, 8,
        EGL_BLUE_SIZE, 8,
        EGL_ALPHA_SIZE, 8,
        EGL_DEPTH_SIZE, 0,
        EGL_NONE,
    };
    EGLConfig config = nullptr;
    EGLint numConfigs = 0;
    if (!eglChooseConfig(display, configAttribs, &config, 1, &numConfigs) || numConfigs < 1 ||
        config == nullptr) {
        SetError(error, EglErrorString("eglChooseConfig(ES3 window|pbuffer RGBA8)"));
        return false;
    }
    eglConfig_ = config;

    // ES 3.1 is required for the compute passes. Ask for 3.1 explicitly first
    // (EGL_KHR_create_context minor attribute), then fall back to a plain ES3
    // request and verify the actual version below.
    const EGLint contextAttribs31[] = {
        EGL_CONTEXT_MAJOR_VERSION_KHR, 3,
        EGL_CONTEXT_MINOR_VERSION_KHR, 1,
        EGL_NONE,
    };
    EGLContext context = eglCreateContext(display, config, EGL_NO_CONTEXT, contextAttribs31);
    if (context == EGL_NO_CONTEXT) {
        const EGLint contextAttribs3[] = {EGL_CONTEXT_CLIENT_VERSION, 3, EGL_NONE};
        context = eglCreateContext(display, config, EGL_NO_CONTEXT, contextAttribs3);
    }
    if (context == EGL_NO_CONTEXT) {
        SetError(error, EglErrorString("eglCreateContext(ES3)"));
        return false;
    }
    eglContext_ = context;

    const EGLint pbufferAttribs[] = {EGL_WIDTH, 1, EGL_HEIGHT, 1, EGL_NONE};
    EGLSurface pbuffer = eglCreatePbufferSurface(display, config, pbufferAttribs);
    if (pbuffer == EGL_NO_SURFACE) {
        SetError(error, EglErrorString("eglCreatePbufferSurface(1x1)"));
        return false;
    }
    eglPbufferSurface_ = pbuffer;

    if (!eglMakeCurrent(display, pbuffer, pbuffer, context)) {
        SetError(error, EglErrorString("eglMakeCurrent(pbuffer)"));
        return false;
    }

    GLint glMajor = 0;
    GLint glMinor = 0;
    glGetIntegerv(GL_MAJOR_VERSION, &glMajor);
    glGetIntegerv(GL_MINOR_VERSION, &glMinor);
    if (glMajor < 3 || (glMajor == 3 && glMinor < 1)) {
        std::ostringstream ss;
        ss << "OpenGL ES 3.1 required for compute passes; context reports " << glMajor << "." << glMinor;
        SetError(error, ss.str());
        return false;
    }
    if (!HasGlExtension("GL_OES_EGL_image_external_essl3")) {
        SetError(error, "GL_OES_EGL_image_external_essl3 not supported");
        return false;
    }
    VG_GS_GPU_RESIDENT_LOGI(
        "ANDROID_GREENSCREEN_GPU_RESIDENT_NATIVE_EGL egl=%d.%d gles=%d.%d renderer=%s",
        major, minor, glMajor, glMinor,
        reinterpret_cast<const char*>(glGetString(GL_RENDERER)));
    return true;
}

bool GlesGreenScreenGpuResidentRenderer::CreatePrograms(std::string* error) {
    namespace shaders = green_screen_gpu_resident_shaders;

    downscaleProgram_ = CreateComputeProgram(shaders::kDownscaleComputeShader, error);
    if (downscaleProgram_ == 0) return false;
    downscaleModelSizeLoc_ = glGetUniformLocation(downscaleProgram_, "uModelSize");
    downscaleStMatrixLoc_ = glGetUniformLocation(downscaleProgram_, "uCameraStMatrix");

    guidedProgram_ = CreateComputeProgram(shaders::kGuidedFilterComputeShader, error);
    if (guidedProgram_ == 0) return false;
    guidedAlphaResolutionLoc_ = glGetUniformLocation(guidedProgram_, "uAlphaResolution");
    guidedStMatrixLoc_ = glGetUniformLocation(guidedProgram_, "uCameraStMatrix");
    guidedFilterEnabledLoc_ = glGetUniformLocation(guidedProgram_, "uFilterEnabled");

    temporalProgram_ = CreateComputeProgram(shaders::kTemporalStabilizerComputeShader, error);
    if (temporalProgram_ == 0) return false;
    temporalAlphaResolutionLoc_ = glGetUniformLocation(temporalProgram_, "uAlphaResolution");

    compositeProgram_ = CreateGraphicsProgram(
        shaders::kCompositeVertexShader, shaders::kCompositeFragmentShader, error);
    if (compositeProgram_ == 0) return false;
    compositeCameraTextureLoc_ = glGetUniformLocation(compositeProgram_, "uCameraTexture");
    compositeAlphaTextureLoc_ = glGetUniformLocation(compositeProgram_, "uAlphaTexture");
    compositeBackgroundImageLoc_ = glGetUniformLocation(compositeProgram_, "uBackgroundImage");
    compositeAlphaResolutionLoc_ = glGetUniformLocation(compositeProgram_, "uAlphaResolution");
    compositeStMatrixLoc_ = glGetUniformLocation(compositeProgram_, "uCameraStMatrix");
    compositeSourceRectLoc_ = glGetUniformLocation(compositeProgram_, "uSourceRect");
    compositeCameraScissorLoc_ = glGetUniformLocation(compositeProgram_, "uCameraScissor");
    compositeCameraViewportLoc_ = glGetUniformLocation(compositeProgram_, "uCameraViewport");
    compositeBackgroundImageRectLoc_ = glGetUniformLocation(compositeProgram_, "uBackgroundImageRect");
    compositeBackgroundVideoTextureLoc_ = glGetUniformLocation(compositeProgram_, "uBackgroundVideoTexture");
    compositeBackgroundVideoStMatrixLoc_ = glGetUniformLocation(compositeProgram_, "uBackgroundVideoStMatrix");
    compositeBackgroundVideoRectLoc_ = glGetUniformLocation(compositeProgram_, "uBackgroundVideoRect");
    compositeBackgroundColorLoc_ = glGetUniformLocation(compositeProgram_, "uBackgroundColor");
    compositePlaceholderColorLoc_ = glGetUniformLocation(compositeProgram_, "uPlaceholderColor");
    compositeBackgroundModeLoc_ = glGetUniformLocation(compositeProgram_, "uBackgroundMode");
    compositeCameraModeLoc_ = glGetUniformLocation(compositeProgram_, "uCameraMode");
    compositeDespillEnabledLoc_ = glGetUniformLocation(compositeProgram_, "uDespillEnabled");
    return true;
}

bool GlesGreenScreenGpuResidentRenderer::CreateStaticObjects(std::string* error) {
    // Camera external OES texture (SurfaceTexture target, driven by Kotlin).
    GLuint cameraTex = 0;
    glGenTextures(1, &cameraTex);
    if (cameraTex == 0) {
        SetError(error, GlErrorString("glGenTextures(camera OES)"));
        return false;
    }
    cameraTexture_ = cameraTex;
    glBindTexture(GL_TEXTURE_EXTERNAL_OES, cameraTexture_);
    glTexParameteri(GL_TEXTURE_EXTERNAL_OES, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_EXTERNAL_OES, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_EXTERNAL_OES, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_EXTERNAL_OES, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    glBindTexture(GL_TEXTURE_EXTERNAL_OES, 0);

    // Full-screen quad (triangle strip, position only).
    const float quadVertices[] = {
        -1.0f, -1.0f,
         1.0f, -1.0f,
        -1.0f,  1.0f,
         1.0f,  1.0f,
    };
    GLuint vao = 0;
    GLuint vbo = 0;
    glGenVertexArrays(1, &vao);
    glGenBuffers(1, &vbo);
    if (vao == 0 || vbo == 0) {
        SetError(error, GlErrorString("glGenVertexArrays/glGenBuffers(quad)"));
        return false;
    }
    quadVao_ = vao;
    quadVbo_ = vbo;
    glBindVertexArray(quadVao_);
    glBindBuffer(GL_ARRAY_BUFFER, quadVbo_);
    glBufferData(GL_ARRAY_BUFFER, sizeof(quadVertices), quadVertices, GL_STATIC_DRAW);
    glEnableVertexAttribArray(0);
    glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, 2 * sizeof(float), nullptr);
    glBindVertexArray(0);
    glBindBuffer(GL_ARRAY_BUFFER, 0);
    return true;
}

bool GlesGreenScreenGpuResidentRenderer::ConfigureModelInput(int width, int height, std::string* error) {
    if (!initialized_) {
        SetError(error, "ConfigureModelInput before Initialize");
        return false;
    }
    if (width <= 0 || height <= 0) {
        SetError(error, "ConfigureModelInput: non-positive model size");
        return false;
    }
    if (modelInputTexture_ != 0 && width == modelInputWidth_ && height == modelInputHeight_) return true;

    if (modelInputFbo_ != 0) {
        GLuint fbo = modelInputFbo_;
        glDeleteFramebuffers(1, &fbo);
        modelInputFbo_ = 0;
    }
    DeleteTextureQuietly(&modelInputTexture_);

    GLuint tex = 0;
    glGenTextures(1, &tex);
    if (tex == 0) {
        SetError(error, GlErrorString("glGenTextures(model input)"));
        return false;
    }
    modelInputTexture_ = tex;
    glBindTexture(GL_TEXTURE_2D, modelInputTexture_);
    glTexStorage2D(GL_TEXTURE_2D, 1, GL_RGBA8, width, height);
    SetTexture2DParams(GL_LINEAR);
    glBindTexture(GL_TEXTURE_2D, 0);

    GLuint fbo = 0;
    glGenFramebuffers(1, &fbo);
    if (fbo == 0) {
        SetError(error, GlErrorString("glGenFramebuffers(model input)"));
        return false;
    }
    modelInputFbo_ = fbo;
    glBindFramebuffer(GL_FRAMEBUFFER, modelInputFbo_);
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, modelInputTexture_, 0);
    GLenum status = glCheckFramebufferStatus(GL_FRAMEBUFFER);
    glBindFramebuffer(GL_FRAMEBUFFER, 0);
    if (status != GL_FRAMEBUFFER_COMPLETE) {
        std::ostringstream ss;
        ss << "model input FBO incomplete: 0x" << std::hex << status;
        SetError(error, ss.str());
        return false;
    }

    modelInputWidth_ = width;
    modelInputHeight_ = height;
    modelInputRgba_.assign(static_cast<size_t>(width) * static_cast<size_t>(height) * 4u, 0);
    VG_GS_GPU_RESIDENT_LOGI("ANDROID_GREENSCREEN_GPU_RESIDENT_NATIVE_MODEL_INPUT %dx%d", width, height);
    return true;
}

void GlesGreenScreenGpuResidentRenderer::Destroy() {
    if (eglDisplay_ == nullptr) {
        initialized_ = false;
        return;
    }
    EGLDisplay display = static_cast<EGLDisplay>(eglDisplay_);

    DestroyWindowSurfaceQuietly();

    if (eglContext_ != nullptr) {
        MakePbufferCurrentQuietly();
        DestroyGlObjects();
    }

    eglMakeCurrent(display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
    if (eglPbufferSurface_ != nullptr) {
        eglDestroySurface(display, static_cast<EGLSurface>(eglPbufferSurface_));
        eglPbufferSurface_ = nullptr;
    }
    if (eglContext_ != nullptr) {
        eglDestroyContext(display, static_cast<EGLContext>(eglContext_));
        eglContext_ = nullptr;
    }
    eglTerminate(display);
    eglDisplay_ = nullptr;
    eglConfig_ = nullptr;
    initialized_ = false;
    outputWidth_ = 0;
    outputHeight_ = 0;
}

void GlesGreenScreenGpuResidentRenderer::DestroyGlObjects() {
    DeleteProgramQuietly(&downscaleProgram_);
    DeleteProgramQuietly(&guidedProgram_);
    DeleteProgramQuietly(&temporalProgram_);
    DeleteProgramQuietly(&compositeProgram_);
    if (modelInputFbo_ != 0) {
        GLuint fbo = modelInputFbo_;
        glDeleteFramebuffers(1, &fbo);
        modelInputFbo_ = 0;
    }
    DeleteTextureQuietly(&modelInputTexture_);
    DeleteTextureQuietly(&coarseAlphaTexture_);
    DeleteTextureQuietly(&alphaPingTexture_);
    DeleteTextureQuietly(&alphaPongTexture_);
    DeleteTextureQuietly(&alphaHistoryTexture_);
    DeleteTextureQuietly(&backgroundImageTexture_);
    DeleteTextureQuietly(&backgroundVideoTexture_);
    DeleteTextureQuietly(&cameraTexture_);
    if (quadVbo_ != 0) {
        GLuint vbo = quadVbo_;
        glDeleteBuffers(1, &vbo);
        quadVbo_ = 0;
    }
    if (quadVao_ != 0) {
        GLuint vao = quadVao_;
        glDeleteVertexArrays(1, &vao);
        quadVao_ = 0;
    }
    modelInputWidth_ = 0;
    modelInputHeight_ = 0;
    coarseAlphaWidth_ = 0;
    coarseAlphaHeight_ = 0;
    alphaWidth_ = 0;
    alphaHeight_ = 0;
    activeAlphaTexture_ = 0;
    hasCoarseMask_ = false;
    hasRefinedAlpha_ = false;
    backgroundImageWidth_ = 0;
    backgroundImageHeight_ = 0;
    backgroundVideoWidth_ = 0;
    backgroundVideoHeight_ = 0;
}

bool GlesGreenScreenGpuResidentRenderer::MakeCurrent() {
    if (eglDisplay_ == nullptr || eglContext_ == nullptr) return false;
    EGLSurface surface = eglWindowSurface_ != nullptr
        ? static_cast<EGLSurface>(eglWindowSurface_)
        : static_cast<EGLSurface>(eglPbufferSurface_);
    if (surface == nullptr) return false;
    if (eglGetCurrentContext() == static_cast<EGLContext>(eglContext_) &&
        eglGetCurrentSurface(EGL_DRAW) == surface) {
        return true;
    }
    return eglMakeCurrent(static_cast<EGLDisplay>(eglDisplay_), surface, surface,
                          static_cast<EGLContext>(eglContext_)) == EGL_TRUE;
}

void GlesGreenScreenGpuResidentRenderer::MakePbufferCurrentQuietly() {
    if (eglDisplay_ == nullptr || eglContext_ == nullptr || eglPbufferSurface_ == nullptr) return;
    eglMakeCurrent(static_cast<EGLDisplay>(eglDisplay_), static_cast<EGLSurface>(eglPbufferSurface_),
                   static_cast<EGLSurface>(eglPbufferSurface_), static_cast<EGLContext>(eglContext_));
}

// ---------------------------------------------------------------------------
// Output window
// ---------------------------------------------------------------------------

bool GlesGreenScreenGpuResidentRenderer::AttachOutputWindow(void* nativeWindow, int widthPx, int heightPx,
                                                            std::string* error) {
    if (!initialized_) {
        SetError(error, "AttachOutputWindow before Initialize");
        return false;
    }
    if (nativeWindow == nullptr || widthPx <= 0 || heightPx <= 0) {
        SetError(error, "AttachOutputWindow: invalid window or size");
        return false;
    }
    DestroyWindowSurfaceQuietly();

    ANativeWindow* window = static_cast<ANativeWindow*>(nativeWindow);
    ANativeWindow_acquire(window);
    EGLDisplay display = static_cast<EGLDisplay>(eglDisplay_);
    EGLSurface surface = eglCreateWindowSurface(display, static_cast<EGLConfig>(eglConfig_), window, nullptr);
    if (surface == EGL_NO_SURFACE) {
        SetError(error, EglErrorString("eglCreateWindowSurface"));
        ANativeWindow_release(window);
        MakePbufferCurrentQuietly();
        return false;
    }
    if (!eglMakeCurrent(display, surface, surface, static_cast<EGLContext>(eglContext_))) {
        SetError(error, EglErrorString("eglMakeCurrent(window)"));
        eglDestroySurface(display, surface);
        ANativeWindow_release(window);
        MakePbufferCurrentQuietly();
        return false;
    }
    eglWindowSurface_ = surface;
    nativeWindow_ = window;
    outputWidth_ = widthPx;
    outputHeight_ = heightPx;
    return true;
}

void GlesGreenScreenGpuResidentRenderer::DetachOutputWindow() {
    DestroyWindowSurfaceQuietly();
    outputWidth_ = 0;
    outputHeight_ = 0;
}

void GlesGreenScreenGpuResidentRenderer::DestroyWindowSurfaceQuietly() {
    if (eglDisplay_ == nullptr) return;
    EGLDisplay display = static_cast<EGLDisplay>(eglDisplay_);
    void* surface = eglWindowSurface_;
    eglWindowSurface_ = nullptr;
    MakePbufferCurrentQuietly();
    if (surface != nullptr) {
        eglDestroySurface(display, static_cast<EGLSurface>(surface));
    }
    if (nativeWindow_ != nullptr) {
        ANativeWindow_release(static_cast<ANativeWindow*>(nativeWindow_));
        nativeWindow_ = nullptr;
    }
}

// ---------------------------------------------------------------------------
// State
// ---------------------------------------------------------------------------

void GlesGreenScreenGpuResidentRenderer::SetLayout(const GlesGreenScreenGpuResidentRect& sourceRect,
                                                   const GlesGreenScreenGpuResidentRect& cameraRect) {
    sourceRect_ = sourceRect;
    cameraRect_ = cameraRect;
    hasLayout_ = true;
}

void GlesGreenScreenGpuResidentRenderer::SetCameraTransform(const float stMatrixColumnMajor[16],
                                                            float cameraUprightAspect) {
    std::memcpy(cameraStMatrix_, stMatrixColumnMajor, sizeof(cameraStMatrix_));
    if (std::isfinite(cameraUprightAspect) && cameraUprightAspect > 0.0f) {
        cameraUprightAspect_ = cameraUprightAspect;
    }
}

void GlesGreenScreenGpuResidentRenderer::SetBackgroundBlack() {
    backgroundMode_ = BackgroundMode::kBlack;
}

void GlesGreenScreenGpuResidentRenderer::SetBackgroundSolidColor(uint32_t argb) {
    backgroundColor_[0] = static_cast<float>((argb >> 16) & 0xFFu) / 255.0f;
    backgroundColor_[1] = static_cast<float>((argb >> 8) & 0xFFu) / 255.0f;
    backgroundColor_[2] = static_cast<float>(argb & 0xFFu) / 255.0f;
    backgroundColor_[3] = static_cast<float>((argb >> 24) & 0xFFu) / 255.0f;
    backgroundMode_ = BackgroundMode::kSolidColor;
}

bool GlesGreenScreenGpuResidentRenderer::SetBackgroundImage(const uint8_t* rgba, int width, int height,
                                                            bool aspectFill, std::string* error) {
    if (!initialized_) {
        SetError(error, "SetBackgroundImage before Initialize");
        return false;
    }
    if (rgba == nullptr || width <= 0 || height <= 0) {
        SetError(error, "SetBackgroundImage: invalid pixels or size");
        return false;
    }
    if (!MakeCurrent()) {
        SetError(error, EglErrorString("eglMakeCurrent(background image)"));
        return false;
    }
    GLint maxTextureSize = 0;
    glGetIntegerv(GL_MAX_TEXTURE_SIZE, &maxTextureSize);
    if (maxTextureSize > 0 && (width > maxTextureSize || height > maxTextureSize)) {
        std::ostringstream ss;
        ss << "SetBackgroundImage: " << width << "x" << height << " exceeds GL_MAX_TEXTURE_SIZE " << maxTextureSize;
        SetError(error, ss.str());
        return false;
    }
    DeleteTextureQuietly(&backgroundImageTexture_);
    GLuint tex = 0;
    glGenTextures(1, &tex);
    if (tex == 0) {
        SetError(error, GlErrorString("glGenTextures(background image)"));
        return false;
    }
    glBindTexture(GL_TEXTURE_2D, tex);
    SetTexture2DParams(GL_LINEAR);
    GLint previousAlignment = 4;
    glGetIntegerv(GL_UNPACK_ALIGNMENT, &previousAlignment);
    glPixelStorei(GL_UNPACK_ALIGNMENT, 1);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, width, height, 0, GL_RGBA, GL_UNSIGNED_BYTE, rgba);
    glPixelStorei(GL_UNPACK_ALIGNMENT, previousAlignment);
    glBindTexture(GL_TEXTURE_2D, 0);
    GLenum glErr = glGetError();
    if (glErr != GL_NO_ERROR) {
        std::ostringstream ss;
        ss << "SetBackgroundImage: glTexImage2D failed: 0x" << std::hex << glErr;
        SetError(error, ss.str());
        glDeleteTextures(1, &tex);
        return false;
    }
    backgroundImageTexture_ = tex;
    backgroundImageWidth_ = width;
    backgroundImageHeight_ = height;
    backgroundImageAspectFill_ = aspectFill;
    backgroundMode_ = BackgroundMode::kImage;
    return true;
}

void GlesGreenScreenGpuResidentRenderer::SetBackgroundImageScaleMode(bool aspectFill) {
    backgroundImageAspectFill_ = aspectFill;
}

void GlesGreenScreenGpuResidentRenderer::ClearBackgroundImage() {
    if (eglContext_ != nullptr && MakeCurrent()) {
        DeleteTextureQuietly(&backgroundImageTexture_);
    }
    backgroundImageTexture_ = 0;
    backgroundImageWidth_ = 0;
    backgroundImageHeight_ = 0;
    if (backgroundMode_ == BackgroundMode::kImage) backgroundMode_ = BackgroundMode::kBlack;
}

uint32_t GlesGreenScreenGpuResidentRenderer::EnsureBackgroundVideoTexture(std::string* error) {
    if (!initialized_) {
        SetError(error, "EnsureBackgroundVideoTexture before Initialize");
        return 0;
    }
    if (backgroundVideoTexture_ != 0) return backgroundVideoTexture_;
    if (!MakeCurrent()) {
        SetError(error, EglErrorString("eglMakeCurrent(background video texture)"));
        return 0;
    }
    GLuint tex = 0;
    glGenTextures(1, &tex);
    if (tex == 0) {
        SetError(error, GlErrorString("glGenTextures(background video OES)"));
        return 0;
    }
    glBindTexture(GL_TEXTURE_EXTERNAL_OES, tex);
    glTexParameteri(GL_TEXTURE_EXTERNAL_OES, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_EXTERNAL_OES, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_EXTERNAL_OES, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_EXTERNAL_OES, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    glBindTexture(GL_TEXTURE_EXTERNAL_OES, 0);
    backgroundVideoTexture_ = tex;
    return backgroundVideoTexture_;
}

void GlesGreenScreenGpuResidentRenderer::SetBackgroundVideoFrame(const float stMatrixColumnMajor[16],
                                                                  int videoWidth, int videoHeight,
                                                                  int rotationDegrees, bool aspectFill) {
    std::memcpy(backgroundVideoStMatrix_, stMatrixColumnMajor, sizeof(backgroundVideoStMatrix_));
    if (videoWidth > 0 && videoHeight > 0) {
        backgroundVideoWidth_ = videoWidth;
        backgroundVideoHeight_ = videoHeight;
    }
    backgroundVideoRotationDegrees_ = rotationDegrees;
    backgroundVideoAspectFill_ = aspectFill;
    backgroundMode_ = BackgroundMode::kVideo;
}

void GlesGreenScreenGpuResidentRenderer::ClearBackgroundVideo() {
    if (eglContext_ != nullptr && MakeCurrent()) {
        DeleteTextureQuietly(&backgroundVideoTexture_);
    }
    backgroundVideoTexture_ = 0;
    backgroundVideoWidth_ = 0;
    backgroundVideoHeight_ = 0;
    backgroundVideoRotationDegrees_ = 0;
    if (backgroundMode_ == BackgroundMode::kVideo) backgroundMode_ = BackgroundMode::kBlack;
}

void GlesGreenScreenGpuResidentRenderer::SetFilterToggles(bool guidedFilter, bool temporalStabilizer, bool despill) {
    guidedFilterEnabled_ = guidedFilter;
    temporalEnabled_ = temporalStabilizer;
    despillEnabled_ = despill;
}

// ---------------------------------------------------------------------------
// Geometry (mirrors AndroidGreenScreenPreviewCompositor's toGlRect /
// cameraAspectFillViewport / backgroundImageAspectViewport in float).
// ---------------------------------------------------------------------------

GlesGreenScreenGpuResidentRenderer::GlRect GlesGreenScreenGpuResidentRenderer::ToGl(
    const GlesGreenScreenGpuResidentRect& rect) const {
    GlRect out;
    out.x = rect.left;
    out.y = static_cast<float>(outputHeight_) - (rect.top + rect.height);
    out.w = rect.width;
    out.h = rect.height;
    return out;
}

GlesGreenScreenGpuResidentRenderer::GlRect GlesGreenScreenGpuResidentRenderer::CameraAspectFillViewport(
    const GlesGreenScreenGpuResidentRect& rect) const {
    if (rect.width <= 0.0f || rect.height <= 0.0f) return ToGl(rect);
    const float cameraAspect = cameraUprightAspect_;
    const float rectAspect = rect.width / rect.height;
    float drawnW;
    float drawnH;
    if (cameraAspect > rectAspect) {
        drawnH = rect.height;
        drawnW = rect.height * cameraAspect;
    } else {
        drawnW = rect.width;
        drawnH = rect.width / cameraAspect;
    }
    GlesGreenScreenGpuResidentRect inflated;
    inflated.left = rect.left - (drawnW - rect.width) / 2.0f;
    inflated.top = rect.top - (drawnH - rect.height) / 2.0f;
    inflated.width = drawnW;
    inflated.height = drawnH;
    return ToGl(inflated);
}

GlesGreenScreenGpuResidentRenderer::GlRect GlesGreenScreenGpuResidentRenderer::BackgroundImageRect(
    const GlesGreenScreenGpuResidentRect& rect) const {
    if (backgroundImageWidth_ <= 0 || backgroundImageHeight_ <= 0 || rect.width <= 0.0f || rect.height <= 0.0f) {
        return ToGl(rect);
    }
    const float imageAspect = static_cast<float>(backgroundImageWidth_) / static_cast<float>(backgroundImageHeight_);
    const float rectAspect = rect.width / rect.height;
    const bool cover = backgroundImageAspectFill_;
    const bool matchHeightBasis = cover ? (imageAspect > rectAspect) : (imageAspect <= rectAspect);
    float drawnW;
    float drawnH;
    if (matchHeightBasis) {
        drawnH = rect.height;
        drawnW = rect.height * imageAspect;
    } else {
        drawnW = rect.width;
        drawnH = rect.width / imageAspect;
    }
    GlesGreenScreenGpuResidentRect drawn;
    drawn.left = rect.left - (drawnW - rect.width) / 2.0f;
    drawn.top = rect.top - (drawnH - rect.height) / 2.0f;
    drawn.width = drawnW;
    drawn.height = drawnH;
    return ToGl(drawn);
}

GlesGreenScreenGpuResidentRenderer::GlRect GlesGreenScreenGpuResidentRenderer::BackgroundVideoRect(
    const GlesGreenScreenGpuResidentRect& rect) const {
    if (backgroundVideoWidth_ <= 0 || backgroundVideoHeight_ <= 0 || rect.width <= 0.0f || rect.height <= 0.0f) {
        return ToGl(rect);
    }
    // For a 90/270-degree source rotation the raw decoded width/height are
    // swapped first so the aspect used here matches the upright display
    // orientation rather than the sideways decode buffer, mirroring the CPU
    // fallback compositor's backgroundVideoAspectViewport.
    int displayWidth = backgroundVideoWidth_;
    int displayHeight = backgroundVideoHeight_;
    if (backgroundVideoRotationDegrees_ == 90 || backgroundVideoRotationDegrees_ == 270) {
        displayWidth = backgroundVideoHeight_;
        displayHeight = backgroundVideoWidth_;
    }
    const float videoAspect = static_cast<float>(displayWidth) / static_cast<float>(displayHeight);
    const float rectAspect = rect.width / rect.height;
    const bool cover = backgroundVideoAspectFill_;
    const bool matchHeightBasis = cover ? (videoAspect > rectAspect) : (videoAspect <= rectAspect);
    float drawnW;
    float drawnH;
    if (matchHeightBasis) {
        drawnH = rect.height;
        drawnW = rect.height * videoAspect;
    } else {
        drawnW = rect.width;
        drawnH = rect.width / videoAspect;
    }
    GlesGreenScreenGpuResidentRect drawn;
    drawn.left = rect.left - (drawnW - rect.width) / 2.0f;
    drawn.top = rect.top - (drawnH - rect.height) / 2.0f;
    drawn.width = drawnW;
    drawn.height = drawnH;
    return ToGl(drawn);
}

void GlesGreenScreenGpuResidentRenderer::DeriveAlphaResolution(int* width, int* height) const {
    int base = std::max(outputWidth_, outputHeight_);
    base = std::max(kMinAlphaLongSide, std::min(kMaxAlphaLongSide, base));
    float aspect = cameraUprightAspect_;
    if (!(aspect > 0.0f) || !std::isfinite(aspect)) aspect = 1080.0f / 1920.0f;
    if (aspect < 1.0f) {
        *height = base;
        *width = std::max(kMinAlphaShortSide, static_cast<int>(std::lround(static_cast<float>(base) * aspect)));
    } else {
        *width = base;
        *height = std::max(kMinAlphaShortSide, static_cast<int>(std::lround(static_cast<float>(base) / aspect)));
    }
}

// ---------------------------------------------------------------------------
// Lazy textures
// ---------------------------------------------------------------------------

bool GlesGreenScreenGpuResidentRenderer::EnsureAlphaTextures(int width, int height, std::string* error) {
    if (alphaPingTexture_ != 0 && width == alphaWidth_ && height == alphaHeight_) return true;
    DeleteTextureQuietly(&alphaPingTexture_);
    DeleteTextureQuietly(&alphaPongTexture_);
    DeleteTextureQuietly(&alphaHistoryTexture_);
    activeAlphaTexture_ = 0;
    hasRefinedAlpha_ = false;

    std::vector<float> zeros(static_cast<size_t>(width) * static_cast<size_t>(height), 0.0f);
    uint32_t* slots[3] = {&alphaPingTexture_, &alphaPongTexture_, &alphaHistoryTexture_};
    for (uint32_t* slot : slots) {
        GLuint tex = 0;
        glGenTextures(1, &tex);
        if (tex == 0) {
            SetError(error, GlErrorString("glGenTextures(alpha)"));
            return false;
        }
        *slot = tex;
        glBindTexture(GL_TEXTURE_2D, tex);
        glTexStorage2D(GL_TEXTURE_2D, 1, GL_R32F, width, height);
        SetTexture2DParams(GL_NEAREST);
        glPixelStorei(GL_UNPACK_ALIGNMENT, 4);
        glTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, width, height, GL_RED, GL_FLOAT, zeros.data());
    }
    glBindTexture(GL_TEXTURE_2D, 0);
    GLenum glErr = glGetError();
    if (glErr != GL_NO_ERROR) {
        std::ostringstream ss;
        ss << "alpha texture allocation failed: 0x" << std::hex << glErr;
        SetError(error, ss.str());
        return false;
    }
    alphaWidth_ = width;
    alphaHeight_ = height;
    VG_GS_GPU_RESIDENT_LOGI("ANDROID_GREENSCREEN_GPU_RESIDENT_NATIVE_ALPHA_RESOLUTION %dx%d output=%dx%d aspect=%.4f",
                            width, height, outputWidth_, outputHeight_, cameraUprightAspect_);
    return true;
}

bool GlesGreenScreenGpuResidentRenderer::EnsureCoarseAlphaTexture(int width, int height, std::string* error) {
    if (coarseAlphaTexture_ != 0 && width == coarseAlphaWidth_ && height == coarseAlphaHeight_) return true;
    DeleteTextureQuietly(&coarseAlphaTexture_);
    GLuint tex = 0;
    glGenTextures(1, &tex);
    if (tex == 0) {
        SetError(error, GlErrorString("glGenTextures(coarse alpha)"));
        return false;
    }
    coarseAlphaTexture_ = tex;
    glBindTexture(GL_TEXTURE_2D, coarseAlphaTexture_);
    // GL_R8 + GL_LINEAR: hardware-filterable on every ES3 GPU (R32F is not).
    glTexStorage2D(GL_TEXTURE_2D, 1, GL_R8, width, height);
    SetTexture2DParams(GL_LINEAR);
    glBindTexture(GL_TEXTURE_2D, 0);
    coarseAlphaWidth_ = width;
    coarseAlphaHeight_ = height;
    coarseAlphaBytes_.assign(static_cast<size_t>(width) * static_cast<size_t>(height), 0);
    return true;
}

// ---------------------------------------------------------------------------
// Frame transaction
// ---------------------------------------------------------------------------

bool GlesGreenScreenGpuResidentRenderer::DownscaleCameraToModelInput(float* outRgbFloats, size_t outFloatCount,
                                                                     std::string* error) {
    if (!initialized_ || modelInputTexture_ == 0 || modelInputFbo_ == 0 || downscaleProgram_ == 0) {
        SetError(error, "DownscaleCameraToModelInput: renderer/model input not configured");
        return false;
    }
    const size_t requiredFloats =
        static_cast<size_t>(modelInputWidth_) * static_cast<size_t>(modelInputHeight_) * 3u;
    if (outRgbFloats == nullptr || outFloatCount < requiredFloats) {
        SetError(error, "DownscaleCameraToModelInput: output buffer too small");
        return false;
    }
    if (!MakeCurrent()) {
        SetError(error, EglErrorString("eglMakeCurrent(downscale)"));
        return false;
    }
    const auto start = Clock::now();

    glUseProgram(downscaleProgram_);
    glUniform2i(downscaleModelSizeLoc_, modelInputWidth_, modelInputHeight_);
    glUniformMatrix4fv(downscaleStMatrixLoc_, 1, GL_FALSE, cameraStMatrix_);
    glActiveTexture(GL_TEXTURE0);
    glBindTexture(GL_TEXTURE_EXTERNAL_OES, cameraTexture_);
    glBindImageTexture(1, modelInputTexture_, 0, GL_FALSE, 0, GL_WRITE_ONLY, GL_RGBA8);
    glDispatchCompute(
        static_cast<GLuint>((modelInputWidth_ + kComputeLocalSize - 1) / kComputeLocalSize),
        static_cast<GLuint>((modelInputHeight_ + kComputeLocalSize - 1) / kComputeLocalSize),
        1);
    glMemoryBarrier(GL_FRAMEBUFFER_BARRIER_BIT | GL_TEXTURE_FETCH_BARRIER_BIT | GL_PIXEL_BUFFER_BARRIER_BIT);

    glBindFramebuffer(GL_FRAMEBUFFER, modelInputFbo_);
    glPixelStorei(GL_PACK_ALIGNMENT, 4);
    glReadPixels(0, 0, modelInputWidth_, modelInputHeight_, GL_RGBA, GL_UNSIGNED_BYTE, modelInputRgba_.data());
    glBindFramebuffer(GL_FRAMEBUFFER, 0);
    glBindTexture(GL_TEXTURE_EXTERNAL_OES, 0);
    glUseProgram(0);

    GLenum glErr = glGetError();
    if (glErr != GL_NO_ERROR) {
        std::ostringstream ss;
        ss << "downscale pass GL error: 0x" << std::hex << glErr;
        SetError(error, ss.str());
        return false;
    }

    Rgba8ToRgbFloat(modelInputRgba_.data(), outRgbFloats,
                    static_cast<size_t>(modelInputWidth_) * static_cast<size_t>(modelInputHeight_));

    stats_.downscales++;
    stats_.lastDownscaleMs = ElapsedMs(start);
    stats_.totalDownscaleMs += stats_.lastDownscaleMs;
    return true;
}

bool GlesGreenScreenGpuResidentRenderer::UploadCoarseMask(const float* mask, size_t floatCount, int width, int height,
                                                          std::string* error) {
    if (!initialized_) {
        SetError(error, "UploadCoarseMask before Initialize");
        return false;
    }
    if (mask == nullptr || width <= 0 || height <= 0 ||
        floatCount < static_cast<size_t>(width) * static_cast<size_t>(height)) {
        SetError(error, "UploadCoarseMask: invalid mask buffer");
        return false;
    }
    if (!MakeCurrent()) {
        SetError(error, EglErrorString("eglMakeCurrent(mask upload)"));
        return false;
    }
    if (!EnsureCoarseAlphaTexture(width, height, error)) return false;

    FloatToU8Clamped(mask, coarseAlphaBytes_.data(), static_cast<size_t>(width) * static_cast<size_t>(height));

    glActiveTexture(GL_TEXTURE1);
    glBindTexture(GL_TEXTURE_2D, coarseAlphaTexture_);
    glPixelStorei(GL_UNPACK_ALIGNMENT, 1);
    glTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, width, height, GL_RED, GL_UNSIGNED_BYTE, coarseAlphaBytes_.data());
    glPixelStorei(GL_UNPACK_ALIGNMENT, 4);
    glBindTexture(GL_TEXTURE_2D, 0);
    glActiveTexture(GL_TEXTURE0);

    GLenum glErr = glGetError();
    if (glErr != GL_NO_ERROR) {
        std::ostringstream ss;
        ss << "coarse mask upload GL error: 0x" << std::hex << glErr;
        SetError(error, ss.str());
        return false;
    }
    hasCoarseMask_ = true;
    stats_.maskUploads++;
    return true;
}

bool GlesGreenScreenGpuResidentRenderer::RunGuidedFilter(std::string* error) {
    glUseProgram(guidedProgram_);
    glUniform2f(guidedAlphaResolutionLoc_, static_cast<float>(alphaWidth_), static_cast<float>(alphaHeight_));
    glUniformMatrix4fv(guidedStMatrixLoc_, 1, GL_FALSE, cameraStMatrix_);
    glUniform1i(guidedFilterEnabledLoc_, guidedFilterEnabled_ ? 1 : 0);

    glActiveTexture(GL_TEXTURE0);
    glBindTexture(GL_TEXTURE_EXTERNAL_OES, cameraTexture_);
    glActiveTexture(GL_TEXTURE1);
    glBindTexture(GL_TEXTURE_2D, coarseAlphaTexture_);
    glBindImageTexture(2, alphaPingTexture_, 0, GL_FALSE, 0, GL_WRITE_ONLY, GL_R32F);

    glDispatchCompute(
        static_cast<GLuint>((alphaWidth_ + kComputeLocalSize - 1) / kComputeLocalSize),
        static_cast<GLuint>((alphaHeight_ + kComputeLocalSize - 1) / kComputeLocalSize),
        1);
    glMemoryBarrier(GL_SHADER_IMAGE_ACCESS_BARRIER_BIT | GL_TEXTURE_FETCH_BARRIER_BIT);

    glBindTexture(GL_TEXTURE_2D, 0);
    glActiveTexture(GL_TEXTURE0);
    glBindTexture(GL_TEXTURE_EXTERNAL_OES, 0);
    activeAlphaTexture_ = alphaPingTexture_;
    (void)error;
    return true;
}

bool GlesGreenScreenGpuResidentRenderer::RunTemporalStabilizer(std::string* error) {
    glUseProgram(temporalProgram_);
    glUniform2f(temporalAlphaResolutionLoc_, static_cast<float>(alphaWidth_), static_cast<float>(alphaHeight_));

    glActiveTexture(GL_TEXTURE0);
    glBindTexture(GL_TEXTURE_2D, alphaPingTexture_);     // current refined
    glActiveTexture(GL_TEXTURE1);
    glBindTexture(GL_TEXTURE_2D, alphaHistoryTexture_);  // previous stabilized
    glBindImageTexture(2, alphaPongTexture_, 0, GL_FALSE, 0, GL_WRITE_ONLY, GL_R32F);

    glDispatchCompute(
        static_cast<GLuint>((alphaWidth_ + kComputeLocalSize - 1) / kComputeLocalSize),
        static_cast<GLuint>((alphaHeight_ + kComputeLocalSize - 1) / kComputeLocalSize),
        1);
    glMemoryBarrier(GL_SHADER_IMAGE_ACCESS_BARRIER_BIT | GL_TEXTURE_FETCH_BARRIER_BIT);

    glBindTexture(GL_TEXTURE_2D, 0);
    glActiveTexture(GL_TEXTURE0);
    glBindTexture(GL_TEXTURE_2D, 0);

    // The stabilized result becomes both the active alpha and next frame's history.
    std::swap(alphaPongTexture_, alphaHistoryTexture_);
    activeAlphaTexture_ = alphaHistoryTexture_;
    (void)error;
    return true;
}

bool GlesGreenScreenGpuResidentRenderer::RunComposite(CameraMode cameraMode, std::string* error) {
    const GlesGreenScreenGpuResidentRect fullCanvas{
        0.0f, 0.0f, static_cast<float>(outputWidth_), static_cast<float>(outputHeight_)};
    const GlesGreenScreenGpuResidentRect& sourceRect = hasLayout_ ? sourceRect_ : fullCanvas;
    const GlesGreenScreenGpuResidentRect& cameraRect = hasLayout_ ? cameraRect_ : fullCanvas;

    const GlRect sourceGl = ToGl(sourceRect);
    const GlRect cameraScissorGl = ToGl(cameraRect);
    const GlRect cameraViewportGl = CameraAspectFillViewport(cameraRect);
    const GlRect backgroundImageGl = BackgroundImageRect(sourceRect);
    const GlRect backgroundVideoGl = BackgroundVideoRect(sourceRect);

    int cameraModeValue = static_cast<int>(cameraMode);
    if (cameraModeValue != static_cast<int>(CameraMode::kNone) &&
        cameraModeValue != static_cast<int>(CameraMode::kPlaceholder) &&
        (cameraViewportGl.w <= 0.0f || cameraViewportGl.h <= 0.0f)) {
        cameraModeValue = static_cast<int>(CameraMode::kNone);
    }
    int backgroundModeValue = static_cast<int>(backgroundMode_);
    if (backgroundModeValue == static_cast<int>(BackgroundMode::kImage) && backgroundImageTexture_ == 0) {
        backgroundModeValue = static_cast<int>(BackgroundMode::kBlack);
    }
    if (backgroundModeValue == static_cast<int>(BackgroundMode::kVideo) && backgroundVideoTexture_ == 0) {
        backgroundModeValue = static_cast<int>(BackgroundMode::kBlack);
    }

    glBindFramebuffer(GL_FRAMEBUFFER, 0);
    glViewport(0, 0, outputWidth_, outputHeight_);
    glDisable(GL_SCISSOR_TEST);
    glDisable(GL_BLEND);
    glDisable(GL_DEPTH_TEST);
    glDisable(GL_CULL_FACE);
    glDisable(GL_DITHER);
    glColorMask(GL_TRUE, GL_TRUE, GL_TRUE, GL_TRUE);

    glUseProgram(compositeProgram_);
    glUniform1i(compositeCameraTextureLoc_, 0);
    glUniform1i(compositeAlphaTextureLoc_, 1);
    glUniform1i(compositeBackgroundImageLoc_, 2);
    glUniform2f(compositeAlphaResolutionLoc_,
                static_cast<float>(std::max(alphaWidth_, 1)), static_cast<float>(std::max(alphaHeight_, 1)));
    glUniformMatrix4fv(compositeStMatrixLoc_, 1, GL_FALSE, cameraStMatrix_);
    glUniform4f(compositeSourceRectLoc_, sourceGl.x, sourceGl.y, sourceGl.w, sourceGl.h);
    glUniform4f(compositeCameraScissorLoc_, cameraScissorGl.x, cameraScissorGl.y, cameraScissorGl.w, cameraScissorGl.h);
    glUniform4f(compositeCameraViewportLoc_, cameraViewportGl.x, cameraViewportGl.y, cameraViewportGl.w, cameraViewportGl.h);
    glUniform4f(compositeBackgroundImageRectLoc_, backgroundImageGl.x, backgroundImageGl.y, backgroundImageGl.w, backgroundImageGl.h);
    glUniform1i(compositeBackgroundVideoTextureLoc_, 3);
    glUniformMatrix4fv(compositeBackgroundVideoStMatrixLoc_, 1, GL_FALSE, backgroundVideoStMatrix_);
    glUniform4f(compositeBackgroundVideoRectLoc_, backgroundVideoGl.x, backgroundVideoGl.y, backgroundVideoGl.w, backgroundVideoGl.h);
    glUniform4fv(compositeBackgroundColorLoc_, 1, backgroundColor_);
    glUniform4f(compositePlaceholderColorLoc_, kPlaceholderR, kPlaceholderG, kPlaceholderB, 1.0f);
    glUniform1i(compositeBackgroundModeLoc_, backgroundModeValue);
    glUniform1i(compositeCameraModeLoc_, cameraModeValue);
    glUniform1i(compositeDespillEnabledLoc_, despillEnabled_ ? 1 : 0);

    glActiveTexture(GL_TEXTURE0);
    glBindTexture(GL_TEXTURE_EXTERNAL_OES, cameraTexture_);
    glActiveTexture(GL_TEXTURE1);
    glBindTexture(GL_TEXTURE_2D, activeAlphaTexture_ != 0 ? activeAlphaTexture_ : alphaPingTexture_);
    glActiveTexture(GL_TEXTURE2);
    glBindTexture(GL_TEXTURE_2D, backgroundImageTexture_);
    glActiveTexture(GL_TEXTURE3);
    glBindTexture(GL_TEXTURE_EXTERNAL_OES, backgroundVideoTexture_);

    glBindVertexArray(quadVao_);
    glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
    glBindVertexArray(0);

    glBindTexture(GL_TEXTURE_EXTERNAL_OES, 0);
    glActiveTexture(GL_TEXTURE2);
    glBindTexture(GL_TEXTURE_2D, 0);
    glActiveTexture(GL_TEXTURE1);
    glBindTexture(GL_TEXTURE_2D, 0);
    glActiveTexture(GL_TEXTURE0);
    glBindTexture(GL_TEXTURE_EXTERNAL_OES, 0);
    glUseProgram(0);

    GLenum glErr = glGetError();
    if (glErr != GL_NO_ERROR) {
        std::ostringstream ss;
        ss << "composite pass GL error: 0x" << std::hex << glErr;
        SetError(error, ss.str());
        return false;
    }
    return true;
}

bool GlesGreenScreenGpuResidentRenderer::RenderFrame(CameraMode cameraMode, bool refineMask, std::string* error) {
    if (!initialized_) {
        SetError(error, "RenderFrame before Initialize");
        return false;
    }
    if (eglWindowSurface_ == nullptr || outputWidth_ <= 0 || outputHeight_ <= 0) {
        // No output attached: nothing to present (not an error, mirrors the CPU compositor).
        return false;
    }
    if (!MakeCurrent()) {
        SetError(error, EglErrorString("eglMakeCurrent(render)"));
        return false;
    }
    const auto frameStart = Clock::now();

    int alphaW = 0;
    int alphaH = 0;
    DeriveAlphaResolution(&alphaW, &alphaH);
    if (!EnsureAlphaTextures(alphaW, alphaH, error)) return false;

    CameraMode effectiveMode = cameraMode;
    if (effectiveMode == CameraMode::kMasked) {
        if (!hasCoarseMask_) {
            effectiveMode = CameraMode::kNone;
        } else if (refineMask || !hasRefinedAlpha_) {
            const auto refineStart = Clock::now();
            if (!RunGuidedFilter(error)) return false;
            if (temporalEnabled_ && !RunTemporalStabilizer(error)) return false;
            hasRefinedAlpha_ = true;
            stats_.refinePasses++;
            stats_.lastRefineMs = ElapsedMs(refineStart);
            stats_.totalRefineMs += stats_.lastRefineMs;
        }
    }

    const auto compositeStart = Clock::now();
    if (!RunComposite(effectiveMode, error)) return false;

    const EGLBoolean swapped = eglSwapBuffers(static_cast<EGLDisplay>(eglDisplay_),
                                              static_cast<EGLSurface>(eglWindowSurface_));
    stats_.lastCompositeMs = ElapsedMs(compositeStart);
    stats_.totalCompositeMs += stats_.lastCompositeMs;
    stats_.framesRendered++;
    if (swapped == EGL_TRUE) {
        stats_.framesSwapped++;
    } else {
        SetError(error, EglErrorString("eglSwapBuffers"));
    }
    (void)frameStart;
    return swapped == EGL_TRUE;
}

std::string GlesGreenScreenGpuResidentRenderer::StatsSummary() const {
    std::ostringstream ss;
    const double frames = stats_.framesRendered > 0 ? static_cast<double>(stats_.framesRendered) : 1.0;
    const double downscales = stats_.downscales > 0 ? static_cast<double>(stats_.downscales) : 1.0;
    const double refines = stats_.refinePasses > 0 ? static_cast<double>(stats_.refinePasses) : 1.0;
    ss << "framesRendered=" << stats_.framesRendered
       << " framesSwapped=" << stats_.framesSwapped
       << " downscales=" << stats_.downscales
       << " maskUploads=" << stats_.maskUploads
       << " refinePasses=" << stats_.refinePasses
       << " avgDownscaleMs=" << (stats_.totalDownscaleMs / downscales)
       << " avgRefineMs=" << (stats_.totalRefineMs / refines)
       << " avgCompositeMs=" << (stats_.totalCompositeMs / frames)
       << " alpha=" << alphaWidth_ << "x" << alphaHeight_
       << " modelInput=" << modelInputWidth_ << "x" << modelInputHeight_
       << " coarseMask=" << coarseAlphaWidth_ << "x" << coarseAlphaHeight_;
    return ss.str();
}

}  // namespace render
}  // namespace vanguard

#else  // !defined(__ANDROID__)

namespace vanguard {
namespace render {

namespace {
void SetUnavailable(std::string* error) {
    if (error) *error = "GlesGreenScreenGpuResidentRenderer is only available on Android";
}
}  // namespace

GlesGreenScreenGpuResidentRenderer::GlesGreenScreenGpuResidentRenderer() {
    for (int i = 0; i < 16; ++i) cameraStMatrix_[i] = (i % 5 == 0) ? 1.0f : 0.0f;
    for (int i = 0; i < 16; ++i) backgroundVideoStMatrix_[i] = (i % 5 == 0) ? 1.0f : 0.0f;
}
GlesGreenScreenGpuResidentRenderer::~GlesGreenScreenGpuResidentRenderer() {}
bool GlesGreenScreenGpuResidentRenderer::Initialize(std::string* error) { SetUnavailable(error); return false; }
void GlesGreenScreenGpuResidentRenderer::Destroy() {}
bool GlesGreenScreenGpuResidentRenderer::MakeCurrent() { return false; }
bool GlesGreenScreenGpuResidentRenderer::ConfigureModelInput(int, int, std::string* error) { SetUnavailable(error); return false; }
bool GlesGreenScreenGpuResidentRenderer::AttachOutputWindow(void*, int, int, std::string* error) { SetUnavailable(error); return false; }
void GlesGreenScreenGpuResidentRenderer::DetachOutputWindow() {}
void GlesGreenScreenGpuResidentRenderer::SetLayout(const GlesGreenScreenGpuResidentRect&, const GlesGreenScreenGpuResidentRect&) {}
void GlesGreenScreenGpuResidentRenderer::SetCameraTransform(const float[16], float) {}
void GlesGreenScreenGpuResidentRenderer::SetBackgroundBlack() {}
void GlesGreenScreenGpuResidentRenderer::SetBackgroundSolidColor(uint32_t) {}
bool GlesGreenScreenGpuResidentRenderer::SetBackgroundImage(const uint8_t*, int, int, bool, std::string* error) { SetUnavailable(error); return false; }
void GlesGreenScreenGpuResidentRenderer::SetBackgroundImageScaleMode(bool) {}
void GlesGreenScreenGpuResidentRenderer::ClearBackgroundImage() {}
uint32_t GlesGreenScreenGpuResidentRenderer::EnsureBackgroundVideoTexture(std::string* error) { SetUnavailable(error); return 0; }
void GlesGreenScreenGpuResidentRenderer::SetBackgroundVideoFrame(const float[16], int, int, int, bool) {}
void GlesGreenScreenGpuResidentRenderer::ClearBackgroundVideo() {}
void GlesGreenScreenGpuResidentRenderer::SetFilterToggles(bool, bool, bool) {}
bool GlesGreenScreenGpuResidentRenderer::DownscaleCameraToModelInput(float*, size_t, std::string* error) { SetUnavailable(error); return false; }
bool GlesGreenScreenGpuResidentRenderer::UploadCoarseMask(const float*, size_t, int, int, std::string* error) { SetUnavailable(error); return false; }
bool GlesGreenScreenGpuResidentRenderer::RenderFrame(CameraMode, bool, std::string* error) { SetUnavailable(error); return false; }
std::string GlesGreenScreenGpuResidentRenderer::StatsSummary() const { return "unavailable"; }

}  // namespace render
}  // namespace vanguard

#endif  // defined(__ANDROID__)
