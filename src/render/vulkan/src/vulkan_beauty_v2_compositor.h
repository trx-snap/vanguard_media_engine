// vulkan_beauty_v2_compositor.h
// P5-BEAUTY-V2-VULKAN-RENDER: Private helper - VulkanBeautyV2Compositor.
//
// Diagnostic-only Vulkan port of the exact global (non-FaceAware) 3-pass
// Beauty V2 bilateral smoothing pipeline already verified for GLES
// (render/gles/src/gles_beauty_v2_compositor.h): Pass 1 horizontal bilateral
// blur, Pass 2 vertical bilateral blur, Pass 3 composite (fused highpass,
// adaptive smoothing gate, soft-S tone compression, midtone lift, detail
// add-back, alpha preservation). All FaceAware/mask/feature/enhance/polish
// layers are permanently discarded, matching the GLES twin.
//
// This helper is NOT a graph node and owns no timeline, DAG, or session
// state. It executes three fragment-render passes (blur_h, blur_v,
// composite) over VK_FORMAT_R8G8B8A8_UNORM images using the existing
// fullscreen-triangle vertex shader (shaders/passthrough_vert_spv.h) plus
// two new fragment shaders (shaders/beauty_v2_blur_frag_spv.h,
// shaders/beauty_v2_composite_frag_spv.h), clamp-to-edge samplers, and
// helper-owned intermediate images/samplers/render passes/pipelines/
// descriptor objects created and destroyed fresh on every DrawBeautyV2 call.
// The caller (a diagnostic JNI in this slice) owns the source sampled image,
// the target color attachment, and the readback buffer; the composition
// root also owns the VkDevice/VkQueue/VkCommandPool.
//
// vanguard_render_vulkan never includes a GLES header: VulkanBeautyV2Parameters
// mirrors GlesBeautyV2Parameters field-for-field (same names, types, and
// defaults) purely by convention, verified independently by static_assert in
// the diagnostic JNI translation unit, never by including
// gles_beauty_v2_compositor.h from this library.
//
// Shader strategy (two new fragment shaders, one reused vertex shader):
//   * Vertex: the existing AOT passthrough fullscreen-triangle vertex module
//     (shaders/passthrough_vert_spv.h) is reused unmodified. It declares a
//     112-byte push-constant block (VideoTransformFullPushConstants) and
//     reads only its first 32 bytes (uvTransform0/uvTransform1) to compute a
//     UV varying this helper's fragment shaders do not consume (they address
//     texels purely through gl_FragCoord, exactly like the GLES shaders).
//     The helper supplies a VK_SHADER_STAGE_VERTEX_BIT push-constant range
//     covering the full declared bytes [0, 112) of that block (Vulkan
//     requires the pipeline layout's range for a stage to cover the whole
//     push-constant block the shader module declares, not just the bytes it
//     statically reads), populated with identity UV-transform values in
//     bytes [0, 32) only.
//   * Fragment: beauty_v2_blur.frag (shared by Pass 1/2 via an `axis` push
//     constant, one combined image sampler at binding 0) and
//     beauty_v2_composite.frag (Pass 3, two combined image samplers at
//     bindings 0/1: orig, mean). Each fragment shader reads only its own
//     fragment-only push-constant range starting at byte offset 32 (see the
//     .frag source headers for the exact layout), non-overlapping with the
//     vertex range.
//
// Ownership / lifecycle: every DrawBeautyV2 call creates two intermediate
// VK_FORMAT_R8G8B8A8_UNORM images (Pass 1/2 targets) with their own device
// memory, image views, and one shared clamp-to-edge/NEAREST sampler; two
// shader modules; two descriptor set layouts (1-binding blur, 2-binding
// composite) plus one descriptor pool holding three sets (blur-H, blur-V,
// composite); two pipeline layouts; two render passes (an intermediate pass
// used for both Pass 1 and Pass 2 framebuffers, and a target pass used for
// the caller's color attachment); three framebuffers; two pipelines
// (blur, composite); one command buffer from the caller's pool; and one
// fence. Every temporary object created is destroyed/freed on every success
// and failure path before DrawBeautyV2 returns; temporaryObjectsCreated() ==
// temporaryObjectsReleased() whenever no call is in progress. The helper
// never creates or destroys the device, queue, command pool, the caller's
// source sampled image/view/sampler, the caller's target color image/view,
// or the caller's readback buffer/memory. The call is synchronous: it
// submits once and waits on its own fence, so on return the caller's
// readback buffer holds the rendered RGBA8 pixels (tightly packed, row
// pitch = extentWidth * 4).
//
// No production VulkanBackend mutation, no MediaCodec/decode, no
// AHardwareBuffer/external image import, no export/playback/app/editor UI.
//
// Private source: this header is confined to the private Vulkan render
// backend implementation. On Android it includes <vulkan/vulkan.h>; on
// non-Android host builds the Vulkan handle fields become void*/uint32_t
// mirrors and DrawBeautyV2() compiles to a safe unavailable stub, matching
// the other private Vulkan helpers (e.g. VulkanOverlayCompositor). The pure
// validation / ramp math compiles on every platform.

