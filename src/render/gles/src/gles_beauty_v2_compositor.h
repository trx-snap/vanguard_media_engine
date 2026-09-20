// gles_beauty_v2_compositor.h
// P5-BEAUTY-V2-GLES-RENDER: Private helper - GlesBeautyV2Compositor.
//
// Diagnostic-only OpenGL ES 3.0+ port of the iOS Metal Beauty V2 bilateral
// smoothing filter group (ios/Classes/BeautyV2FilterGroup.m,
// ios/Classes/VanguardEffects.metal vanguard_beauty_blur_h / _blur_v /
// _composite). Executes the exact global (non-FaceAware) 3-pass pipeline:
// Pass 1 horizontal bilateral blur, Pass 2 vertical bilateral blur, Pass 3
// composite (fused highpass, adaptive smoothing gate, soft-S tone
// compression, midtone lift, detail add-back, alpha preservation). All
// FaceAware/mask/feature/enhance/polish layers are permanently discarded per
// 00_START_HERE.md's FaceAware exclusion and the iOS
// `_faceAwareEnabled = NO` production default (hasMask = 0 -> exact global
// beauty output).
//
// This helper is NOT a graph node and owns no timeline, DAG, or session
// state. It draws into a caller-provided target FBO (0 for the default
// window/pbuffer framebuffer, or an already-created FBO) using a
// caller-owned input texture; the composition root (a diagnostic JNI in this
// slice) owns the EGL context/surface and the input texture's contents.
//
// t=0 ("None") is the minimum ramp, never a bypass: the complete 3-pass
// pipeline always executes (radius=1, sharpenStrength=0.35 at t=0), per the
// frozen readiness contract in
// packages/UMF/Android_Documentation/implementation_readiness/Phase_5_Beauty_V2_GLES_Render_Readiness.md
// section 7.
//
// GL / GLSL pinning (ES3-or-fail, no ES2 fallback):
//   - `#version 300 es`, `precision highp float; precision highp sampler2D;`
//   - texelFetch with clamped integer coordinates (gl_FragCoord.xy truncated
//     to ivec2, no normalized UV interpolation).
//   - GL_RGBA8 non-sRGB for the input texture, both intermediate FBO
//     textures, and the target framebuffer; GL_NEAREST / GL_CLAMP_TO_EDGE
//     texture parameters.
//   - No Y-flip between passes; viewport is (0, 0, width, height) for every
//     pass.
//
// Lifecycle (Opus-corrected, matching GlesOverlayCompositor's precedent):
// validates every argument before any GL or EGL call; on success it
// snapshots the full GL state it will touch (viewport, active texture,
// texture-unit 0/1 bindings, framebuffer/renderbuffer binding, current
// program, VAO/VBO bindings, blend enable/equations/funcs, dither, scissor
// enable/box, depth test/writemask, stencil enable, cull-face enable, color
// write mask, pack/unpack alignment), forces a clean render state for the
// three passes (blend/dither/scissor/depth/stencil/cull disabled, full color
// mask, alignments = 1), creates per-call intermediate FBOs/textures A and B
// plus per-call shader programs, runs the three passes, deletes every
// temporary GL object it created, and restores the snapshot bit-for-bit on
// every exit path (success or failure). No GL handle is cached across calls.
//
// Private source: EGL/GLES/Android headers must never appear in this header;
// the .cpp translation unit confines all such includes behind
// #if defined(__ANDROID__) and compiles to a safe unavailable stub elsewhere.

#pragma once

#include <cstdint>
#include <string>

namespace vanguard {
namespace render {

// Tunable Beauty V2 parameters for one DrawBeautyV2 call. Defaults mirror
// the iOS production defaults (BeautyV2FilterGroup.m init):
// intensity=0.75 -> radius=10 (rounded from the 0.75 ramp; iOS ships the
// hand-tuned constant 10), sigma=5.5, smoothStrength=0.90,
// sharpenStrength=0.25, theta=0.06, rangeSigma=0.10, detailDamping=0.55,
// toneStrength=0.25, midtoneLift=0.045.
struct GlesBeautyV2Parameters {
    int32_t radius = 10;
    float sigma = 5.5f;
    float rangeSigma = 0.10f;
    float smoothStrength = 0.90f;
    float sharpenStrength = 0.25f;
    float theta = 0.06f;
    float detailDamping = 0.55f;
    float toneStrength = 0.25f;
    float midtoneLift = 0.045f;
};

// Pure, platform-independent validation (no GL/EGL calls) of `params`
// against a width x height render target. Evaluates in exactly this order,
// returning false and setting *outError to the first failure:
//   1. outError == nullptr                                 -> (no report possible; returns false)
//   2. width == 0 || height == 0                            -> "gles_beauty_v2_invalid_dimensions"
//   3. non-finite or out-of-range params (radius < 1,
//      sigma < 1.0, rangeSigma < 0.01, theta < 0.001,
//      any strength/damping/lift < 0.0)                     -> "gles_beauty_v2_invalid_parameters"
// On success, *outError is cleared and the function returns true.
bool ValidateBeautyV2Parameters(const GlesBeautyV2Parameters& params,
                                uint32_t width,
                                uint32_t height,
                                std::string* outError);

// Pure, platform-independent parameter ramp calculator (no GL/EGL calls).
// Computes the full parameter set from a master intensity scalar
// `intensity` in [0.0, 1.0], matching the iOS `_useIntensityRamp` formulas
// (BeautyV2FilterGroup.m processEnvelope:) exactly, including the
// resolution spatial-scale factor S = max(1.0, min(width, height) / 1080.0).
// Evaluates in exactly this order, returning false and setting *outError to
// the first failure:
//   1. outError == nullptr || outParams == nullptr           -> (no report possible; returns false)
//   2. width == 0 || height == 0                              -> "gles_beauty_v2_invalid_dimensions"
//   3. !isfinite(intensity) || intensity < 0 || intensity > 1 -> "gles_beauty_v2_invalid_intensity"
// On success, *outParams is filled with values guaranteed to already satisfy
// ValidateBeautyV2Parameters, *outError is cleared, and the function returns
// true.
bool ComputeBeautyV2ParametersFromIntensity(float intensity,
                                            uint32_t width,
                                            uint32_t height,
                                            GlesBeautyV2Parameters* outParams,
                                            std::string* outError);

class GlesBeautyV2Compositor {
public:
    GlesBeautyV2Compositor();
    ~GlesBeautyV2Compositor();

