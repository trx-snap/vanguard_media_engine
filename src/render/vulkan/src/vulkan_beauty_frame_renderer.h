// vulkan_beauty_frame_renderer.h
// P5-BEAUTY-V2-PRODUCTION-EXPORT-ROUTE-A: private helper -
// VulkanBeautyFrameRenderer.
//
// Production (non-diagnostic) Vulkan-only render chain for clip-level
// Beauty V2 on solo/hard-cut export frames, used exclusively by
// VulkanFrameRenderer::renderFrame's beauty-aware overload. One command
// buffer / one submit / one present per frame: this helper only RECORDS
// commands into a caller-supplied, already-recording VkCommandBuffer; it
// never begins/ends a command buffer, never creates its own queue submit or
// fence wait, and never touches the swapchain acquire/present protocol --
// all of that remains owned exclusively by VulkanFrameRenderer::renderFrame,
// exactly as for the existing non-beauty solo path.
//
// Required production chain for one beauty-enabled solo frame, recorded as
// five render passes inside the caller's single command buffer:
//   1. Crop pass:      existing AHB/YCbCr import (srcImage), sampled through
//                       the existing coreShaders vertex/fragment pair, drawn
//                       with an IDENTITY rotation + the caller's existing
//                       crop scale/bias into a session-owned plain RGBA8
//                       intermediate ("orig") sized to the cropped SOURCE
//                       extent (buffer-native orientation, pre-rotation) --
//                       never the display-rotated or output extent, so
//                       Beauty never samples letterboxed/pillarboxed pixels.
//   2. Blur H pass:    beauty_v2_blur.frag (axis=0), orig -> "blurH".
//   3. Blur V pass:    beauty_v2_blur.frag (axis=1), blurH -> "mean".
//   4. Composite pass: beauty_v2_composite.frag, orig + mean -> "beautified".
//   5. Placement pass: the SAME existing coreShaders vertex/fragment pair
//                       used by the non-beauty path, sampling "beautified"
//                       (UV identity: it already IS the cropped, unrotated
//                       content) with the caller's ACTUAL rotation,
//                       aspect-fit destination rect, and colorMatrix
//                       (composing colorMatrix strictly AFTER beauty, never
//                       before), drawn into the caller's swapchain
//                       framebuffer.
//
// No CPU readback, no helper-created queue submit/fence wait, no per-frame
// vkCreatePipeline/vkCreateImage/vkQueueWaitIdle/vkDeviceWaitIdle: the four
// intermediate RGBA8 images, their framebuffers, descriptor sets, the shared
// intermediate render pass, the blur/composite/placement descriptor set
// layouts + pipeline layouts + pipelines are all created lazily ONCE per
// distinct (cropWidth, cropHeight) geometry and reused on every subsequent
// frame for that geometry, until shutdown(). The one exception -- matching
// pre-existing cost, not new -- is the crop pass's own pipeline: its
// pipeline layout is owned by the AHardwareBuffer import (a fresh import per
// decoded frame), so it is recreated whenever that layout no longer matches
// the cached one, identically to VulkanFrameRenderer's own solo-frame
// pipeline cache for the non-beauty path. This recreation happens per
// frame-in-flight slot (see below) rather than through a single shared
// instance, so it needs no vkDeviceWaitIdle: destroying and rebuilding the
// pipeline cached for [frameSlotIndex] is safe purely because the caller
// already waited that slot's own frame fence before calling recordBeauty()
// for it. The placement pipeline (rebuilt only on the much rarer swapchain
// resize/reattach) uses the identical per-slot cache for the same reason.
//
// Frame-in-flight safety: because VulkanFrameRenderer double-buffers
// (kDefaultFramesInFlight == 2) and does not wait for a submitted frame's
// fence before returning, two frames' GPU work can legitimately overlap.
// Every per-geometry resource that is WRITTEN by a render pass (the four
// RGBA8 images, their framebuffers, and the descriptor sets that bind them),
// plus the crop and placement pipelines discussed above, is therefore
// duplicated per frame-in-flight slot ([frameSlotIndex] in [0, frameCount));
// only read-only, extent-independent Vulkan objects (sampler, shader
// modules, descriptor SET LAYOUTS, pipeline layouts, the blur/composite
// pipelines, the shared render pass) are shared across slots.
//
// Reuses ComputeVulkanBeautyV2ParametersFromIntensity (declared in
// vulkan_beauty_v2_compositor.h) and the existing Beauty V2 SPIR-V
// (beauty_v2_blur_frag_spv.h / beauty_v2_composite_frag_spv.h /
// passthrough_vert_spv.h) -- no ramp math is rederived here. The diagnostic
// VulkanBeautyV2Compositor (readback-based, per-call temp objects) is left
// completely untouched and is never called from this production path.
//
// Confined to the private Vulkan render backend implementation; never
// included from a public header. On non-Android host builds this compiles
// to a safe unavailable stub (matching the other private Vulkan helpers).

