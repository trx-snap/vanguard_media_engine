// vulkan_overlay_compositor.h
// P5-OVERLAYS-TRANS (sub-slice VULKAN-RENDER): Private helper -
// VulkanOverlayCompositor.
//
// Rasterizes an ordered list of already-created, already-sampleable Vulkan
// images (text / emoji / sticker overlay rasters owned by the caller) on top
// of a caller-owned offscreen color attachment, one straight-alpha
// Porter-Duff source-over draw per layer, then copies the attachment into a
// caller-owned host-visible readback buffer. Each layer is placed by an
// evaluated spatial transform (top-left canvas pixel position, size, uniform
// scale, rotation about the layer centre, opacity) that mirrors the raster
// fields of the pure-Dart VGOverlayEvaluatedTransform produced by the
// verified P5-OVERLAYS-KEYFRAME-INTERP sub-slice
// (lib/src/overlay/vg_overlay_keyframe.dart), exactly like the verified GLES
// twin GlesOverlayCompositor (render/gles/src/gles_overlay_compositor.h).
//
// This helper is the Vulkan raster stage for compositor-owned overlay layers.
// It is NOT a graph node, owns no timeline / keyframe / export state, and does
// not touch production VulkanBackend / VulkanDescriptorResources /
// VulkanGraphicsCommandRecorder state. The composition root (a diagnostic JNI
// in this slice; VGTimelineCompositorNode / export integration later)
// evaluates the keyframe math elsewhere and hands already-resolved transforms
// across the VulkanOverlayLayerDescriptor below, so vanguard_render_vulkan
// keeps its existing dependency direction: it never includes a compositors,
// graph, or Dart-facing header, exactly like VulkanTimelineTransitionCompositor.
//
// Shader strategy (no new GLSL/SPIR-V): every draw uses the existing AOT
// passthrough vertex/fragment SPIR-V (fullscreen triangle, one combined image
// sampler at binding 0, VideoTransformFullPushConstants). The vertex shader
// maps the fullscreen triangle to base coordinates (x, y) in [0,1]^2 over the
// viewport (top-left origin, Y down) and evaluates
//   u = dot(uvTransform0, (x, y, 0, 1)),  v = dot(uvTransform1, (x, y, 0, 1)).
// The helper therefore encodes the INVERSE of each layer's placement in the
// two UV rows: for every canvas pixel it recovers the overlay-local texture
// coordinate (u, v) by translating to the layer centre, rotating by -rotation,
// and dividing by the scaled extents. Any translation / uniform scale /
// arbitrary rotation-about-centre combination is one affine 2x3 mapping. The
// viewport is always the full canvas; the scissor is the rotated layer's
// bounding box clipped to the canvas (conservative, never a correctness
// input). Per-layer opacity rides in colour-matrix row 3 = (0, 0, 0, opacity)
// with identity rows 0..2, so the fragment shader multiplies only the sampled
// alpha and leaves RGB straight (non-premultiplied).
//
// Blending (fixed function, one pipeline):
//   srcColor = VK_BLEND_FACTOR_SRC_ALPHA, dstColor = VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA,
//   colorOp  = VK_BLEND_OP_ADD,
//   srcAlpha = VK_BLEND_FACTOR_ONE,       dstAlpha = VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA,
//   alphaOp  = VK_BLEND_OP_ADD
// which is standard source-over for straight-alpha sources (destination alpha
// accumulates as srcA + dstA * (1 - srcA)).
//
// Outside-the-overlay pixels: the fixed passthrough fragment shader cannot
// discard, so pixels of the scissor box that fall outside the rotated overlay
// quad sample texture coordinates outside [0,1]. The CALLER's sampler must
// therefore use VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_BORDER with
// VK_BORDER_COLOR_FLOAT_TRANSPARENT_BLACK (or the layer image must carry its
// own transparent margin) so those pixels blend as transparent black and
// leave the destination untouched. The helper cannot query sampler state and
// does not validate this; the diagnostic composition root proves it with
// clamp-to-border transparent-black samplers.
//
// Draw model:
//   * Layers are drawn in the caller-provided order, first to last, i.e.
//     back-to-front. The caller (Dart VGOverlayTransformEvaluator today) is
//     responsible for sorting by zIndex; `zIndex` is carried for parity and
//     telemetry only and is never used to reorder here.
//   * The attachment is either cleared to `clearColor` (loadExistingContents
//     == false: render pass initialLayout UNDEFINED, loadOp CLEAR) or loaded
//     as-is (loadExistingContents == true: initialLayout = colorInitialLayout,
//     loadOp LOAD) so overlays composite over an existing base layer; in both
//     cases the attachment is left in VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL.
//   * A layer whose clipped bounding box rounds to zero pixels is skipped
//     (not an error). An empty layer list is a validated no-op: no Vulkan
//     call is issued, the attachment and readback buffer are untouched.
//
// Coordinate conventions: x/y are the overlay's top-left corner in canvas
// pixels with a top-left origin and Y down (the Dart convention); rotation is
// radians, clockwise-positive on screen. Vulkan framebuffer coordinates are
// also top-left-origin Y-down and texel row 0 is the first row in memory, so
// no V flip is applied: texture row 0 is the overlay's visual top edge.
// Sampled images must already be in VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
// no layout transition of the sampled images is recorded.
//
// Ownership / lifecycle: owns only the temporary Vulkan objects it creates
// per renderOverlays() call (two shader modules, descriptor set layout, one
// descriptor pool holding one set per layer, pipeline layout, render pass,
// framebuffer, one pipeline, one command buffer from the caller's pool, one
// fence) and destroys / frees all of them on every success and failure path
// before returning; temporaryObjectsCreated() == temporaryObjectsReleased()
// whenever no call is in progress. It never creates or destroys the device,
// queue, command pool, sampled images / views / samplers, color attachment
// image / view, or readback buffer / memory. The call is synchronous: it
// submits once and waits on its own fence, so on return the readback buffer
// holds the rendered RGBA8 pixels (tightly packed, row pitch = extentWidth *
// 4). The caller maps / invalidates the readback memory itself.
//
// Private source: this header is confined to the private Vulkan render
// backend implementation. On Android it includes <vulkan/vulkan.h>; on
// non-Android host builds the Vulkan handle fields become void*/uint32_t
// mirrors and renderOverlays() compiles to a safe unavailable stub, matching
// the other private Vulkan helpers. The pure validation / transform math
// compiles on every platform.