#pragma once

#include <cstdint>
#include <string>

#if defined(__ANDROID__)
#ifndef VK_USE_PLATFORM_ANDROID_KHR
#define VK_USE_PLATFORM_ANDROID_KHR
#endif
#include <vulkan/vulkan.h>
#endif

namespace vanguard {
namespace render {

// Tunable Beauty V2 parameters for one DrawBeautyV2 call. Field-for-field
// mirror of GlesBeautyV2Parameters (render/gles/src/gles_beauty_v2_compositor.h):
// same names, types, and defaults (intensity=0.75 production default ->
// radius=10, sigma=5.5, smoothStrength=0.90, sharpenStrength=0.25,
// theta=0.06, rangeSigma=0.10, detailDamping=0.55, toneStrength=0.25,
// midtoneLift=0.045).
struct VulkanBeautyV2Parameters {
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

// Pure, platform-independent validation (no Vulkan calls) of `params`
// against a width x height render target. Evaluates in exactly this order,
// returning false and setting *outError to the first failure:
//   1. outError == nullptr                                 -> (no report possible; returns false)
//   2. width == 0 || height == 0                            -> "vulkan_beauty_v2_invalid_dimensions"
//   3. non-finite or out-of-range params (radius < 1,
//      sigma < 1.0, rangeSigma < 0.01, theta < 0.001,
//      any strength/damping/lift < 0.0)                     -> "vulkan_beauty_v2_invalid_parameters"
// On success, *outError is cleared and the function returns true.
bool ValidateVulkanBeautyV2Parameters(const VulkanBeautyV2Parameters& params,
                                      uint32_t width,
                                      uint32_t height,
                                      std::string* outError);

// Pure, platform-independent parameter ramp calculator (no Vulkan calls).
// Computes the full parameter set from a master intensity scalar
// `intensity` in [0.0, 1.0]; mirrors
// ComputeBeautyV2ParametersFromIntensity (gles_beauty_v2_compositor.cpp)
// line-for-line, including the resolution spatial-scale factor
// S = max(1.0, min(width, height) / 1080.0). Evaluates in exactly this
// order, returning false and setting *outError to the first failure:
//   1. outError == nullptr || outParams == nullptr           -> (no report possible; returns false)
//   2. width == 0 || height == 0                              -> "vulkan_beauty_v2_invalid_dimensions"
//   3. !isfinite(intensity) || intensity < 0 || intensity > 1 -> "vulkan_beauty_v2_invalid_intensity"
// On success, *outParams is filled with values guaranteed to already satisfy
// ValidateVulkanBeautyV2Parameters, *outError is cleared, and the function
// returns true.
bool ComputeVulkanBeautyV2ParametersFromIntensity(float intensity,
                                                   uint32_t width,
                                                   uint32_t height,
                                                   VulkanBeautyV2Parameters* outParams,
                                                   std::string* outError);

// Caller-owned combined image sampler pair holding the source raster to
// beautify; not owned by the helper. Both must be non-null; per the frozen
// contract the sampler should use clamp-to-edge addressing (the helper
// cannot query or validate sampler state, matching VulkanOverlayCompositor's
// equivalent disclaimer).
struct VulkanBeautyV2SourceImage {
#if defined(__ANDROID__)
    VkImageView imageView = VK_NULL_HANDLE;
    VkSampler   sampler   = VK_NULL_HANDLE;
#else
    void* imageView = nullptr;
    void* sampler   = nullptr;
#endif
};

// Caller-owned device context plus target color attachment and readback
// staging buffer. Nothing in this struct is created or destroyed by the
// helper.
struct VulkanBeautyV2RenderTarget {
#if defined(__ANDROID__)
    // Needed only so the helper can allocate device-local memory for its own
    // per-call intermediate images (texA/texB); the helper never creates or
    // destroys the physical device itself.
    VkPhysicalDevice physicalDevice = VK_NULL_HANDLE;
    VkDevice      device      = VK_NULL_HANDLE;
    VkQueue       queue       = VK_NULL_HANDLE;
    VkCommandPool commandPool = VK_NULL_HANDLE;
    // Pass 3 (composite) target image: 2D, must be VK_FORMAT_R8G8B8A8_UNORM,
    // single mip/layer, usage must include COLOR_ATTACHMENT_BIT |
    // TRANSFER_SRC_BIT. Left in VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL after
    // every successful render.
    VkImage       colorImage     = VK_NULL_HANDLE;
    VkImageView   colorImageView = VK_NULL_HANDLE;
    VkFormat      colorFormat    = VK_FORMAT_R8G8B8A8_UNORM;
    // Host-visible readback buffer with usage TRANSFER_DST_BIT and size of at
    // least extentWidth * extentHeight * 4 bytes (declared by the caller in
    // readbackBufferSizeBytes; validated, not queried).
    VkBuffer      readbackBuffer          = VK_NULL_HANDLE;
    VkDeviceSize  readbackBufferSizeBytes = 0;
#else
    void*    physicalDevice = nullptr;
    void*    device      = nullptr;
    void*    queue       = nullptr;
    void*    commandPool = nullptr;
    void*    colorImage     = nullptr;
    void*    colorImageView = nullptr;
    uint32_t colorFormat    = 0;
    void*    readbackBuffer          = nullptr;
    uint64_t readbackBufferSizeBytes = 0;
#endif
    uint32_t extentWidth  = 0;
    uint32_t extentHeight = 0;
};

class VulkanBeautyV2Compositor {
public:
    VulkanBeautyV2Compositor();
    ~VulkanBeautyV2Compositor();