#pragma once

#include "vanguard/render/render_transform.h"

#include <cstdint>
#include <memory>
#include <string>

#if defined(__ANDROID__)
#ifndef VK_USE_PLATFORM_ANDROID_KHR
#define VK_USE_PLATFORM_ANDROID_KHR
#endif
#include <vulkan/vulkan.h>
#include "vulkan_hardware_buffer_image.h"
#else
namespace vanguard {
namespace render {
struct VulkanHardwareBufferImage;
} // namespace render
} // namespace vanguard
#endif

namespace vanguard {
namespace render {

// ---------------------------------------------------------------------------
// P5-BEAUTY-V2-TRANSITION-COMP: VulkanBeautyTransitionLayerResources
// ---------------------------------------------------------------------------
// Draw resources for one beautified transition layer, returned by
// [VulkanBeautyFrameRenderer::prepareTransitionLayer]. [pipeline] is the
// placement pipeline for the caller's swapchain render pass (already built
// via ensurePlacementPipeline for the given frame slot); [pipelineLayout] /
// [descriptorSet] bind the beautified RGBA intermediate exactly like the
// solo path's own placement pass. [placementTransform] is the caller's
// original per-layer transform with cropScaleU/V forced to 1.0 and
// cropBiasU/V forced to 0.0 (the beautified intermediate is already the
// cropped, unrotated content) -- rotation, destination rect, and colorMatrix
// are carried through unchanged. Feed it to makeVideoTransformFullPushConstants
// to build the draw's push constants, matching the solo placement pass's
// policy exactly.
struct VulkanBeautyTransitionLayerResources {
#if defined(__ANDROID__)
    VkPipeline pipeline = VK_NULL_HANDLE;
    VkPipelineLayout pipelineLayout = VK_NULL_HANDLE;
    VkDescriptorSet descriptorSet = VK_NULL_HANDLE;
#else
    void* pipeline = nullptr;
    void* pipelineLayout = nullptr;
    void* descriptorSet = nullptr;
#endif
    VideoFrameTransform placementTransform;
};

class VulkanBeautyFrameRenderer {
public:
    VulkanBeautyFrameRenderer();
    ~VulkanBeautyFrameRenderer();

    VulkanBeautyFrameRenderer(const VulkanBeautyFrameRenderer&) = delete;
    VulkanBeautyFrameRenderer& operator=(const VulkanBeautyFrameRenderer&) = delete;

    // Records the full crop -> blur H -> blur V -> composite -> placement
    // sequence (see file header) into `commandBuffer`, which must already be
    // in the recording state (this method neither begins nor ends the
    // command buffer). `frameSlotIndex` must be in [0, frameCount).
    //
    // `srcImage` is the caller's existing AHardwareBuffer import (already
    // validated non-null image/descriptorResources by the caller);
    // `srcCurrentLayout` is its current VkImageLayout (VK_IMAGE_LAYOUT_UNDEFINED
    // triggers the same one-time layout transition the non-beauty path
    // performs). `vertexModule`/`fragmentModule` are the existing
    // VulkanCoreShaderModules pair (never owned by this helper).
    // `finalRenderPass`/`finalFramebuffer`/`finalExtentWidth`/
    // `finalExtentHeight` describe the caller's swapchain target for the
    // placement pass; `placementTransform` carries the clip's actual
    // rotation/crop/destination-rect/colorMatrix (identical to the
    // non-beauty renderFrame's `transform` argument).
    //
    // Returns true on success. Returns false (recording nothing further; any
    // commands already recorded into `commandBuffer` for THIS call are
    // safe no-ops on a discarded submit) with `*outFailureReason` set to a
    // "beauty_v2_*" token on any validation or Vulkan object-creation
    // failure. The caller must fail the whole frame on false -- no partial
    // present.
#if defined(__ANDROID__)
    bool recordBeauty(
        VkDevice device,
        VkPhysicalDevice physicalDevice,
        VkCommandBuffer commandBuffer,
        uint32_t frameSlotIndex,
        uint32_t frameCount,
        const VulkanHardwareBufferImage& srcImage,
        VkImageLayout srcCurrentLayout,
        VkShaderModule vertexModule,
        VkShaderModule fragmentModule,
        const VideoFrameTransform& placementTransform,
        const VideoBeautyV2RenderParams& beauty,
        VkRenderPass finalRenderPass,
        VkFramebuffer finalFramebuffer,
        uint32_t finalExtentWidth,
        uint32_t finalExtentHeight,
        std::string* outFailureReason);
#else
    bool recordBeauty(
        void* device,
        void* physicalDevice,
        void* commandBuffer,
        uint32_t frameSlotIndex,
        uint32_t frameCount,
        const VulkanHardwareBufferImage& srcImage,
        uint32_t srcCurrentLayout,
        void* vertexModule,
        void* fragmentModule,
        const VideoFrameTransform& placementTransform,
        const VideoBeautyV2RenderParams& beauty,
        void* finalRenderPass,
        void* finalFramebuffer,
        uint32_t finalExtentWidth,
        uint32_t finalExtentHeight,
        std::string* outFailureReason);
#endif

