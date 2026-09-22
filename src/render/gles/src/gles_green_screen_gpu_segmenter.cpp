// gles_green_screen_gpu_segmenter.cpp
// ANDROID-GREENSCREEN-GPU-SEGMENTER: see gles_green_screen_gpu_segmenter.h.
//
// The compute passes, NEON packing and alpha-resolution policy are the same
// as the committed GlesGreenScreenGpuResidentRenderer (which keeps its own
// self-contained copy for the standalone live GreenScreen backend); this
// component only drops every EGL / camera-texture / output / composite /
// swap ownership so a host compositor can embed it in its own render pass.

#include "gles_green_screen_gpu_segmenter.h"

#if defined(__ANDROID__)

#include <GLES3/gl31.h>
#include <GLES2/gl2ext.h>
#include <android/log.h>

#if defined(__ARM_NEON) || defined(__ARM_NEON__)
#include <arm_neon.h>
#define VG_GS_GPU_SEGMENTER_HAS_NEON 1
#else
#define VG_GS_GPU_SEGMENTER_HAS_NEON 0
#endif

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <sstream>

#include "gles_green_screen_gpu_resident_shaders.h"

#ifndef GL_TEXTURE_EXTERNAL_OES
#define GL_TEXTURE_EXTERNAL_OES 0x8D65
#endif

#define VG_GS_GPU_SEGMENTER_TAG "VanguardGreenScreenGpuSegmenter"
#define VG_GS_GPU_SEGMENTER_LOGI(...) \
    __android_log_print(ANDROID_LOG_INFO, VG_GS_GPU_SEGMENTER_TAG, __VA_ARGS__)
#define VG_GS_GPU_SEGMENTER_LOGW(...) \
    __android_log_print(ANDROID_LOG_WARN, VG_GS_GPU_SEGMENTER_TAG, __VA_ARGS__)