#pragma once

#include <cstddef>
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

// One resolved overlay layer at one timeline instant. Raster-field mirror of
// the Dart VGOverlayEvaluatedTransform: identity / type / timing / text /
// asset fields are intentionally absent because the raster stage never needs
// them. Field order and meaning:
//   imageView, sampler - caller-owned combined image sampler pair holding the
//                        overlay raster (2D colour view, SHADER_READ_ONLY_OPTIMAL,
//                        sampler clamp-to-border transparent black); not
//                        owned by the helper; both must be non-null.
//   x, y               - top-left corner in canvas pixels (Dart translationX/Y).
//   width, height      - unscaled size in canvas pixels; both must be > 0.
//   rotation           - radians, clockwise-positive, about the layer centre.
//   scale              - uniform scale factor about the layer centre; must be > 0.
//   opacity            - [0, 1]; multiplied into the sampled alpha.
//   zIndex             - draw-order hint carried for parity/telemetry; the
//                        helper draws layers in the caller-provided order.
struct VulkanOverlayLayerDescriptor {
#if defined(__ANDROID__)
    VkImageView imageView = VK_NULL_HANDLE;
    VkSampler   sampler   = VK_NULL_HANDLE;
#else
    void* imageView = nullptr;
    void* sampler   = nullptr;
#endif
    double  x        = 0.0;
    double  y        = 0.0;
    double  width    = 0.0;
    double  height   = 0.0;
    double  rotation = 0.0;
    double  scale    = 1.0;
    double  opacity  = 1.0;
    int32_t zIndex   = 0;
};

