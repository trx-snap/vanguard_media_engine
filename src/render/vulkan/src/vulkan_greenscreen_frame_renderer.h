// vulkan_greenscreen_frame_renderer.h
// DUET-VULKAN-GREENSCREEN-FRAME-RENDERER: private helper -
// VulkanGreenScreenFrameRenderer.
//
// Isolated, compile-safe, record-only Vulkan helper that blends a foreground
// image over a background image using a single-channel R8 mask image into a
// caller-owned, already-open render pass.
//
// recordGreenScreenDraw() is record-only: the caller has already begun
// `commandBuffer` and already opened a render pass compatible with
// `renderPass` (via vkCmdBeginRenderPass) before calling this method, and
// remains responsible for ending that render pass, ending the command
// buffer, submitting, and presenting. This method never begins/ends a command
// buffer, never begins/ends a render pass, never acquires or presents a
// swapchain image, and never issues a queue submit, queue wait, or device
// wait.
//
// VulkanGreenScreenFrameInputs carries the background, foreground, and mask
// sampled image view and sampler handles widened to uint64_t (non-dispatchable
// Vulkan handles, never cast through void*, so this header never needs
// <vulkan/vulkan.h> or Android headers), plus the mask width and height.
//
// Draw model:
//   * Reuses existing AOT fullscreen-triangle vertex SPIR-V
//     (shaders/passthrough_vert_spv.h) and AOT green-screen blend fragment
//     SPIR-V (shaders/greenscreen_blend_frag_spv.h).
//   * Fullscreen triangle, no vertex input.
//   * Dynamic viewport and scissor set to the full canvas extent.
//   * Cull none, front-face counter-clockwise.
//   * Fixed-function blend disabled; fragment shader mix() is written
//     directly to the color attachment (RGBA color write mask).
//   * Combined image sampler descriptor set bound at set 0:
//       binding 0: background (RGBA8_UNORM)
//       binding 1: foreground (RGBA8_UNORM)
//       binding 2: mask (R8_UNORM)
//   * VideoTransformFullPushConstants pushed with identity UV transform
//     (u = x, v = y) and identity color matrix.
//   * vkCmdDraw(3, 1, 0, 0).
//
// Caching / lifecycle:
//   * Lazily created and cached until invalidate() or shutdown():
//     shader modules, descriptor set layout, pipeline layout, descriptor pool,
//     and graphics pipeline.
//   * If `renderPass` changes while a pipeline is cached, recordGreenScreenDraw()
//     fails closed with "vulkan_greenscreen_frame_renderer_render_pass_mismatch".
//     The caller can call invalidate(device) first when the render pass has
//     legitimately changed.
//   * invalidate(device) destroys only the render-pass-bound pipeline; the
//     descriptor set layout, pipeline layout, descriptor pool, and shader
//     modules remain cached.
//   * shutdown(device) destroys every cached Vulkan object.
//   * Both invalidate() and shutdown() are idempotent.
//   * Cached resources survive after recordGreenScreenDraw returns; objects
//     referenced by the command buffer are not destroyed before invalidate/shutdown.
//
// Platform isolation:
//   * Confined to the private Vulkan render backend implementation; never
//     included from a public header.
//   * Header contains NO Android or Vulkan headers on any platform: dispatchable
//     handles cross as void*, non-dispatchable handles as uint64_t.
//   * On non-Android host builds, recordGreenScreenDraw() compiles to a safe
//     stub returning false with a clear failure token; invalidate() and
//     shutdown() are no-ops.

#pragma once

#include <cstdint>
#include <memory>
#include <string>

namespace vanguard {
namespace render {

// Image-sampler pair handle container with compatibility aliases.
struct VulkanGreenScreenFrameSampledImage {
    union {
        uint64_t imageView = 0;
        uint64_t imageViewHandle;
    };
    union {
        uint64_t sampler = 0;
        uint64_t samplerHandle;
    };
};

// Inputs for one green-screen blend frame draw.
// Supports direct handle access (with or without 'Handle' suffix) or
// grouped access through background/foreground/mask sub-objects.
struct VulkanGreenScreenFrameInputs {
    union {
        struct {
            uint64_t backgroundImageView;
            uint64_t backgroundSampler;
            uint64_t foregroundImageView;
            uint64_t foregroundSampler;
            uint64_t maskImageView;
            uint64_t maskSampler;
        };
        struct {
            uint64_t backgroundImageViewHandle;
            uint64_t backgroundSamplerHandle;
            uint64_t foregroundImageViewHandle;
            uint64_t foregroundSamplerHandle;
            uint64_t maskImageViewHandle;
            uint64_t maskSamplerHandle;
        };
        struct {
            VulkanGreenScreenFrameSampledImage background;
            VulkanGreenScreenFrameSampledImage foreground;
            VulkanGreenScreenFrameSampledImage mask;
        };
    };
    uint32_t maskWidth = 0;
    uint32_t maskHeight = 0;

    VulkanGreenScreenFrameInputs()
        : backgroundImageView(0), backgroundSampler(0),
          foregroundImageView(0), foregroundSampler(0),
          maskImageView(0), maskSampler(0),
          maskWidth(0), maskHeight(0) {}
};

class VulkanGreenScreenFrameRenderer {
public:
    VulkanGreenScreenFrameRenderer();
    ~VulkanGreenScreenFrameRenderer();

    VulkanGreenScreenFrameRenderer(const VulkanGreenScreenFrameRenderer&) = delete;
    VulkanGreenScreenFrameRenderer& operator=(const VulkanGreenScreenFrameRenderer&) = delete;

    // Records one three-texture green-screen mask blend draw into `commandBuffer`,
    // which must already be in the recording state inside an open render pass
    // compatible with `renderPass`.
    //
    // device           - VkDevice, as void*; owns every cached object.
    // commandBuffer    - VkCommandBuffer, as void*; recording inside `renderPass`.
    // renderPass       - VkRenderPass, as uint64_t, from which the open pass was created.
    // canvasWidth      - Canvas width in pixels (> 0).
    // canvasHeight     - Canvas height in pixels (> 0).
    // inputs           - Background, foreground, and mask image views and samplers.
    // outFailureReason - Non-null; cleared on success, set to an ASCII
    //                    "vulkan_greenscreen_frame_renderer_*" token on failure.
    //
    // Returns true on success; false on any validation or Vulkan creation failure.
    bool recordGreenScreenDraw(
        void* device,
        void* commandBuffer,
        uint64_t renderPass,
        uint32_t canvasWidth,
        uint32_t canvasHeight,
        const VulkanGreenScreenFrameInputs& inputs,
        std::string* outFailureReason);

    // Destroys only the cached render-pass-bound pipeline so the next
    // recordGreenScreenDraw() call rebuilds it against a (possibly new)
    // renderPass. Idempotent; no-op on non-Android host builds.
    void invalidate(void* device);

    // Destroys all cached Vulkan objects (pipeline, pipeline layout,
    // descriptor set layout, descriptor pool, shader modules).
    // Idempotent; no-op on non-Android host builds.
    void shutdown(void* device);

private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};

} // namespace render
} // namespace vanguard
