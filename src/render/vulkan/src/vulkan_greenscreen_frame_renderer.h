// vulkan_greenscreen_frame_renderer.h
// ANDROID-DUET-VULKAN-GREENSCREEN-VISUAL: private helper -
// VulkanGreenScreenFrameRenderer.
//
// Isolated, compile-safe, record-only Vulkan helper that draws the CAMERA
// layer of a Duet green-screen frame: the camera import sampled through its
// OWN external-format descriptor set, alpha-masked by a mask image, and
// straight-alpha blended over whatever the caller already drew (the opaque
// source / decoder layer) into a caller-owned, already-open render pass.
//
// History: the previous revision of this helper drew a full-canvas
// three-texture blend through its own sampler2D descriptor set for every
// input. That sampled the external-format AHardwareBuffer imports without
// their immutable YCbCr sampler (green-tinted output) and ignored the Duet
// layout rects (full-screen, unrotated camera). The imported images are now
// only ever sampled through the import's own descriptor resources, exactly
// like the solo / transition / layout paths.
//
// recordCameraDraw() is record-only: the caller has already begun
// `commandBuffer` and already opened a render pass compatible with
// `renderPass` (via vkCmdBeginRenderPass) before calling this method, and
// remains responsible for ending that render pass, ending the command
// buffer, submitting, and presenting. This method never begins/ends a command
// buffer, never begins/ends a render pass, never acquires or presents a
// swapchain image, and never issues a queue submit, queue wait, or device
// wait.
//
// Draw model:
//   * Uses the AOT camera-mask fullscreen-triangle vertex SPIR-V
//     (shaders/greenscreen_camera_mask_vert_spv.h, kGreenScreenCameraMaskVertSpv,
//     glsl/greenscreen_camera_mask.vert) and the AOT camera-mask fragment
//     SPIR-V (shaders/greenscreen_blend_frag_spv.h,
//     kGreenScreenCameraMaskFragSpv, glsl/greenscreen_blend.frag compiled
//     with -DVANGUARD_DUET_CAMERA_MASK=1). The vertex shader emits both the
//     transformed camera UV (location 0) and the raw camera-rect UV
//     (location 1) the fragment stage samples the mask with.
//   * Fullscreen triangle, no vertex input. Dynamic viewport = the camera
//     rect (may start before / extend beyond the canvas), dynamic scissor =
//     the rect clipped to the canvas -- the same viewport / scissor / UV
//     crop contract AppendVulkanDuetLayoutLayer records for the layout
//     path's camera layer, so the caller resolves both through
//     ResolveVulkanDuetLayoutLayerPlacement (single source of truth).
//   * Pipeline layout:
//       set 0: the camera import's OWN descriptor set layout (binding 0,
//              COMBINED_IMAGE_SAMPLER, the import's immutable external-format
//              YCbCr sampler baked in), borrowed by handle for the draw and
//              never created or destroyed here;
//       set 1: this helper's mask set layout (binding 0,
//              COMBINED_IMAGE_SAMPLER, fragment stage, mutable sampler);
//       one VERTEX|FRAGMENT push-constant range of 128 bytes: the shared
//       112-byte VideoTransformFullPushConstants block (matching the shared
//       import pipeline layouts; see vulkan_descriptor_resources.h) plus a
//       trailing fragment-only vec4 maskDebug (debugMode, 1/maskWidth,
//       1/maskHeight, reserved).
//   * Straight-alpha blend over the destination: colour SRC_ALPHA /
//     ONE_MINUS_SRC_ALPHA, alpha ONE / ONE_MINUS_SRC_ALPHA, RGBA write mask.
//   * The mask is bound with this helper's own LINEAR / CLAMP_TO_EDGE sampler
//     (a GPU-mask AHardwareBuffer import carries a NEAREST sampler, and the
//     mask is typically 320x240 upscaled into the camera rect). The mask
//     image must therefore be a non-external-format sampled image (R8 CPU
//     upload or RGBA8 GPU import); its .r channel is the matte.
//   * VideoTransformFullPushConstants pushed verbatim from the caller
//     (aspect-fill crop + colour matrix resolved by the placement helper);
//     the fragment stage samples the mask at the same cropped UV as the
//     camera texel (see the shader for the mask-orientation caveat).
//   * vkCmdDraw(3, 1, 0, 0).
//
// Caching / lifecycle:
//   * Cached until shutdown(): shader modules, mask descriptor set layout,
//     mask sampler, descriptor pool and a ring of Impl::kPoolCapacity mask
//     descriptor sets (one consumed per recordCameraDraw() call; with two
//     frames in flight a set is only rewritten long after the frame that
//     used it has had its fence waited).
//   * Cached against the (camera descriptor set layout, render pass) pair
//     until invalidate() / shutdown(): the pipeline layout and the graphics
//     pipeline. needsPipelineRebuild() reports a cached pair built for a
//     different key; the CALLER must then idle the device and call
//     invalidate() before recording, since the previous pipeline may still
//     be in flight on the other frame slot -- exactly the protocol
//     VulkanFrameRenderer already uses for its layout-path pipeline cache.
//     recordCameraDraw() itself fails closed with
//     "vulkan_greenscreen_frame_renderer_pipeline_key_mismatch" on a
//     mismatch rather than destroying anything.
//   * invalidate(device) destroys only the pipeline and pipeline layout; the
//     mask set layout / sampler / pool / shader modules remain cached.
//   * shutdown(device) destroys every cached Vulkan object.
//   * Both invalidate() and shutdown() are idempotent.
//   * Cached resources survive after recordCameraDraw() returns; objects
//     referenced by the command buffer are not destroyed before
//     invalidate/shutdown.
//
// Platform isolation:
//   * Confined to the private Vulkan render backend implementation; never
//     included from a public header.
//   * Header contains NO Android or Vulkan headers on any platform:
//     dispatchable handles cross as void*, non-dispatchable handles as
//     uint64_t.
//   * On non-Android host builds, recordCameraDraw() compiles to a safe stub
//     returning false with a clear failure token; needsPipelineRebuild()
//     returns false; invalidate() and shutdown() are no-ops.

