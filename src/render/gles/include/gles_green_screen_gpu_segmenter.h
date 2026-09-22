// gles_green_screen_gpu_segmenter.h
// ANDROID-GREENSCREEN-GPU-SEGMENTER: private helper - GlesGreenScreenGpuSegmenter.
//
// Reusable, caller-agnostic GPU-resident green-screen segmentation core,
// extracted from the committed GlesGreenScreenGpuResidentRenderer so a host
// compositor that already owns its own EGL context, camera OES texture,
// output surface, background layers and swap can run the proven
// downscale -> [TFLite interpreter] -> coarse mask upload -> guided filter
// (-> optional temporal) refinement inside its OWN render pass and then
// sample the refined alpha texture from its own draw.
//
// Owns ONLY:
//   - model-input RGBA8 texture + FBO (GPU downscale target + readback),
//   - coarse R8 mask texture (interpreter output upload),
//   - R32F alpha ping / pong / history textures (refined alpha),
//   - the downscale / guided-filter / temporal compute programs,
//   - the CPU scratch buffers for the NEON float pack / mask pack.
//
// Does NOT own (and never touches the lifetime of): the EGL display /
// context / surfaces, the camera GL_TEXTURE_EXTERNAL_OES texture (passed in
// per call), any output window, background or source-video layer, and never
// calls eglSwapBuffers. The TFLite interpreter stays with the host (Kotlin).
//
// Requirements on the caller:
//   - An OpenGL ES 3.1 (or newer) context with GL_OES_EGL_image_external_essl3
//     must be current on the calling thread for every method. Initialize()
//     verifies both and fails closed otherwise (no GL objects are left behind).
//   - Single thread only (the host's render thread). No internal locking.
//   - The camera OES texture handed to DownscaleCameraToModelInput /
//     RefineAlpha must already hold the latched frame (updateTexImage done)
//     and the transform matrix latched with that frame must have been passed
//     to SetCameraTransform.
//
// Camera UV policy (identical to the committed renderer / shaders):
//   camUv = (cameraStMatrix * vec4(quadUv, 0, 1)).xy, where quadUv is the
//   [0,1]^2 coordinate of the displayed camera layer with v=0 at the bottom.
//   The refined alpha texture lives in that same quad space, so a host that
//   draws the camera through a `uSTMatrix * aTextureCoord` vertex path
//   samples the alpha at the raw (untransformed) quad texture coordinate.
//
// GL state left behind by every pass: program 0, texture unit 0 active with
// nothing bound on GL_TEXTURE_2D / GL_TEXTURE_EXTERNAL_OES, framebuffer 0,
// GL_UNPACK_ALIGNMENT restored to 4 and GL_PACK_ALIGNMENT at 4. Viewport,
// scissor, blend and vertex-array state are never touched.
//
// Private header: EGL/GLES/Android headers never appear here; the .cpp
// confines them behind #if defined(__ANDROID__) and compiles to a failing
// stub elsewhere.

#pragma once

#include <cstddef>
#include <cstdint>
#include <string>
#include <vector>

namespace vanguard {
namespace render {

/** Cumulative per-session counters for the host's release-time summary log. */
struct GlesGreenScreenGpuSegmenterStats {
    uint64_t downscales = 0;
    uint64_t maskUploads = 0;
    uint64_t refinePasses = 0;
    double totalDownscaleMs = 0.0;
    double totalRefineMs = 0.0;
    float lastDownscaleMs = 0.0f;
    float lastRefineMs = 0.0f;
};

class GlesGreenScreenGpuSegmenter {
public:
    GlesGreenScreenGpuSegmenter();
    ~GlesGreenScreenGpuSegmenter();

    GlesGreenScreenGpuSegmenter(const GlesGreenScreenGpuSegmenter&) = delete;
    GlesGreenScreenGpuSegmenter& operator=(const GlesGreenScreenGpuSegmenter&) = delete;

    // -- Lifecycle ----------------------------------------------------------

    /**
     * Verifies the CURRENT context is ES 3.1+ with
     * GL_OES_EGL_image_external_essl3, then compiles the three compute
     * programs. On failure every partial GL object is deleted and *error
     * describes the first failure. Idempotent once initialized.
     */
    bool Initialize(std::string* error);

    /**
     * Deletes every GL object this segmenter owns. Requires the owning
     * context to be current (the host must call this BEFORE destroying its
     * context). Idempotent, never throws.
     */
    void Destroy();

    bool IsInitialized() const { return initialized_; }

    // -- Configuration ---------------------------------------------------------

    /** Allocates the model-input RGBA8 texture + FBO for the interpreter's
     *  input tensor size (re-allocates on size change). */
    bool ConfigureModelInput(int width, int height, std::string* error);

    /**
     * Latches the SurfaceTexture transform matrix (column-major 4x4, as
     * returned by getTransformMatrix) plus the upright camera aspect
     * (width / height after that transform) used for the alpha resolution.
     */
    void SetCameraTransform(const float stMatrixColumnMajor[16], float cameraUprightAspect);