// Caller-owned device context plus offscreen render target and readback
// staging buffer. Nothing in this struct is created or destroyed by the
// helper.
struct VulkanOverlayRenderTarget {
#if defined(__ANDROID__)
    VkDevice      device      = VK_NULL_HANDLE;
    VkQueue       queue       = VK_NULL_HANDLE;
    VkCommandPool commandPool = VK_NULL_HANDLE;
    // Color attachment image: 2D, `colorFormat`, single mip / layer, usage
    // must include COLOR_ATTACHMENT_BIT | TRANSFER_SRC_BIT. Left in
    // VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL after every successful render.
    VkImage       colorImage     = VK_NULL_HANDLE;
    VkImageView   colorImageView = VK_NULL_HANDLE;
    VkFormat      colorFormat    = VK_FORMAT_R8G8B8A8_UNORM;
    // When loadExistingContents is true the attachment's current contents are
    // preserved (loadOp LOAD) and `colorInitialLayout` must be the image's
    // current layout (never UNDEFINED / PREINITIALIZED). When false the
    // attachment is cleared to `clearColor` and prior contents are discarded.
    bool          loadExistingContents = false;
    VkImageLayout colorInitialLayout   = VK_IMAGE_LAYOUT_UNDEFINED;
    VkClearColorValue clearColor = {{0.0f, 0.0f, 0.0f, 1.0f}};
    // Host-visible readback buffer with usage TRANSFER_DST_BIT and size of at
    // least extentWidth * extentHeight * 4 bytes (declared by the caller in
    // readbackBufferSizeBytes; validated, not queried).
    VkBuffer      readbackBuffer          = VK_NULL_HANDLE;
    VkDeviceSize  readbackBufferSizeBytes = 0;
#else
    void*    device      = nullptr;
    void*    queue       = nullptr;
    void*    commandPool = nullptr;
    void*    colorImage     = nullptr;
    void*    colorImageView = nullptr;
    uint32_t colorFormat    = 0;
    bool     loadExistingContents = false;
    uint32_t colorInitialLayout   = 0;
    float    clearColor[4] = {0.0f, 0.0f, 0.0f, 1.0f};
    void*    readbackBuffer          = nullptr;
    uint64_t readbackBufferSizeBytes = 0;
#endif
    uint32_t extentWidth  = 0;
    uint32_t extentHeight = 0;
};

// Inverse placement of one layer resolved against an extentWidth x
// extentHeight canvas: the two push-constant UV rows plus the conservative
// scissor rectangle (top-left pixel coordinates, already clipped to the
// canvas). `visible == false` means the clipped bounding box is empty.
struct VulkanOverlayLayerPlacement {
    float    uvRow0[4] = {1.0f, 0.0f, 0.0f, 0.0f}; // u = r0 . (x, y, 0, 1)
    float    uvRow1[4] = {0.0f, 1.0f, 0.0f, 0.0f}; // v = r1 . (x, y, 0, 1)
    bool     visible   = false;
    int32_t  scissorX  = 0;
    int32_t  scissorY  = 0;
    uint32_t scissorWidth  = 0;
    uint32_t scissorHeight = 0;
};

// Pure, platform-independent validation of one descriptor against an
// extentWidth x extentHeight canvas (no Vulkan calls). Returns true when the
// layer is drawable; otherwise returns false and sets *outError to one of:
//   "vulkan_overlay_compositor_invalid_argument"  - extent dim == 0
//   "vulkan_overlay_compositor_invalid_image"     - imageView or sampler null
//   "vulkan_overlay_compositor_invalid_transform" - non-finite
//        x/y/width/height/rotation/scale, width/height <= 0, scale <= 0, or
//        a placement whose derived coefficients overflow to non-finite
//   "vulkan_overlay_compositor_invalid_opacity"   - non-finite or outside [0, 1]
// Checks run in exactly that order so callers can rely on the first failure.
bool ValidateVulkanOverlayLayerDescriptor(const VulkanOverlayLayerDescriptor& layer,
                                          uint32_t extentWidth,
                                          uint32_t extentHeight,
                                          std::string* outError);

