// vulkan_duet_layout_frame_renderer.h
// ANDROID-DUET-VULKAN-LAYOUT: layout-mode (PiP / split) helpers for
// VulkanFrameRenderer's two-layer opaque Duet frame.
//
// This translation unit owns the parts of a Duet layout frame that do not
// touch the per-frame swapchain / fence / semaphore lifecycle (which stays in
// vulkan_frame_renderer.cpp, next to the renderDuetGreenScreenFrame protocol
// it mirrors):
//
//   * pure placement math mapping one layer's canvas pixel rect onto a
//     viewport (the rect itself, which may extend beyond the canvas), a
//     scissor (the rect clipped to the canvas) and an aspect-fill UV crop
//     derived from the imported buffer's content dimensions,
//   * draw-list construction over VulkanTransitionPassParams, so the frame is
//     recorded by the existing VulkanGraphicsCommandRecorder::
//     recordTransitionPass (optional source layout transitions, one clear
//     render pass, every layer draw in order) with no new shader / pipeline
//     setup: each layer draws through its import's own descriptor resources
//     and the core passthrough shaders, exactly like a solo/transition frame.
//
// Placement helpers are platform independent (pure math). The draw-list
// helper is Android-only, like the Vulkan handles it operates on.

#pragma once

#include <cstdint>

#include "vanguard/render/render_transform.h"
#include "vulkan_graphics_command_recorder.h"
#include "vulkan_transition_frame_renderer.h"

namespace vanguard {
namespace render {

// Caller-supplied geometry of one opaque Duet layout layer: the canvas pixel
// rect it fills (top-left origin, Y-down; width/height must be > 0) and the
// imported buffer's content dimensions used for the aspect-fill crop. A zero
// bufferWidth or bufferHeight means "unknown": the layer is stretched to the
// rect, matching the GLES compositor's unknown-size behaviour.
struct VulkanDuetLayoutLayerGeometry {
    RenderDestinationRect rect;
    uint32_t bufferWidth = 0;
    uint32_t bufferHeight = 0;
};

// Resolved on-canvas draw of one layer.
struct VulkanDuetLayoutLayerPlacement {
    // The full rect, never empty on success; may start before / extend beyond
    // the canvas so partially off-canvas content is clipped, not squeezed.
    VulkanTransitionPixelRect viewport;
    // viewport clipped to the canvas; never empty on success.
    VulkanTransitionPixelRect scissor;
    // Aspect-fill crop UV mapping (identity colour matrix).
    VideoTransformFullPushConstants pushConstants{};
};

// Resolves one layer. Fails closed (returns false, *out reset) for a zero
// extent, a non-positive rect size, or a rect that does not intersect the
// canvas at all.
bool ResolveVulkanDuetLayoutLayerPlacement(const VulkanDuetLayoutLayerGeometry& layer,
                                            uint32_t extentWidth,
                                            uint32_t extentHeight,
                                            VulkanDuetLayoutLayerPlacement* out);

#if defined(__ANDROID__)

// Appends one opaque layer draw to [params] using [res]'s pipeline / pipeline
// layout / descriptor set and [placement]'s viewport, scissor and push
// constants (res.pushConstants / blend fields are ignored: Duet layout layers
// are always opaque and their UV mapping is owned by the placement). No
// letterbox bands are appended: a layer aspect-fills its rect, so there is
// never an unfilled region inside it. Returns false when the draw list is
// full or the placement is empty (an unresolved placement), recording
// nothing in that case.
bool AppendVulkanDuetLayoutLayer(VulkanTransitionPassParams* params,
                                 const VulkanTransitionLayerResources& res,
                                 const VulkanDuetLayoutLayerPlacement& placement);

#endif // __ANDROID__

} // namespace render
} // namespace vanguard