namespace vanguard {
namespace render {

namespace {

constexpr int kMaxAlphaLongSide = 1280;
constexpr int kMinAlphaLongSide = 64;
constexpr int kMinAlphaShortSide = 16;
constexpr int kComputeLocalSize = 16;

using Clock = std::chrono::steady_clock;

float ElapsedMs(Clock::time_point start) {
    return std::chrono::duration<float, std::milli>(Clock::now() - start).count();
}

void SetError(std::string* error, const std::string& message) {
    if (error) *error = message;
    VG_GS_GPU_SEGMENTER_LOGW("ANDROID_GREENSCREEN_GPU_SEGMENTER_NATIVE_ERROR %s", message.c_str());
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

GLuint CreateComputeProgram(const char* source, std::string* error) {
    GLuint shader = CompileShader(GL_COMPUTE_SHADER, source, error);
    if (shader == 0) return 0;
    GLuint program = glCreateProgram();
    if (program == 0) {
        SetError(error, GlErrorString("glCreateProgram"));
        glDeleteShader(shader);
        return 0;
    }
    glAttachShader(program, shader);
    glLinkProgram(program);
    glDeleteShader(shader);
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
        SetError(error, "compute program link failed: " + log);
        glDeleteProgram(program);
        return 0;
    }
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

// Parses "OpenGL ES <major>.<minor> ..." from GL_VERSION. Safe on every
// context version (GL_MAJOR_VERSION is an invalid enum on an ES 2 context).
bool ParseGlesVersion(int* major, int* minor) {
    const GLubyte* raw = glGetString(GL_VERSION);
    if (raw == nullptr) return false;
    const char* text = reinterpret_cast<const char*>(raw);
    const char* prefix = "OpenGL ES ";
    const char* at = std::strstr(text, prefix);
    if (at == nullptr) return false;
    int parsedMajor = 0;
    int parsedMinor = 0;
    if (std::sscanf(at + std::strlen(prefix), "%d.%d", &parsedMajor, &parsedMinor) != 2) return false;
    *major = parsedMajor;
    *minor = parsedMinor;
    return true;
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
// mirrors the committed renderer; the scalar tail also serves non-NEON ABIs.
void Rgba8ToRgbFloat(const uint8_t* rgba, float* rgbFloat, size_t numPixels) {
    const float scale = 1.0f / 255.0f;
    size_t i = 0;
#if VG_GS_GPU_SEGMENTER_HAS_NEON
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
#if VG_GS_GPU_SEGMENTER_HAS_NEON
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

GlesGreenScreenGpuSegmenter::GlesGreenScreenGpuSegmenter() {
    for (int i = 0; i < 16; ++i) cameraStMatrix_[i] = (i % 5 == 0) ? 1.0f : 0.0f;
}

GlesGreenScreenGpuSegmenter::~GlesGreenScreenGpuSegmenter() {
    // The host is contractually required to call Destroy() with its context
    // current; if it did not, GL calls here would target a foreign or absent
    // context, so only forget the names.
    initialized_ = false;
}

// ---------------------------------------------------------------------------
// Lifecycle
// ---------------------------------------------------------------------------

bool GlesGreenScreenGpuSegmenter::Initialize(std::string* error) {
    if (initialized_) return true;

    int glMajor = 0;
    int glMinor = 0;
    if (!ParseGlesVersion(&glMajor, &glMinor)) {
        SetError(error, "Initialize: no current OpenGL ES context (GL_VERSION unreadable)");
        return false;
    }
    if (glMajor < 3 || (glMajor == 3 && glMinor < 1)) {
        std::ostringstream ss;
        ss << "OpenGL ES 3.1 required for compute passes; current context reports " << glMajor << "." << glMinor;
        SetError(error, ss.str());
        return false;
    }
    if (!HasGlExtension("GL_OES_EGL_image_external_essl3")) {
        SetError(error, "GL_OES_EGL_image_external_essl3 not supported");
        return false;
    }
    // Clear any error a previous host pass may have left so the bootstrap
    // check below only reports this component's own failures.
    while (glGetError() != GL_NO_ERROR) {}

    if (!CreatePrograms(error)) {
        DestroyGlObjects();
        return false;
    }
    GLenum glErr = glGetError();
    if (glErr != GL_NO_ERROR) {
        std::ostringstream ss;
        ss << "GL error after bootstrap: 0x" << std::hex << glErr;
        SetError(error, ss.str());
        DestroyGlObjects();
        return false;
    }
    initialized_ = true;
    VG_GS_GPU_SEGMENTER_LOGI(
        "ANDROID_GREENSCREEN_GPU_SEGMENTER_NATIVE_READY gles=%d.%d renderer=%s neon=%d",
        glMajor, glMinor, reinterpret_cast<const char*>(glGetString(GL_RENDERER)),
        VG_GS_GPU_SEGMENTER_HAS_NEON);
    return true;
}

bool GlesGreenScreenGpuSegmenter::CreatePrograms(std::string* error) {
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
    return true;
}

void GlesGreenScreenGpuSegmenter::Destroy() {
    if (!initialized_ && downscaleProgram_ == 0 && modelInputTexture_ == 0 && alphaPingTexture_ == 0 &&
        coarseAlphaTexture_ == 0) {
        return;
    }
    DestroyGlObjects();
    initialized_ = false;
}

void GlesGreenScreenGpuSegmenter::DestroyGlObjects() {
    DeleteProgramQuietly(&downscaleProgram_);
    DeleteProgramQuietly(&guidedProgram_);
    DeleteProgramQuietly(&temporalProgram_);
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
    modelInputWidth_ = 0;
    modelInputHeight_ = 0;
    coarseAlphaWidth_ = 0;
    coarseAlphaHeight_ = 0;
    alphaWidth_ = 0;
    alphaHeight_ = 0;
    activeAlphaTexture_ = 0;
    hasCoarseMask_ = false;
    hasRefinedAlpha_ = false;
    temporalHistoryValid_ = false;
    modelInputRgba_.clear();
    coarseAlphaBytes_.clear();
}

// ---------------------------------------------------------------------------
// Configuration
// ---------------------------------------------------------------------------

bool GlesGreenScreenGpuSegmenter::ConfigureModelInput(int width, int height, std::string* error) {
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
    VG_GS_GPU_SEGMENTER_LOGI("ANDROID_GREENSCREEN_GPU_SEGMENTER_NATIVE_MODEL_INPUT %dx%d", width, height);
    return true;
}

void GlesGreenScreenGpuSegmenter::SetCameraTransform(const float stMatrixColumnMajor[16], float cameraUprightAspect) {
    std::memcpy(cameraStMatrix_, stMatrixColumnMajor, sizeof(cameraStMatrix_));
    if (std::isfinite(cameraUprightAspect) && cameraUprightAspect > 0.0f) {
        cameraUprightAspect_ = cameraUprightAspect;
    }
}

void GlesGreenScreenGpuSegmenter::SetAlphaTargetSize(int outputWidthPx, int outputHeightPx) {
    outputWidth_ = std::max(0, outputWidthPx);
    outputHeight_ = std::max(0, outputHeightPx);
}

void GlesGreenScreenGpuSegmenter::SetFilterToggles(bool guidedFilter, bool temporalStabilizer) {
    guidedFilterEnabled_ = guidedFilter;
    temporalEnabled_ = temporalStabilizer;
}

void GlesGreenScreenGpuSegmenter::ResetMaskState() {
    hasCoarseMask_ = false;
    hasRefinedAlpha_ = false;
    temporalHistoryValid_ = false;
    activeAlphaTexture_ = 0;
}

// ---------------------------------------------------------------------------
// Geometry (same policy as the committed renderer)
// ---------------------------------------------------------------------------

void GlesGreenScreenGpuSegmenter::DeriveAlphaResolution(int* width, int* height) const {
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

bool GlesGreenScreenGpuSegmenter::EnsureAlphaTextures(int width, int height, std::string* error) {
    if (alphaPingTexture_ != 0 && width == alphaWidth_ && height == alphaHeight_) return true;
    DeleteTextureQuietly(&alphaPingTexture_);
    DeleteTextureQuietly(&alphaPongTexture_);
    DeleteTextureQuietly(&alphaHistoryTexture_);
    activeAlphaTexture_ = 0;
    hasRefinedAlpha_ = false;
    temporalHistoryValid_ = false;

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
    VG_GS_GPU_SEGMENTER_LOGI("ANDROID_GREENSCREEN_GPU_SEGMENTER_NATIVE_ALPHA_RESOLUTION %dx%d output=%dx%d aspect=%.4f",
                             width, height, outputWidth_, outputHeight_, cameraUprightAspect_);
    return true;
}

bool GlesGreenScreenGpuSegmenter::EnsureCoarseAlphaTexture(int width, int height, std::string* error) {
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

bool GlesGreenScreenGpuSegmenter::DownscaleCameraToModelInput(uint32_t cameraOesTexture, float* outRgbFloats,
                                                              size_t outFloatCount, std::string* error) {
    if (!initialized_ || modelInputTexture_ == 0 || modelInputFbo_ == 0 || downscaleProgram_ == 0) {
        SetError(error, "DownscaleCameraToModelInput: segmenter/model input not configured");
        return false;
    }
    if (cameraOesTexture == 0) {
        SetError(error, "DownscaleCameraToModelInput: camera texture is 0");
        return false;
    }
    const size_t requiredFloats =
        static_cast<size_t>(modelInputWidth_) * static_cast<size_t>(modelInputHeight_) * 3u;
    if (outRgbFloats == nullptr || outFloatCount < requiredFloats) {
        SetError(error, "DownscaleCameraToModelInput: output buffer too small");
        return false;
    }
    const auto start = Clock::now();

    glUseProgram(downscaleProgram_);
    glUniform2i(downscaleModelSizeLoc_, modelInputWidth_, modelInputHeight_);
    glUniformMatrix4fv(downscaleStMatrixLoc_, 1, GL_FALSE, cameraStMatrix_);
    glActiveTexture(GL_TEXTURE0);
    glBindTexture(GL_TEXTURE_EXTERNAL_OES, cameraOesTexture);
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

bool GlesGreenScreenGpuSegmenter::UploadCoarseMask(const float* mask, size_t floatCount, int width, int height,
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

bool GlesGreenScreenGpuSegmenter::RunGuidedFilter(uint32_t cameraOesTexture, std::string* error) {
    glUseProgram(guidedProgram_);
    glUniform2f(guidedAlphaResolutionLoc_, static_cast<float>(alphaWidth_), static_cast<float>(alphaHeight_));
    glUniformMatrix4fv(guidedStMatrixLoc_, 1, GL_FALSE, cameraStMatrix_);
    glUniform1i(guidedFilterEnabledLoc_, guidedFilterEnabled_ ? 1 : 0);

    glActiveTexture(GL_TEXTURE0);
    glBindTexture(GL_TEXTURE_EXTERNAL_OES, cameraOesTexture);
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

bool GlesGreenScreenGpuSegmenter::RunTemporalStabilizer(std::string* error) {
    glUseProgram(temporalProgram_);
    glUniform2f(temporalAlphaResolutionLoc_, static_cast<float>(alphaWidth_), static_cast<float>(alphaHeight_));

    glActiveTexture(GL_TEXTURE0);
    glBindTexture(GL_TEXTURE_2D, alphaPingTexture_);  // current refined
    glActiveTexture(GL_TEXTURE1);
    // First frame after a reset: seed the history with the current alpha
    // (prev == curr => output == curr) instead of blending up from zeros.
    glBindTexture(GL_TEXTURE_2D, temporalHistoryValid_ ? alphaHistoryTexture_ : alphaPingTexture_);
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
    temporalHistoryValid_ = true;
    (void)error;
    return true;
}

bool GlesGreenScreenGpuSegmenter::RefineAlpha(uint32_t cameraOesTexture, std::string* error) {
    if (!initialized_) {
        SetError(error, "RefineAlpha before Initialize");
        return false;
    }
    if (!hasCoarseMask_ || coarseAlphaTexture_ == 0) {
        SetError(error, "RefineAlpha: no coarse mask uploaded");
        return false;
    }
    if (cameraOesTexture == 0) {
        SetError(error, "RefineAlpha: camera texture is 0");
        return false;
    }
    int alphaW = 0;
    int alphaH = 0;
    DeriveAlphaResolution(&alphaW, &alphaH);
    if (!EnsureAlphaTextures(alphaW, alphaH, error)) return false;

    const auto refineStart = Clock::now();
    if (!RunGuidedFilter(cameraOesTexture, error)) return false;
    if (temporalEnabled_ && !RunTemporalStabilizer(error)) return false;
    glUseProgram(0);

    GLenum glErr = glGetError();
    if (glErr != GL_NO_ERROR) {
        std::ostringstream ss;
        ss << "refine pass GL error: 0x" << std::hex << glErr;
        SetError(error, ss.str());
        hasRefinedAlpha_ = false;
        return false;
    }
    hasRefinedAlpha_ = true;
    stats_.refinePasses++;
    stats_.lastRefineMs = ElapsedMs(refineStart);
    stats_.totalRefineMs += stats_.lastRefineMs;
    return true;
}

std::string GlesGreenScreenGpuSegmenter::StatsSummary() const {
    std::ostringstream ss;
    const double downscales = stats_.downscales > 0 ? static_cast<double>(stats_.downscales) : 1.0;
    const double refines = stats_.refinePasses > 0 ? static_cast<double>(stats_.refinePasses) : 1.0;
    ss << "downscales=" << stats_.downscales
       << " maskUploads=" << stats_.maskUploads
       << " refinePasses=" << stats_.refinePasses
       << " avgDownscaleMs=" << (stats_.totalDownscaleMs / downscales)
       << " avgRefineMs=" << (stats_.totalRefineMs / refines)
       << " lastDownscaleMs=" << stats_.lastDownscaleMs
       << " lastRefineMs=" << stats_.lastRefineMs
       << " alpha=" << alphaWidth_ << "x" << alphaHeight_
       << " modelInput=" << modelInputWidth_ << "x" << modelInputHeight_
       << " coarseMask=" << coarseAlphaWidth_ << "x" << coarseAlphaHeight_
       << " guided=" << (guidedFilterEnabled_ ? 1 : 0)
       << " temporal=" << (temporalEnabled_ ? 1 : 0);
    return ss.str();
}

}  // namespace render
}  // namespace vanguard

#else  // !defined(__ANDROID__)

namespace vanguard {
namespace render {

namespace {
void SetUnavailable(std::string* error) {
    if (error) *error = "GlesGreenScreenGpuSegmenter is only available on Android";
}
}  // namespace

GlesGreenScreenGpuSegmenter::GlesGreenScreenGpuSegmenter() {
    for (int i = 0; i < 16; ++i) cameraStMatrix_[i] = (i % 5 == 0) ? 1.0f : 0.0f;
}
GlesGreenScreenGpuSegmenter::~GlesGreenScreenGpuSegmenter() {}
bool GlesGreenScreenGpuSegmenter::Initialize(std::string* error) { SetUnavailable(error); return false; }
void GlesGreenScreenGpuSegmenter::Destroy() {}
bool GlesGreenScreenGpuSegmenter::ConfigureModelInput(int, int, std::string* error) { SetUnavailable(error); return false; }
void GlesGreenScreenGpuSegmenter::SetCameraTransform(const float[16], float) {}
void GlesGreenScreenGpuSegmenter::SetAlphaTargetSize(int, int) {}
void GlesGreenScreenGpuSegmenter::SetFilterToggles(bool, bool) {}
bool GlesGreenScreenGpuSegmenter::DownscaleCameraToModelInput(uint32_t, float*, size_t, std::string* error) { SetUnavailable(error); return false; }
bool GlesGreenScreenGpuSegmenter::UploadCoarseMask(const float*, size_t, int, int, std::string* error) { SetUnavailable(error); return false; }
bool GlesGreenScreenGpuSegmenter::RefineAlpha(uint32_t, std::string* error) { SetUnavailable(error); return false; }
void GlesGreenScreenGpuSegmenter::ResetMaskState() {}
std::string GlesGreenScreenGpuSegmenter::StatsSummary() const { return "unavailable"; }

}  // namespace render
}  // namespace vanguard

#endif  // defined(__ANDROID__)
