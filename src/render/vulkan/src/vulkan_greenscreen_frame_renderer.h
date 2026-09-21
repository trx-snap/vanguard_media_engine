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
//   * Identity / near-identity foreground rotation (the default; see
//     VulkanGreenScreenCameraDraw::foregroundRotationDegrees): fullscreen
//     triangle, no vertex input, byte-for-byte the pre-rotation draw.
//     Dynamic viewport = the camera rect (may start before / extend beyond
//     the canvas), dynamic scissor = the rect clipped to the canvas -- the
//     same viewport / scissor / UV crop contract AppendVulkanDuetLayoutLayer
//     records for the layout path's camera layer, so the caller resolves
//     both through ResolveVulkanDuetLayoutLayerPlacement (single source of
//     truth).
//   * ANDROID-DUET-VULKAN-GREENSCREEN-FREE-TRANSFORM: non-identity foreground
//     rotation switches to a 2-triangle (6-vertex) quad built from 4 NDC
//     corners this helper computes by rotating the camera rect's corners in
//     canvas-pixel space around (foregroundAnchorX, foregroundAnchorY)'s
//     pivot, converting each to NDC (Vulkan clip space is already Y-down /
//     top-left, matching the canvas convention -- no Y-flip, unlike GLES).
//     Dynamic viewport / scissor become the FULL canvas in this case (like
//     the GLES rotated path's glViewport(0,0,w,h) + scissor disabled): the
//     rotated quad's own geometry -- not the viewport/scissor rect -- bounds
//     what is rasterized, since a rotated rect is not axis-aligned.
//   * Pipeline layout:
//       set 0: the camera import's OWN descriptor set layout (binding 0,
//              COMBINED_IMAGE_SAMPLER, the import's immutable external-format
//              YCbCr sampler baked in), borrowed by handle for the draw and
//              never created or destroyed here;
//       set 1: this helper's mask set layout (binding 0,
//              COMBINED_IMAGE_SAMPLER, fragment stage, mutable sampler);
//       one VERTEX|FRAGMENT push-constant range of 160 bytes: the original
//       128-byte block (112-byte VideoTransformFullPushConstants, matching
//       the shared import pipeline layouts, plus the fragment-only vec4
//       maskDebug: debugMode, 1/maskWidth, 1/maskHeight, useRotatedQuad) is
//       byte-for-byte unchanged, with a trailing 32 vertex-only bytes
//       (rotatedQuad0/rotatedQuad1, the 4 rotated NDC corners) appended after
//       it, always pushed but meaningful only on the rotated-quad path.
//   * Straight-alpha blend over the destination: colour SRC_ALPHA /
//     ONE_MINUS_SRC_ALPHA, alpha ONE / ONE_MINUS_SRC_ALPHA, RGBA write mask.
//   * The mask is bound with this helper's own LINEAR / CLAMP_TO_EDGE sampler
//     (a GPU-mask AHardwareBuffer import carries a NEAREST sampler, and the
//     mask is typically 320x240 upscaled into the camera rect). The mask
//     image must therefore be a non-external-format sampled image (R8 CPU
//     upload or RGBA8 GPU import); its .r channel is the matte.
//   * VideoTransformFullPushConstants pushed verbatim from the caller
//     (aspect-fill crop + colour matrix resolved by the placement helper) --
//     that transformed camera UV feeds only the camera texel and the
//     mask_mapped diagnostic (debugMode 2); normal-mode matte sampling
//     instead uses the untransformed raw camera-rect UV with Y flipped
//     (maskUv = vec2(inRawUv.x, 1.0 - inRawUv.y)), matching the GLES parity
//     policy proven on-device (see the shader for the mask-orientation
//     caveat). This aspect-fill/colour-matrix transform is the camera's
//     SENSOR/CONTENT rotation and is completely independent of
//     the foreground free-transform rotation above; both may be non-zero at
//     once (e.g. a 90-degree front-camera sensor correction while the user
//     free-rotates the foreground layer 37 degrees).
//   * vkCmdDraw(3, 1, 0, 0) on the identity path; vkCmdDraw(6, 1, 0, 0) on
//     the rotated-quad path.
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

    // ANDROID-DUET-VULKAN-GREENSCREEN-FREE-TRANSFORM: Duet-only user
    // foreground free-rotation for the green-screen camera layer preview --
    // entirely independent from any camera sensor/content rotation baked
    // into [pushConstants]'s UV transform (see DuetLayoutLayer::rotationDegrees
    // in vulkan_frame_renderer.h). [foregroundRotationDegrees] is visual
    // clockwise in canvas-pixel space (Dart/top-left convention), any finite
    // value including negative or beyond +-360; identity (default 0.0, or
    // any value whose magnitude is below recordCameraDraw's small epsilon)
    // keeps the pre-existing axis-aligned fullscreen-triangle draw exactly,
    // byte-for-byte. [foregroundAnchorX]/[foregroundAnchorY] are the
    // normalized [0,1] pivot within the camera rect (viewportX/Y/Width/Height
    // above, BEFORE any aspect-fill inflation -- Vulkan's aspect-fill crop is
    // UV-only, so the rect above already is the true un-inflated camera
    // rect) the rotation is applied around; default (0.5, 0.5) is the rect
    // centre. Out-of-range or non-finite anchor values are clamped/defaulted
    // defensively inside recordCameraDraw, never fail closed.
    float foregroundRotationDegrees = 0.0f;
    float foregroundAnchorX = 0.5f;
    float foregroundAnchorY = 0.5f;
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