    VulkanBeautyV2Compositor(const VulkanBeautyV2Compositor&) = delete;
    VulkanBeautyV2Compositor& operator=(const VulkanBeautyV2Compositor&) = delete;

    // Executes the 3-pass bilateral beauty smoothing pipeline (blur_h ->
    // blur_v -> composite) against `source`, writing into `target` and
    // copying the result into target.readbackBuffer (see the draw model in
    // the file header).
    //
    // target   - physicalDevice/device/queue/commandPool, color attachment,
    //            readback buffer. Every handle must be non-null, colorFormat must be
    //            VK_FORMAT_R8G8B8A8_UNORM, extents > 0, and
    //            readbackBufferSizeBytes >= extentWidth*extentHeight*4, else
    //            outError = "vulkan_beauty_v2_invalid_dimensions".
    // source   - caller-owned source image view + sampler. Either being
    //            null yields outError = "vulkan_beauty_v2_invalid_image".
    // params   - validated beauty parameters (see
    //            ValidateVulkanBeautyV2Parameters); invalid params yield
    //            outError = "vulkan_beauty_v2_invalid_parameters".
    // outError - non-null; set to "" on success, to one of the validation
    //            reasons above, or to one of
    //            "vulkan_beauty_v2_image_failed"
    //            "vulkan_beauty_v2_shader_module_failed"
    //            "vulkan_beauty_v2_descriptor_failed"
    //            "vulkan_beauty_v2_render_pass_failed"
    //            "vulkan_beauty_v2_pipeline_failed"
    //            "vulkan_beauty_v2_command_buffer_failed"
    //            "vulkan_beauty_v2_submit_failed"
    //            "vulkan_beauty_v2_wait_failed"
    //            for Vulkan-stage failures.
    //
    // Returns true only if every Vulkan object creation, the submit, and the
    // fence wait succeeded. Returns false with
    // outError="vulkan_beauty_v2_unavailable_on_host" and no Vulkan calls on
    // non-Android builds. Validation runs before any Vulkan call; on
    // validation failure zero Vulkan objects are created. On every other
    // failure path, every temporary object created so far by this call is
    // destroyed/freed before returning.
    bool DrawBeautyV2(const VulkanBeautyV2RenderTarget& target,
                      const VulkanBeautyV2SourceImage& source,
                      const VulkanBeautyV2Parameters& params,
                      std::string* outError);

    // Lifecycle telemetry for diagnostics: cumulative count of temporary
    // Vulkan objects this instance created (successful vkCreate*/vkAllocate*)
    // and released (vkDestroy*/vkFree*). They are equal whenever no
    // DrawBeautyV2() call is in progress; a difference indicates a leak.
    uint64_t temporaryObjectsCreated() const { return temporaryObjectsCreated_; }
    uint64_t temporaryObjectsReleased() const { return temporaryObjectsReleased_; }

private:
    uint64_t temporaryObjectsCreated_  = 0;
    uint64_t temporaryObjectsReleased_ = 0;
};

} // namespace render
} // namespace vanguard
