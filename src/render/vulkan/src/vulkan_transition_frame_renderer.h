// vulkan_transition_frame_renderer.h
// P5-COMPOSITOR-TRANS: transition-only helpers for VulkanFrameRenderer's
// two-source clip overlap transition frame.
//
// This translation unit owns the parts of a transition frame that do not
// touch the per-frame swapchain / fence / semaphore lifecycle (which stays
// in vulkan_frame_renderer.cpp, next to the solo renderFrame protocol it
// mirrors):
//
//   * draw-model resolution from the descriptor's blend weights,
//   * pure placement math mapping a layer's aspect-fit destination rect
//     through the compositor-owned transition viewport / crop onto output
//     pixels,
//   * transition pass draw-list construction (black letterbox bands + clip
//     content draws) over VulkanTransitionPassParams,
//   * the constant-alpha blend pipeline variant used by crossfade frames.
//
// Placement / draw-mode helpers are platform independent (pure math). The
// draw-list and pipeline helpers are Android-only, like the Vulkan handles
// they operate on.

#pragma once

#include <cstdint>

#include "vanguard/render/render_transform.h"
#include "vulkan_graphics_command_recorder.h"

#if defined(__ANDROID__)
#ifndef VK_USE_PLATFORM_ANDROID_KHR
#define VK_USE_PLATFORM_ANDROID_KHR
#endif
#include <vulkan/vulkan.h>
#endif

namespace vanguard {
namespace render {

// ---------------------------------------------------------------------------
// Draw model (see render_transform.h VideoTransitionFrameTransform doc).
// ---------------------------------------------------------------------------

// kFromFade / kToFade: a single-sided PARTIAL weight (the other side <= 0,
// this side < 1) is a fade-through-black half-phase -- that one layer is
// constant-alpha blended over an explicit full-canvas black base with
// alpha == its weight (see AppendVulkanTransitionBlackCanvas). Hard cut
// (1,0), the crossfade endpoints (1,0)/(0,1), the crossfade interior and the
// opaque (1,1) paint-over pair resolve exactly as before.
enum class VulkanTransitionDrawMode { kFromOnly, kToOnly, kPaintOver, kCrossfade, kFromFade, kToFade };

// Resolves the draw model purely from the descriptor's weights. Returns
// false (fail closed, nothing rendered) when any weight / progress is
// non-finite, or when a crossfade or fade half-phase carries non-identity
// viewport / crop geometry. [outMode] is only written on success.
bool ResolveVulkanTransitionDrawMode(const VideoTransitionFrameTransform& transition,
                                     VulkanTransitionDrawMode* outMode);

// ---------------------------------------------------------------------------
// Placement math (pure, platform independent).
// ---------------------------------------------------------------------------

// Closed pixel rectangle [x, right) x [y, bottom) in output pixel space.
struct VulkanTransitionPixelRect {
    int32_t x = 0;
    int32_t y = 0;
    int32_t right = 0;
    int32_t bottom = 0;

    bool empty() const { return right <= x || bottom <= y; }
    uint32_t width() const { return empty() ? 0u : static_cast<uint32_t>(right - x); }
    uint32_t height() const { return empty() ? 0u : static_cast<uint32_t>(bottom - y); }
};

// Resolved on-canvas placement of one layer: [viewport] is the layer's
// aspect-fit destination rect carried through the transition viewport (may
// extend beyond / start before the canvas); [region] is the visible canvas
// area of the layer (viewport x crop, clipped to the canvas) that the layer's
// own black letterbox background also owns; [content] is the part of
// [viewport] inside [region]. [visible] is false when [region] is empty.
struct VulkanTransitionLayerPlacement {
    bool visible = false;
    VulkanTransitionPixelRect viewport;
    VulkanTransitionPixelRect region;
    VulkanTransitionPixelRect content;
};

// Maps [layer]'s destination rect (full extent when default) through the
// transition [viewport] / [crop] onto an extentWidth x extentHeight canvas.
// Returns false (fail closed) for non-finite rects, a crop outside [0,1], an
// invalid destination rect, or a zero extent; [out] is reset on entry.
bool ResolveVulkanTransitionLayerPlacement(const VideoFrameTransform& layer,
                                           const RenderNormalizedRect& viewport,
                                           const RenderNormalizedRect& crop,
                                           uint32_t extentWidth,
                                           uint32_t extentHeight,
                                           VulkanTransitionLayerPlacement* out);

#if defined(__ANDROID__)

// ---------------------------------------------------------------------------
// Draw-list construction and blend pipeline (Android only).
// ---------------------------------------------------------------------------

// Vulkan objects one layer draws with.
struct VulkanTransitionLayerResources {
    VkPipeline pipeline = VK_NULL_HANDLE;
    VkPipelineLayout pipelineLayout = VK_NULL_HANDLE;
    VkDescriptorSet descriptorSet = VK_NULL_HANDLE;
    VideoTransformFullPushConstants pushConstants{};
    bool useBlendConstants = false;
    float blendConstant = 0.0f;
};

// Appends one layer to [params]: optional black bands covering
// region-minus-content (the layer canvas's own letterbox background, needed
// only when the layer paints over an earlier layer), then the clip content
// draw itself. Invisible layers append nothing. Returns false only when the
// draw list would exceed kVulkanTransitionMaxLayerDraws.
bool AppendVulkanTransitionLayer(VulkanTransitionPassParams* params,
                                 const VulkanTransitionLayerResources& res,
                                 const VulkanTransitionLayerPlacement& placement,
                                 bool includeBands);

// Appends one full-canvas opaque black draw (black push constants, blend
// constants forced off) through [res]'s pipeline / layout / descriptor set:
// the explicit black base a fade half-phase layer is then blended over, so
// the dip to black never depends on the pass clear colour. [res.pipeline]
// must be an OPAQUE pipeline for that layout (never the constant-alpha blend
// variant). Returns false only when the draw list would exceed
// kVulkanTransitionMaxLayerDraws or the extent is zero.
bool AppendVulkanTransitionBlackCanvas(VulkanTransitionPassParams* params,
                                       const VulkanTransitionLayerResources& res,
                                       uint32_t extentWidth,
                                       uint32_t extentHeight);

// Constant-alpha blend variant of VulkanGraphicsPipeline::create (same
// fullscreen-triangle fixed state; src = CONSTANT_ALPHA,
// dst = ONE_MINUS_CONSTANT_ALPHA, dynamic blend constants). The caller owns
// the returned pipeline and destroys it with vkDestroyPipeline.
bool CreateVulkanTransitionBlendPipeline(VkDevice device,
                                         VkPipelineLayout pipelineLayout,
                                         VkRenderPass renderPass,
                                         VkShaderModule vertShader,
                                         VkShaderModule fragShader,
                                         VkPipeline* outPipeline);

#endif // __ANDROID__

} // namespace render
} // namespace vanguard
