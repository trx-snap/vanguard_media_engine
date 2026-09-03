// vulkan_overlay_frame_renderer.h
// P5-OVERLAYS-TRANS / P5-OVERLAYS-PRODUCTION-EXPORT-ROUTE-A: private helper -
// VulkanOverlayFrameRenderer (native helper sub-slice N1).
//
// Isolated, compile-safe, record-only Vulkan helper that draws an ordered
// list of already-resolved overlay layers ("draws") into a caller-owned,
// already-open render pass. This sub-slice adds the helper in complete
// isolation: it is NOT called from VulkanFrameRenderer, VulkanBackend, JNI,
// or Kotlin yet, and no such wiring is part of this file. A later sub-slice
// integrates it.
//
// recordOverlayDraws() is record-only, matching the production contract used
// by VulkanBeautyFrameRenderer::recordBeauty() (see
// vulkan_beauty_frame_renderer.h): the caller has already begun
// `commandBuffer` and already opened a render pass compatible with
// `renderPass` (via vkCmdBeginRenderPass) before calling this method, and
// remains responsible for ending that render pass, ending the command
// buffer, submitting, and presenting. This method never begins/ends a
// command buffer, never begins/ends a render pass, never acquires or
// presents a swapchain image, and never issues a queue submit, queue wait,
// or device wait.
//
// Each VulkanOverlayFrameDraw carries one already-resolved overlay layer:
// the sampled image view / sampler (non-dispatchable Vulkan handles widened
// to uint64_t, never cast through void*, so this header never needs
// <vulkan/vulkan.h>), the inverse UV placement rows, the clipped scissor
// rectangle, and opacity -- the same shape as
// VulkanOverlayLayerPlacement::uvRow0/uvRow1/scissorX/scissorY/scissorWidth/
// scissorHeight produced by ComputeVulkanOverlayPlacement
// (vulkan_overlay_compositor.h). Callers resolve placement before
// populating this struct; this helper performs no placement math of its
// own.
//
// Draw model, mirroring vulkan_overlay_compositor.cpp's blend pipeline
// (read-only reference for this slice; not modified by it): one
// straight-alpha Porter-Duff source-over draw per draw entry, a shared
// full-canvas dynamic viewport, a per-draw dynamic scissor, one
// combined-image-sampler descriptor set per draw bound at set 0 binding 0,
// VideoTransformFullPushConstants pushed per draw (UV rows verbatim in the
// vertex rows; identity color rows 0..2 and (0, 0, 0, opacity) in row 3 so
// only the sampled alpha is scaled), vkCmdDraw(3, 1, 0, 0) against the
// existing AOT passthrough vertex/fragment SPIR-V (fullscreen triangle, no
// vertex input) supplied by the caller.
//
// overlayCount == 0 is a validated no-op: returns true immediately with zero
// Vulkan calls, regardless of the other arguments. overlayCount > 0
// validates every required handle, the canvas extent, and every draw's
// scissor / opacity / UV rows before any Vulkan call, and fails closed
// (returns false, records nothing) on the first invalid input.
//
// Lazily created and cached for the life of the device (not per call):
// descriptor set layout, pipeline layout (single
// VideoTransformFullPushConstants push range, vertex + fragment stages),
// and the straight-alpha blend pipeline (built against the `renderPass` /
// `vertexModule` / `fragmentModule` of the first successful call; a later
// call with a different renderPass or shader module fails closed with
// "vulkan_overlay_frame_renderer_render_pass_mismatch" -- call invalidate()
// first once the caller's render pass has legitimately changed, e.g. a
// swapchain resize, and no in-flight command buffer still references the
// old pipeline). The descriptor pool is grow-only: it is (re)created only
// when a call needs more descriptor sets than its current capacity, and
// otherwise reset (vkResetDescriptorPool) and re-populated with exactly
// `overlayCount` fresh descriptor sets on every call.
//
// invalidate(device) destroys only the render-pass-bound pipeline; the
// descriptor set layout, pipeline layout, and descriptor pool are left
// intact and reused by the next recordOverlayDraws() call. shutdown(device)
// destroys every cached Vulkan object. Both are idempotent.
//
// Confined to the private Vulkan render backend implementation; never
// included from a public header. This header includes only <cstdint>,
// <memory>, <string>, and the shared, platform-neutral render_transform.h
// (for VideoTransformFullPushConstants) -- no Android or Vulkan header on
// either platform: every Vulkan/Android type is confined to the .cpp
// translation unit, dispatchable handles (VkDevice, VkCommandBuffer,
// VkShaderModule) cross this header as void*, and non-dispatchable handles
// (VkRenderPass, VkImageView, VkSampler) cross as uint64_t. On non-Android
// host builds recordOverlayDraws() compiles to a safe stub that returns
// true only for the overlayCount == 0 no-op case; invalidate()/shutdown()
// are no-ops.