// Pure, platform-independent transform math (no Vulkan calls): resolves the
// inverse UV rows and clipped scissor for `layer` on an extentWidth x
// extentHeight canvas. Base coordinates (x, y) in [0,1]^2 span the full
// canvas (top-left origin, Y down); the rows map them to overlay-local
// (u, v) with (0, 0) at the overlay's visual top-left corner and (1, 1) at
// its bottom-right. Non-finite inputs, zero extents, non-positive
// width/height/scale, or coefficients that overflow produce identity rows,
// visible == false, and return false.
bool ComputeVulkanOverlayPlacement(const VulkanOverlayLayerDescriptor& layer,
                                   uint32_t extentWidth,
                                   uint32_t extentHeight,
                                   VulkanOverlayLayerPlacement* outPlacement);

class VulkanOverlayCompositor {
public:
    VulkanOverlayCompositor();
    ~VulkanOverlayCompositor();

    VulkanOverlayCompositor(const VulkanOverlayCompositor&) = delete;
    VulkanOverlayCompositor& operator=(const VulkanOverlayCompositor&) = delete;

    // Draws `layerCount` layers from `layers` in order (back-to-front) into
    // target.colorImage (cleared or loaded per target.loadExistingContents),
    // copies it into target.readbackBuffer, and waits for completion (see
    // the draw model in the file header).
    //
    // target             - device/queue/commandPool, color attachment,
    //                      readback buffer. Every handle must be non-null,
    //                      extents > 0, readbackBufferSizeBytes >=
    //                      extentWidth*extentHeight*4, and when
    //                      loadExistingContents is true colorInitialLayout
    //                      must not be UNDEFINED / PREINITIALIZED (else
    //                      outError="vulkan_overlay_compositor_invalid_argument").
    // layers, layerCount - `layers` may be null only when layerCount is 0
    //                      (a no-op that still validates the target and
    //                      issues no Vulkan call). Every layer is validated
    //                      with ValidateVulkanOverlayLayerDescriptor before
    //                      any Vulkan call.
    // outError           - non-null; set to "" on success, to a validation
    //                      reason above, or to one of
    //                      "vulkan_overlay_compositor_shader_module_failed"
    //                      "vulkan_overlay_compositor_descriptor_failed"
    //                      "vulkan_overlay_compositor_render_pass_failed"
    //                      "vulkan_overlay_compositor_pipeline_failed"
    //                      "vulkan_overlay_compositor_command_buffer_failed"
    //                      "vulkan_overlay_compositor_submit_failed"
    //                      "vulkan_overlay_compositor_wait_failed"
    //                      for Vulkan-stage failures.
    //
    // Returns true only if every Vulkan object creation, the submit, and the
    // fence wait succeeded. Returns false with
    // outError="vulkan_overlay_compositor_unavailable_on_host" and no Vulkan
    // calls on non-Android builds.
    bool renderOverlays(const VulkanOverlayRenderTarget& target,
                        const VulkanOverlayLayerDescriptor* layers,
                        size_t layerCount,
                        std::string* outError);

    // Lifecycle telemetry for diagnostics: cumulative count of temporary
    // Vulkan objects this instance created (successful vkCreate*/vkAllocate*)
    // and released (vkDestroy*/vkFree*). They are equal whenever no
    // renderOverlays() call is in progress; a difference indicates a leak.
    uint64_t temporaryObjectsCreated() const { return temporaryObjectsCreated_; }
    uint64_t temporaryObjectsReleased() const { return temporaryObjectsReleased_; }

private:
    uint64_t temporaryObjectsCreated_  = 0;
    uint64_t temporaryObjectsReleased_ = 0;
};

} // namespace render
} // namespace vanguard
