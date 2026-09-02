// vulkan_timeline_transition_compositor.h
// P5-COMPOSITOR-TRANS (sub-slice VULKAN-RENDER): Private helper -
// VulkanTimelineTransitionCompositor.
//
// Rasterizes two already-created, already-sampleable Vulkan images ("from"
// clip layer and "to" clip layer) into a caller-owned offscreen color
// attachment according to a resolved timeline transition geometry: the blend
// weights, per-layer normalized viewports and per-layer normalized crops
// produced by the compositor-owned pure math in
// vanguard::compositors::ComputeTransitionGeometry() /
// EvaluateTimelineComposition() (see
// compositors/include/vanguard/compositors/vg_timeline_compositor_node.h),
// then copies the attachment into a caller-owned host-visible readback buffer.
//
// This helper is the Vulkan raster stage for compositor-owned clip overlap
// transitions. It is NOT a graph node, owns no timeline state, and does not
// touch production VulkanBackend / VulkanDescriptorResources /
// VulkanGraphicsCommandRecorder state. The composition root (a diagnostic JNI
// in this slice; VGTimelineCompositorNode integration later) evaluates the
// transition math and hands the resolved geometry across the
// VulkanTimelineTransitionGeometry descriptor below, which mirrors
// vanguard::compositors::TimelineTransitionProgress field-for-field (minus the
// family enum) so vanguard_render_vulkan keeps its existing dependency
// direction: it never includes a compositors/graph header.
//
// Shader strategy (no new GLSL/SPIR-V): every draw uses the existing AOT
// passthrough vertex/fragment SPIR-V (fullscreen triangle, one combined image
// sampler at binding 0, VideoTransformFullPushConstants). Per-layer crop UVs
// are encoded in the push-constant UV transform rows (u = u0 + x*(u1-u0),
// v = v0 + y*(v1-v0)) with an identity color matrix; per-layer canvas
// placement is encoded purely through dynamic viewport + scissor. Crossfade is
// two draws: "from" opaque, then "to" through a second pipeline with
// fixed-function constant-alpha blending (src = CONSTANT_ALPHA,
// dst = ONE_MINUS_CONSTANT_ALPHA) and dynamic blend constants set to
// blendWeightTo. Slide / wipe families are opaque paint-over layering.
//
// Draw model (derived purely from the descriptor, never from a family enum):
//   * blendWeightTo <= 0            -> "from" layer only, opaque, at its
//                                      geometry (kNone / hard cut, crossfade
//                                      progress 0).
//   * blendWeightFrom <= 0          -> "to" layer only, opaque, at its
//                                      geometry (crossfade progress 1).
//   * both weights >= 1             -> layered opaque paint-over: "from" at
//                                      its geometry, then "to" at its
//                                      geometry (slide / wipe families).
//   * otherwise                     -> full-canvas "from" opaque draw, then
//                                      full-canvas "to" constant-alpha blend
//                                      draw with alpha = blendWeightTo
//                                      (crossfade); both viewports must be
//                                      identity.
// Each opaque layer draw places crop-rect(layer) x viewport-rect(layer) onto
// the canvas, clips the result to the canvas, advances the sampled UV range
// by the clipped fraction, and issues a fullscreen-triangle draw scoped by
// viewport/scissor to the resulting top-left pixel rectangle. A layer whose
// visible region rounds to zero pixels is skipped (not an error).
//
// Coordinate conventions: viewport/crop rects are top-left-origin, Y-down
// normalized canvas rects (the compositor convention). Vulkan framebuffer
// coordinates are also top-left-origin Y-down and texel row 0 is the first
// row in memory, so no V flip is applied: crop.y == 0 selects the first
// (top) texel row of the sampled image and readback row 0 is the top canvas
// row. Sampled images must already be in
// VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL; no layout transition of the
// sampled images is recorded.
//
// Ownership / lifecycle: owns only the temporary Vulkan objects it creates
// per renderTransition() call (shader modules, descriptor set layout / pool /
// sets, pipeline layout, render pass, framebuffer, pipelines, one command
// buffer from the caller's pool, one fence) and destroys / frees all of them
// on every success and failure path before returning. It never creates or
// destroys the device, queue, command pool, sampled images / views /
// samplers, color attachment image / view, or readback buffer / memory. The
// call is synchronous: it submits once and waits on its own fence, so on
// return the readback buffer holds the rendered RGBA8 pixels (tightly packed,
// row pitch = extentWidth * 4). The caller maps / invalidates the readback
// memory itself.
//
// Private source: this header is confined to the private Vulkan render
// backend implementation. On Android it includes <vulkan/vulkan.h>; on
// non-Android host builds the Vulkan handle fields become void*/uint32_t
// mirrors and renderTransition() compiles to a safe unavailable stub, matching
// the other private Vulkan helpers. The pure placement math compiles on every
// platform.

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