#pragma once

#include "vanguard/render/render_transform.h"

#include <cstdint>
#include <memory>
#include <string>

namespace vanguard {
namespace render {

// One already-resolved overlay layer draw. imageViewHandle/samplerHandle are
// non-dispatchable VkImageView/VkSampler handles widened to uint64_t (a
// non-dispatchable handle is always uint64_t-sized on every ABI Vulkan
// supports, so it round-trips through uint64_t exactly, unlike void* which
// is only pointer-sized). uvRow0/uvRow1 are the two push-constant UV rows
// produced by the caller's inverse-placement math (e.g.
// ComputeVulkanOverlayPlacement's VulkanOverlayLayerPlacement::uvRow0/
// uvRow1). scissorX/scissorY/scissorWidth/scissorHeight are the
// top-left-origin, Y-down clipped scissor rectangle in canvas pixels (must
// lie within the canvas extent passed to recordOverlayDraws). opacity in
// [0, 1] is multiplied into the sampled alpha only (straight alpha, RGB
// untouched).
struct VulkanOverlayFrameDraw {
    uint64_t imageViewHandle = 0;
    uint64_t samplerHandle = 0;
    float uvRow0[4] = {1.0f, 0.0f, 0.0f, 0.0f};
    float uvRow1[4] = {0.0f, 1.0f, 0.0f, 0.0f};
    int32_t scissorX = 0;
    int32_t scissorY = 0;
    uint32_t scissorWidth = 0;
    uint32_t scissorHeight = 0;
    float opacity = 1.0f;
};

class VulkanOverlayFrameRenderer {
public:
    VulkanOverlayFrameRenderer();
    ~VulkanOverlayFrameRenderer();

    VulkanOverlayFrameRenderer(const VulkanOverlayFrameRenderer&) = delete;
    VulkanOverlayFrameRenderer& operator=(const VulkanOverlayFrameRenderer&) = delete;

    // Records one straight-alpha draw per entry of `draws` into
    // `commandBuffer`, which must already be in the recording state with an
    // open render pass compatible with `renderPass` (this method neither
    // begins/ends the command buffer nor begins/ends a render pass, and
    // never acquires, presents, submits, or waits).
    //
    // device                        - VkDevice, as void*; owns every cached
    //                                  object below.
    // commandBuffer                 - VkCommandBuffer, as void*; already
    //                                  recording, already inside the open
    //                                  render pass described by
    //                                  `renderPass`.
    // vertexModule, fragmentModule  - existing AOT passthrough
    //                                 VkShaderModule pair, as void*; never
    //                                 owned by this helper.
    // renderPass                    - VkRenderPass, as uint64_t, that the
    //                                 caller's currently open render pass
    //                                 was created from.
    // canvasWidth, canvasHeight     - full render target extent, used for
    //                                 the shared dynamic viewport; both
    //                                 must be > 0 when overlayCount > 0.
    // draws, overlayCount           - `draws` may be null only when
    //                                 overlayCount is 0.
    // outFailureReason              - non-null; cleared on success, set to
    //                                 an ASCII
    //                                 "vulkan_overlay_frame_renderer_*"
    //                                 token on the first invalid input or
    //                                 Vulkan object-creation failure.
    //
    // Returns true immediately with zero Vulkan calls when overlayCount ==
    // 0, regardless of the other arguments. Otherwise validates every
    // required handle, the canvas extent, and every draw's scissor rect /
    // opacity / UV rows before any Vulkan call, returning false (recording
    // nothing) on the first invalid input. The caller must fail the whole
    // frame on false -- no partial present.
    bool recordOverlayDraws(
        void* device,
        void* commandBuffer,
        void* vertexModule,
        void* fragmentModule,
        uint64_t renderPass,
        uint32_t canvasWidth,
        uint32_t canvasHeight,
        const VulkanOverlayFrameDraw* draws,
        uint32_t overlayCount,
        std::string* outFailureReason);

    // Destroys only the cached render-pass-bound pipeline so the next
    // recordOverlayDraws() call rebuilds it against a (possibly new)
    // renderPass / shader module pair. Safe to call once the caller has
    // ensured no in-flight command buffer still references the pipeline.
    // The descriptor set layout, pipeline layout, and descriptor pool are
    // left intact. Idempotent; no-op on non-Android host builds.
    void invalidate(void* device);

    // Destroys every cached Vulkan object (pipeline, pipeline layout,
    // descriptor set layout, descriptor pool). Idempotent; no-op on
    // non-Android host builds.
    void shutdown(void* device);

private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};

} // namespace render
} // namespace vanguard