    /**
     * Output (host surface) size the refined alpha resolution is derived
     * from: long side clamped to [64, 1280] with the upright camera aspect,
     * exactly like the committed renderer. Alpha textures are (re)allocated
     * lazily on the next RefineAlpha when the derived size changes.
     */
    void SetAlphaTargetSize(int outputWidthPx, int outputHeightPx);

    /** Guided filter on/off, temporal stabilizer on/off (RND defaults: on / off). */
    void SetFilterToggles(bool guidedFilter, bool temporalStabilizer);

    // -- Frame transaction ---------------------------------------------------

    /**
     * GPU-downscales the latched camera frame (sampled from [cameraOesTexture]
     * through the latched transform) into the model input texture, reads it
     * back and packs it as normalized float RGB (NHWC, row 0 = top) into
     * outRgbFloats (must hold width*height*3 floats).
     */
    bool DownscaleCameraToModelInput(uint32_t cameraOesTexture, float* outRgbFloats, size_t outFloatCount,
                                     std::string* error);

    /**
     * Converts a float32 single-channel mask (row 0 = top, width*height
     * floats, values clamped to [0,1]) to R8 and uploads it as the coarse
     * alpha texture.
     */
    bool UploadCoarseMask(const float* mask, size_t floatCount, int width, int height, std::string* error);

    /**
     * Guided filter (+ optional temporal) over the coarse mask, sampling
     * camera luminance from [cameraOesTexture]. Fails (false) when no coarse
     * mask has been uploaded yet. On success RefinedAlphaTextureId() /
     * AlphaWidth() / AlphaHeight() describe the result.
     */
    bool RefineAlpha(uint32_t cameraOesTexture, std::string* error);

    /** R32F, GL_NEAREST, CLAMP_TO_EDGE texture holding the latest refined alpha (0 = none yet). */
    uint32_t RefinedAlphaTextureId() const { return hasRefinedAlpha_ ? activeAlphaTexture_ : 0u; }
    int AlphaWidth() const { return alphaWidth_; }
    int AlphaHeight() const { return alphaHeight_; }
    bool HasCoarseMask() const { return hasCoarseMask_; }
    bool HasRefinedAlpha() const { return hasRefinedAlpha_; }

    /**
     * Forgets the current coarse mask and refined alpha (textures are kept
     * for reuse) so a re-enabled host never composites a stale matte. Also
     * resets the temporal history so it does not blend across the gap.
     */
    void ResetMaskState();

    const GlesGreenScreenGpuSegmenterStats& stats() const { return stats_; }
    std::string StatsSummary() const;

private:
    bool CreatePrograms(std::string* error);
    bool EnsureAlphaTextures(int width, int height, std::string* error);
    bool EnsureCoarseAlphaTexture(int width, int height, std::string* error);
    void DeriveAlphaResolution(int* width, int* height) const;
    bool RunGuidedFilter(uint32_t cameraOesTexture, std::string* error);
    bool RunTemporalStabilizer(std::string* error);
    void DestroyGlObjects();

    bool initialized_ = false;

    int modelInputWidth_ = 0;
    int modelInputHeight_ = 0;
    int outputWidth_ = 0;
    int outputHeight_ = 0;

    // GL objects.
    uint32_t modelInputTexture_ = 0;
    uint32_t modelInputFbo_ = 0;
    uint32_t coarseAlphaTexture_ = 0;
    uint32_t alphaPingTexture_ = 0;
    uint32_t alphaPongTexture_ = 0;
    uint32_t alphaHistoryTexture_ = 0;

    uint32_t downscaleProgram_ = 0;
    uint32_t guidedProgram_ = 0;
    uint32_t temporalProgram_ = 0;

    // Uniform locations.
    int32_t downscaleModelSizeLoc_ = -1;
    int32_t downscaleStMatrixLoc_ = -1;
    int32_t guidedAlphaResolutionLoc_ = -1;
    int32_t guidedStMatrixLoc_ = -1;
    int32_t guidedFilterEnabledLoc_ = -1;
    int32_t temporalAlphaResolutionLoc_ = -1;

    int coarseAlphaWidth_ = 0;
    int coarseAlphaHeight_ = 0;
    int alphaWidth_ = 0;
    int alphaHeight_ = 0;
    uint32_t activeAlphaTexture_ = 0;
    bool hasCoarseMask_ = false;
    bool hasRefinedAlpha_ = false;
    bool temporalHistoryValid_ = false;

    float cameraStMatrix_[16];
    float cameraUprightAspect_ = 1080.0f / 1920.0f;

    bool guidedFilterEnabled_ = true;
    bool temporalEnabled_ = false;

    std::vector<uint8_t> modelInputRgba_;
    std::vector<uint8_t> coarseAlphaBytes_;

    GlesGreenScreenGpuSegmenterStats stats_;
};

}  // namespace render
}  // namespace vanguard