// Top-left-origin, Y-down normalized canvas rectangle. Viewport rects may lie
// outside [0,1] on x/y (off-canvas slide motion); crop rects must lie inside
// [0,1]. Mirrors vanguard::compositors::TimelineNormalizedRect without
// including that header.
struct VulkanTimelineNormalizedRect {
    double x      = 0.0;
    double y      = 0.0;
    double width  = 1.0;
    double height = 1.0;
};

// Resolved transition geometry at one timeline instant. Mirrors
// vanguard::compositors::TimelineTransitionProgress minus the family enum.
// Defaults describe an inactive transition (from-only, identity geometry).
struct VulkanTimelineTransitionGeometry {
    double progress        = 0.0;
    double blendWeightFrom = 1.0;
    double blendWeightTo   = 0.0;
    VulkanTimelineNormalizedRect fromViewport;
    VulkanTimelineNormalizedRect toViewport;
    VulkanTimelineNormalizedRect fromCrop;
    VulkanTimelineNormalizedRect toCrop;
};

// Top-left-origin pixel placement plus (unflipped) UV range resolved for one
// layer. `visible == false` means the layer has no on-canvas pixels.
struct VulkanTimelineLayerPlacement {
    bool     visible  = false;
    int32_t  xPx      = 0;
    int32_t  yTopPx   = 0;
    uint32_t widthPx  = 0;
    uint32_t heightPx = 0;
    // Texture coordinates (v0 is the top edge, v1 the bottom edge).
    float    u0       = 0.0f;
    float    u1       = 1.0f;
    float    v0       = 0.0f;
    float    v1       = 1.0f;
};

// Pure, platform-independent placement math (no Vulkan calls): maps
// crop x viewport onto an extentWidth x extentHeight canvas, clips to the
// canvas, and advances the UV range by the clipped fraction. Callers must
// have validated finiteness; non-finite inputs yield visible == false.
VulkanTimelineLayerPlacement ResolveVulkanTimelineLayerPlacement(
    const VulkanTimelineNormalizedRect& viewport,
    const VulkanTimelineNormalizedRect& crop,
    uint32_t extentWidth,
    uint32_t extentHeight);

// One caller-owned sampled layer. The image behind `imageView` must already
// be in VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL with a color aspect 2D view.
struct VulkanTimelineTransitionLayerImage {
#if defined(__ANDROID__)
    VkImageView imageView = VK_NULL_HANDLE;
    VkSampler   sampler   = VK_NULL_HANDLE;
#else
    void* imageView = nullptr;
    void* sampler   = nullptr;
#endif
};