    GlesBeautyV2Compositor(const GlesBeautyV2Compositor&) = delete;
    GlesBeautyV2Compositor& operator=(const GlesBeautyV2Compositor&) = delete;

    // Executes the 3-pass bilateral beauty smoothing pipeline (blur_h ->
    // blur_v -> composite) against the caller's currently-current EGL
    // surface/context.
    //
    // Shader programs are compiled once and reused across calls.
    // Intermediate FBOs/textures and the fullscreen-quad VAO/VBO are
    // cached and re-allocated only when width/height change. This
    // eliminates ~15 redundant GL state-change calls per frame for
    // sustained 30 FPS on mid-tier Android SoCs.
    //
    // inputTexture - non-zero GL_TEXTURE_2D handle already holding a
    //                GL_RGBA8 non-sRGB raster; not owned by the helper.
    // targetFbo     - GL framebuffer object the composite pass writes into
    //                 (0 for the default window/pbuffer framebuffer, or an
    //                 already-created, already-complete FBO); not owned by
    //                 the helper.
    // width, height - render dimensions in pixels; both must be > 0.
    // params        - validated beauty parameters (see
    //                 ValidateBeautyV2Parameters).
    // outError      - non-null; set to "" on success, or to one of the
    //                 error strings in the frozen evaluation-order table
    //                 (gles_beauty_v2_invalid_argument,
    //                 gles_beauty_v2_invalid_dimensions,
    //                 gles_beauty_v2_invalid_texture,
    //                 gles_beauty_v2_invalid_parameters,
    //                 gles_beauty_v2_unavailable_on_host,
    //                 gles_beauty_v2_shader_compile_failed,
    //                 gles_beauty_v2_program_link_failed,
    //                 gles_beauty_v2_fbo_incomplete,
    //                 gles_beauty_v2_draw_failed) on failure.
    //
    // Returns true only if every shader compile/link, FBO completeness
    // check, and draw call reports success/GL_NO_ERROR. Returns false with
    // outError="gles_beauty_v2_unavailable_on_host" and no GL mutation on
    // non-Android builds or when the current context is not OpenGL ES 3.0+.
    // Validation runs before any GL or EGL call; on validation failure zero
    // GL state is touched. On every other failure path, every temporary GL
    // object created so far is deleted and the pre-call GL state is restored
    // before returning.
    bool DrawBeautyV2(uint32_t inputTexture,
                      uint32_t targetFbo,
                      uint32_t width,
                      uint32_t height,
                      const GlesBeautyV2Parameters& params,
                      std::string* outError);

    // Releases all cached GL resources (programs, FBOs, textures, VAO/VBO).
    // Must be called on the GL thread that owns the context before the
    // context is destroyed. Safe to call multiple times or on an instance
    // that was never used. After Release(), the next DrawBeautyV2 call
    // will lazily re-create all resources.
    void Release();

private:
    // Cached render dimensions — triggers FBO/texture re-allocation when
    // width or height changes between frames.
    uint32_t cachedWidth_ = 0;
    uint32_t cachedHeight_ = 0;

    // Cached shader programs. 0 = not yet compiled.
    uint32_t blurProgram_ = 0;
    uint32_t blurVertexShader_ = 0;
    uint32_t blurFragmentShader_ = 0;
    uint32_t compositeProgram_ = 0;
    uint32_t compositeVertexShader_ = 0;
    uint32_t compositeFragmentShader_ = 0;

    // Cached intermediate FBOs and their color-attachment textures.
    // 0 = not yet allocated.
    uint32_t texA_ = 0;
    uint32_t texB_ = 0;
    uint32_t fboA_ = 0;
    uint32_t fboB_ = 0;

    // Cached fullscreen-quad VAO/VBO.
    uint32_t vao_ = 0;
    uint32_t vbo_ = 0;
};

} // namespace render
} // namespace vanguard