    // P5-BEAUTY-V2-TRANSITION-COMP: reusable seam for the transition-frame
    // draw path. Records ONLY passes 1-4 (crop -> blurH -> blurV -> composite,
    // see the file header) into `commandBuffer` -- which must already be in
    // the recording state -- producing the beautified RGBA intermediate for
    // ONE transition layer. Unlike [recordBeauty] this method never begins or
    // ends the command buffer, never submits, never waits, never presents,
    // never releases an AHardwareBuffer, and never records the placement
    // pass itself: the caller (VulkanFrameRenderer's transition path) draws
    // the returned resources into its own transition render pass alongside
    // any non-beautified layer.
    //
    // Calls ensurePlacementPipeline(device, frameSlotIndex, frameCount,
    // swapchainRenderPass) so the pipeline handed back in `*outResources` is
    // guaranteed compatible with `swapchainRenderPass` -- the same render
    // pass the caller's transition draw targets. `layerTransform` is this
    // layer's own per-frame transform (rotation / decoder crop / destination
    // rect / colorMatrix), identical in shape to the solo path's `transform`
    // argument to [recordBeauty].
    //
    // Returns true on success with `*outResources` populated. Returns false
    // (recording nothing further; any commands already recorded into
    // `commandBuffer` for THIS call are safe no-ops on a discarded submit)
    // with `*outFailureReason` set to a "beauty_v2_*" token on any validation
    // or Vulkan object-creation failure. The caller must fail the whole frame
    // on false -- no partial present.
#if defined(__ANDROID__)
    bool prepareTransitionLayer(
        VkDevice device,
        VkPhysicalDevice physicalDevice,
        VkCommandBuffer commandBuffer,
        uint32_t frameSlotIndex,
        uint32_t frameCount,
        const VulkanHardwareBufferImage& srcImage,
        VkImageLayout srcCurrentLayout,
        VkShaderModule vertexModule,
        VkShaderModule fragmentModule,
        const VideoFrameTransform& layerTransform,
        const VideoBeautyV2RenderParams& beauty,
        VkRenderPass swapchainRenderPass,
        VulkanBeautyTransitionLayerResources* outResources,
        std::string* outFailureReason);
#else
    bool prepareTransitionLayer(
        void* device,
        void* physicalDevice,
        void* commandBuffer,
        uint32_t frameSlotIndex,
        uint32_t frameCount,
        const VulkanHardwareBufferImage& srcImage,
        uint32_t srcCurrentLayout,
        void* vertexModule,
        void* fragmentModule,
        const VideoFrameTransform& layerTransform,
        const VideoBeautyV2RenderParams& beauty,
        void* swapchainRenderPass,
        VulkanBeautyTransitionLayerResources* outResources,
        std::string* outFailureReason);
#endif

    // Destroys every cached Vulkan object (all geometries, all frame slots).
    // Idempotent / double-destroy safe.
#if defined(__ANDROID__)
    void shutdown(VkDevice device);
#else
    void shutdown(void* device);
#endif

    // Lifecycle telemetry: cumulative counts of temporary/cached Vulkan
    // objects this instance has created and released. Released only grows
    // on shutdown() (resources are cached, not per-call), so the two values
    // are equal only after shutdown() completes.
    uint64_t resourcesCreated() const;
    uint64_t resourcesReleased() const;

private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};

} // namespace render
} // namespace vanguard