// Caller-owned device context plus offscreen render target and readback
// staging buffer. Nothing in this struct is created or destroyed by the
// helper.
struct VulkanTimelineTransitionRenderTarget {
#if defined(__ANDROID__)
    VkDevice      device      = VK_NULL_HANDLE;
    VkQueue       queue       = VK_NULL_HANDLE;
    VkCommandPool commandPool = VK_NULL_HANDLE;
    // Color attachment image: 2D, `colorFormat`, single mip / layer, usage
    // must include COLOR_ATTACHMENT_BIT | TRANSFER_SRC_BIT. Its prior
    // contents are discarded (render pass initialLayout UNDEFINED, loadOp
    // CLEAR) and it is left in VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL.
    VkImage       colorImage     = VK_NULL_HANDLE;
    VkImageView   colorImageView = VK_NULL_HANDLE;
    VkFormat      colorFormat    = VK_FORMAT_R8G8B8A8_UNORM;
    // Host-visible readback buffer with usage TRANSFER_DST_BIT and size of at
    // least extentWidth * extentHeight * 4 bytes (declared by the caller in
    // readbackBufferSizeBytes; validated, not queried).
    VkBuffer      readbackBuffer          = VK_NULL_HANDLE;
    VkDeviceSize  readbackBufferSizeBytes = 0;
    // Clear color applied to the whole attachment before any layer draw.
    VkClearColorValue clearColor = {{0.0f, 0.0f, 0.0f, 1.0f}};
#else
    void*    device      = nullptr;
    void*    queue       = nullptr;
    void*    commandPool = nullptr;
    void*    colorImage     = nullptr;
    void*    colorImageView = nullptr;
    uint32_t colorFormat    = 0;
    void*    readbackBuffer          = nullptr;
    uint64_t readbackBufferSizeBytes = 0;
    float    clearColor[4] = {0.0f, 0.0f, 0.0f, 1.0f};
#endif
    uint32_t extentWidth  = 0;
    uint32_t extentHeight = 0;
};

class VulkanTimelineTransitionCompositor {
public:
    VulkanTimelineTransitionCompositor();
    ~VulkanTimelineTransitionCompositor();

    VulkanTimelineTransitionCompositor(const VulkanTimelineTransitionCompositor&) = delete;
    VulkanTimelineTransitionCompositor& operator=(const VulkanTimelineTransitionCompositor&) = delete;

    // Renders the resolved transition into target.colorImage, copies it into
    // target.readbackBuffer, and waits for completion (see the draw model in
    // the file header).
    //
    // target     - device/queue/commandPool, color attachment, readback
    //              buffer. Every handle must be non-null, extents > 0, and
    //              readbackBufferSizeBytes >= extentWidth*extentHeight*4
    //              (else outError="vulkan_timeline_transition_compositor_invalid_argument").
    // from, to   - non-null imageView + sampler pairs; both must be non-null
    //              even when a weight makes one layer invisible (same
    //              "_invalid_argument" error).
    // geometry   - resolved transition geometry. progress must be finite
    //              ("..._invalid_progress"), both weights finite
    //              ("..._invalid_blend_weight"; finite values are clamped
    //              into [0,1]), every rect field finite with non-negative
    //              extents, and both crops inside [0,1]
    //              ("..._invalid_geometry"). A blend draw with a non-identity
    //              viewport fails with "..._unsupported_geometry". All
    //              validation runs before any Vulkan call.
    // outError   - non-null; set to "" on success or an ASCII failure reason
    //              ("..._shader_module_failed", "..._descriptor_failed",
    //              "..._render_pass_failed", "..._pipeline_failed",
    //              "..._command_buffer_failed", "..._submit_failed",
    //              "..._wait_failed").
    //
    // Returns true only if every Vulkan object creation, the submit, and the
    // fence wait succeeded. Returns false with
    // outError="vulkan_timeline_transition_compositor_unavailable_on_host"
    // and no Vulkan calls on non-Android builds.
    bool renderTransition(const VulkanTimelineTransitionRenderTarget& target,
                          const VulkanTimelineTransitionLayerImage& from,
                          const VulkanTimelineTransitionLayerImage& to,
                          const VulkanTimelineTransitionGeometry& geometry,
                          std::string* outError);

    // Lifecycle telemetry for diagnostics: cumulative count of temporary
    // Vulkan objects this instance created (successful vkCreate*/vkAllocate*)
    // and released (vkDestroy*/vkFree*). They are equal whenever no
    // renderTransition() call is in progress; a difference indicates a leak.
    uint64_t temporaryObjectsCreated() const { return temporaryObjectsCreated_; }
    uint64_t temporaryObjectsReleased() const { return temporaryObjectsReleased_; }

private:
    uint64_t temporaryObjectsCreated_  = 0;
    uint64_t temporaryObjectsReleased_ = 0;
};

} // namespace render
} // namespace vanguard