#pragma once

#include "vanguard/render/render_transform.h"

#include <cstdint>
#include <memory>
#include <string>

namespace vanguard {
namespace render {

// Inputs for one camera-over-source green-screen layer draw.
struct VulkanGreenScreenCameraDraw {
    // The camera import's own descriptor resources (VkDescriptorSetLayout /
    // VkDescriptorSet non-dispatchable handles widened to uint64_t). Borrowed
    // for this draw only; the import table keeps ownership.
    uint64_t cameraDescriptorSetLayout = 0;
    uint64_t cameraDescriptorSet = 0;

    // Mask VkImageView (uint64_t): a non-external-format R8 / RGBA8 sampled
    // image whose .r channel is the matte (0 -> source shows through,
    // 1 -> camera). Sampled with the helper's own sampler, so no sampler
    // handle is taken here. maskWidth / maskHeight are validated > 0 only.
    uint64_t maskImageView = 0;
    uint32_t maskWidth = 0;
    uint32_t maskHeight = 0;

    // RND debug visualization mode, forwarded to the fragment shader's
    // maskDebug.x (0 = normal, 1 = mask_direct, 2 = mask_mapped,
    // 3 = mask_direct_mirror_x, 4 = mask_direct_flip_y). camera_passthrough
    // and mask_full_white are not shader modes: camera_passthrough is routed
    // by the caller through the opaque Kotlin layout path entirely, and
    // mask_full_white keeps debugMode 0 (normal) with a forced 1x1 white
    // CPU mask upload.
    int32_t debugMode = 0;

    // Resolved placement (a VulkanDuetLayoutLayerPlacement flattened so this
    // header stays free of Vulkan headers): the viewport is the camera rect
    // itself (width / height > 0, may extend beyond the canvas), the scissor
    // is that rect clipped to the canvas (non-empty, non-negative origin,
    // fully inside the canvas).
    int32_t viewportX = 0;
    int32_t viewportY = 0;
    uint32_t viewportWidth = 0;
    uint32_t viewportHeight = 0;
    int32_t scissorX = 0;
    int32_t scissorY = 0;
    uint32_t scissorWidth = 0;
    uint32_t scissorHeight = 0;

    // Aspect-fill crop UV mapping + colour matrix, pushed verbatim.
    VideoTransformFullPushConstants pushConstants{};
};

class VulkanGreenScreenFrameRenderer {
public:
    VulkanGreenScreenFrameRenderer();
    ~VulkanGreenScreenFrameRenderer();

    VulkanGreenScreenFrameRenderer(const VulkanGreenScreenFrameRenderer&) = delete;
    VulkanGreenScreenFrameRenderer& operator=(const VulkanGreenScreenFrameRenderer&) = delete;

    // Returns true when a pipeline layout / pipeline is currently cached
    // against a DIFFERENT camera descriptor set layout or render pass than
    // the given ones, i.e. the caller must idle the device and call
    // invalidate() before the next recordCameraDraw(). Returns false when
    // nothing is cached yet or the cached key matches. Never touches Vulkan.
    bool needsPipelineRebuild(uint64_t cameraDescriptorSetLayout, uint64_t renderPass) const;

    // Records one alpha-masked camera layer draw into `commandBuffer`, which
    // must already be in the recording state inside an open render pass
    // compatible with `renderPass`.
    //
    // device           - VkDevice, as void*; owns every cached object.
    // commandBuffer    - VkCommandBuffer, as void*; recording inside `renderPass`.
    // renderPass       - VkRenderPass, as uint64_t, from which the open pass was created.
    // canvasWidth      - Canvas width in pixels (> 0); bounds the scissor.
    // canvasHeight     - Canvas height in pixels (> 0); bounds the scissor.
    // draw             - Camera descriptor resources, mask view, placement,
    //                    push constants (see VulkanGreenScreenCameraDraw).
    // outFailureReason - Non-null; cleared on success, set to an ASCII
    //                    "vulkan_greenscreen_frame_renderer_*" token on failure.
    //
    // Returns true on success; false on any validation or Vulkan creation
    // failure. Every validation failure happens before any Vulkan call.
    bool recordCameraDraw(
        void* device,
        void* commandBuffer,
        uint64_t renderPass,
        uint32_t canvasWidth,
        uint32_t canvasHeight,
        const VulkanGreenScreenCameraDraw& draw,
        std::string* outFailureReason);

    // Destroys only the cached pipeline and pipeline layout so the next
    // recordCameraDraw() call rebuilds them against a (possibly new) camera
    // descriptor set layout / render pass. The caller must have established
    // that no submitted frame still references them (device idle wait).
    // Idempotent; no-op on non-Android host builds.
    void invalidate(void* device);

    // Destroys all cached Vulkan objects (pipeline, pipeline layout, mask
    // descriptor set layout, mask sampler, descriptor pool, shader modules).
    // Idempotent; no-op on non-Android host builds.
    void shutdown(void* device);

private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};

} // namespace render
} // namespace vanguard
