// vulkan_duet_layout_frame_renderer.cpp
// ANDROID-DUET-VULKAN-LAYOUT: layout-mode (PiP / split) helpers for
// VulkanFrameRenderer's two-layer opaque Duet frame. See the header for
// ownership.
//
// Placement math compiles on every platform (pure math); draw-list
// construction is Android-only.

#include "vulkan_duet_layout_frame_renderer.h"

#include <algorithm>
#include <cmath>
#include <cstdint>

namespace vanguard {
namespace render {

// ---------------------------------------------------------------------------
// Placement math
// ---------------------------------------------------------------------------

namespace {

VulkanTransitionPixelRect intersectRects(const VulkanTransitionPixelRect& a,
                                         const VulkanTransitionPixelRect& b) {
    VulkanTransitionPixelRect r;
    r.x = std::max(a.x, b.x);
    r.y = std::max(a.y, b.y);
    r.right = std::min(a.right, b.right);
    r.bottom = std::min(a.bottom, b.bottom);
    return r;
}

// Aspect-fill ("cover") crop of a bufferWidth x bufferHeight source into a
// rectWidth x rectHeight destination: the axis on which the source is
// proportionally larger is cropped symmetrically so the whole rect is
// covered without distortion. Mirrors the GLES compositor's
// aspectFillViewport (which inflates the viewport and scissors the overflow
// back to the rect) in UV space instead, so the viewport can stay exactly the
// rect and never approach the implementation's viewport limits.
void applyAspectFillCrop(int32_t rectWidth,
                         int32_t rectHeight,
                         uint32_t bufferWidth,
                         uint32_t bufferHeight,
                         VideoFrameTransform* transform) {
    if (bufferWidth == 0 || bufferHeight == 0 || rectWidth <= 0 || rectHeight <= 0) {
        return; // unknown size: stretch (identity crop)
    }
    const double rectAspect =
        static_cast<double>(rectWidth) / static_cast<double>(rectHeight);
    const double bufferAspect =
        static_cast<double>(bufferWidth) / static_cast<double>(bufferHeight);
    if (!std::isfinite(rectAspect) || !std::isfinite(bufferAspect) ||
        rectAspect <= 0.0 || bufferAspect <= 0.0) {
        return;
    }
    if (bufferAspect > rectAspect) {
        // Source is proportionally wider than the rect: keep full height,
        // crop the sides.
        const double scale = rectAspect / bufferAspect;
        transform->cropScaleU = static_cast<float>(scale);
        transform->cropBiasU = static_cast<float>((1.0 - scale) * 0.5);
    } else if (bufferAspect < rectAspect) {
        // Source is proportionally taller than the rect: keep full width,
        // crop the top and bottom.
        const double scale = bufferAspect / rectAspect;
        transform->cropScaleV = static_cast<float>(scale);
        transform->cropBiasV = static_cast<float>((1.0 - scale) * 0.5);
    }
}

} // anonymous namespace

bool ResolveVulkanDuetLayoutLayerPlacement(const VulkanDuetLayoutLayerGeometry& layer,
                                            uint32_t extentWidth,
                                            uint32_t extentHeight,
                                            VulkanDuetLayoutLayerPlacement* out) {
    if (out == nullptr) return false;
    *out = VulkanDuetLayoutLayerPlacement{};
    if (extentWidth == 0 || extentHeight == 0 ||
        extentWidth > static_cast<uint32_t>(INT32_MAX) ||
        extentHeight > static_cast<uint32_t>(INT32_MAX)) {
        return false;
    }
    const RenderDestinationRect& r = layer.rect;
    if (r.width <= 0 || r.height <= 0) {
        return false;
    }
    const int64_t right = static_cast<int64_t>(r.x) + static_cast<int64_t>(r.width);
    const int64_t bottom = static_cast<int64_t>(r.y) + static_cast<int64_t>(r.height);
    if (right > static_cast<int64_t>(INT32_MAX) || bottom > static_cast<int64_t>(INT32_MAX)) {
        return false;
    }

    VulkanTransitionPixelRect viewport;
    viewport.x = r.x;
    viewport.y = r.y;
    viewport.right = static_cast<int32_t>(right);
    viewport.bottom = static_cast<int32_t>(bottom);

    VulkanTransitionPixelRect canvas;
    canvas.x = 0;
    canvas.y = 0;
    canvas.right = static_cast<int32_t>(extentWidth);
    canvas.bottom = static_cast<int32_t>(extentHeight);

    const VulkanTransitionPixelRect scissor = intersectRects(viewport, canvas);
    if (scissor.empty()) {
        return false; // fully off-canvas: fail closed
    }

    VideoFrameTransform transform{};
    applyAspectFillCrop(r.width, r.height, layer.bufferWidth, layer.bufferHeight, &transform);

    out->viewport = viewport;
    out->scissor = scissor;
    out->pushConstants = makeVideoTransformFullPushConstants(transform);
    return true;
}

#if defined(__ANDROID__)

// ---------------------------------------------------------------------------
// Draw-list construction (Android only)
// ---------------------------------------------------------------------------

bool AppendVulkanDuetLayoutLayer(VulkanTransitionPassParams* params,
                                 const VulkanTransitionLayerResources& res,
                                 const VulkanDuetLayoutLayerPlacement& placement) {
    if (params == nullptr) return false;
    if (params->drawCount >= kVulkanTransitionMaxLayerDraws) return false;
    // A resolved placement is never empty; an empty one means the caller
    // skipped ResolveVulkanDuetLayoutLayerPlacement, so fail closed rather
    // than silently dropping a layer from the frame.
    if (placement.viewport.empty() || placement.scissor.empty()) return false;
    VulkanTransitionLayerDraw& d = params->draws[params->drawCount++];
    d.pipeline = res.pipeline;
    d.pipelineLayout = res.pipelineLayout;
    d.descriptorSet = res.descriptorSet;
    d.pushConstants = placement.pushConstants;
    d.viewportX = placement.viewport.x;
    d.viewportY = placement.viewport.y;
    d.viewportWidth = placement.viewport.width();
    d.viewportHeight = placement.viewport.height();
    d.scissorX = placement.scissor.x;
    d.scissorY = placement.scissor.y;
    d.scissorWidth = placement.scissor.width();
    d.scissorHeight = placement.scissor.height();
    d.useBlendConstants = false;
    d.blendConstant = 0.0f;
    return true;
}

#endif // __ANDROID__

} // namespace render
} // namespace vanguard
