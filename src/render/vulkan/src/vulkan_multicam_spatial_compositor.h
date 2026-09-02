// vulkan_multicam_spatial_compositor.h
// P3-MULTICAM-NODE (sub-slice SPATIAL-VULKAN-RENDER): Private helper -
// VulkanMultiCamSpatialCompositor.
//
// Rasterizes two already-created, already-sampleable Vulkan images (primary
// layer and secondary layer) into a caller-owned offscreen RGBA8 color
// attachment as two independent opaque rectangles, then copies the attachment
// into a caller-owned host-visible readback buffer. This is the Vulkan
// sibling of the GLES GlesMultiCamSpatialCompositor
// (render/gles/src/gles_multicam_spatial_compositor.h): an opaque
// full-screen-triangle draw of the primary layer scoped to its viewport /
// scissor pixel rectangle, followed by an opaque full-screen-triangle draw of
// the secondary layer scoped to its own rectangle. No blend, no opacity, no
// corner radius, no crop -- the secondary layer overwrites the primary layer
// wherever the two rectangles overlap (paint-over ordering).
//
// Dependency direction: vanguard_render_vulkan never includes a
// compositors/graph header. The composition root (a diagnostic JNI in this
// slice) evaluates vanguard::compositors::ComputeMultiCamLayout() and converts
// the resulting normalized viewports into the VulkanSpatialViewportRectPx
// top-left pixel rectangles consumed here.
//
// Shader strategy (no new GLSL/SPIR-V): every draw uses the existing AOT
// passthrough vertex/fragment SPIR-V (fullscreen triangle, one combined image
// sampler at binding 0, VideoTransformFullPushConstants) with an identity UV
// transform and identity color matrix. Canvas placement rides purely on
// dynamic viewport + scissor state; the full sampled image is stretched into
// its rectangle.
//
// Coordinate conventions: rects are top-left-origin, Y-down pixel rectangles
// (Vulkan framebuffer convention). Texel row 0 of each sampled image lands on
// the top row of its rectangle and readback row 0 is the top canvas row (no V
// flip). Sampled images must already be in
// VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL; no layout transition of the
// sampled images is recorded.
//
// Ownership / lifecycle: owns only the temporary Vulkan objects it creates
// per renderSpatialComposite() call (two shader modules, descriptor set
// layout / pool / two sets, pipeline layout, render pass, framebuffer, one
// opaque pipeline, one command buffer from the caller's pool, one fence) and
// destroys / frees all of them on every success and failure path before
// returning. It never creates or destroys the device, queue, command pool,
// sampled images / views / samplers, color attachment image / view, or
// readback buffer / memory. The call is synchronous: it submits once and
// waits on its own fence, so on return the readback buffer holds the rendered
// RGBA8 pixels (tightly packed, row pitch = extentWidth * 4). The caller
// maps / invalidates the readback memory itself.
//
// Scope non-claims: no camera open, no OES / AHardwareBuffer / YUV import
// claim, no product / editor / export wiring, no production VulkanBackend
// mutation. Fails closed: any invalid argument returns an ASCII error before
// a single Vulkan call is issued.
//
// Private source: this header is confined to the private Vulkan render
// backend implementation. On Android it includes <vulkan/vulkan.h>; on
// non-Android host builds the Vulkan handle fields become void*/uint32_t
// mirrors and renderSpatialComposite() compiles to a safe unavailable stub,
// matching the other private Vulkan helpers.

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

// Top-left-origin, Y-down pixel rectangle on the color attachment. The
// composition root derives it from the compositor's normalized layout rects;
// this helper validates it against the attachment extent and never adjusts
// it.
struct VulkanSpatialViewportRectPx {
    int32_t  x        = 0;
    int32_t  yTop     = 0;
    uint32_t width    = 0;
    uint32_t height   = 0;
};

// One already-sampleable layer: a 2D image view in
// VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL plus the sampler used to read it.
// Neither handle is owned by this helper.
struct VulkanMultiCamSpatialLayerImage {
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
struct VulkanMultiCamSpatialRenderTarget {
#if defined(__ANDROID__)
    VkDevice      device      = VK_NULL_HANDLE;
    VkQueue       queue       = VK_NULL_HANDLE;
    VkCommandPool commandPool = VK_NULL_HANDLE;
    // Color attachment image: 2D, `colorFormat` (RGBA8), single mip / layer,
    // usage must include COLOR_ATTACHMENT_BIT | TRANSFER_SRC_BIT. Its prior
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
    // Clear color applied to the whole attachment before either layer draw.
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

class VulkanMultiCamSpatialCompositor {
public:
    VulkanMultiCamSpatialCompositor();
    ~VulkanMultiCamSpatialCompositor();

    VulkanMultiCamSpatialCompositor(const VulkanMultiCamSpatialCompositor&) = delete;
    VulkanMultiCamSpatialCompositor& operator=(const VulkanMultiCamSpatialCompositor&) = delete;

    // Clears target.colorImage to target.clearColor, draws `primary` opaque
    // into primaryRect, then draws `secondary` opaque into secondaryRect,
    // copies the attachment into target.readbackBuffer and waits for
    // completion.
    //
    // target        - device/queue/commandPool, color attachment, readback
    //                 buffer. Every handle must be non-null, extents > 0, and
    //                 readbackBufferSizeBytes >= extentWidth*extentHeight*4
    //                 (else outError="vulkan_multicam_spatial_compositor_invalid_argument").
    // primary,
    // secondary     - non-null imageView + sampler pairs (same
    //                 "_invalid_argument" error otherwise).
    // primaryRect,
    // secondaryRect - top-left pixel rects; width/height must be > 0,
    //                 x/yTop must be >= 0, and x+width / yTop+height must not
    //                 exceed extentWidth / extentHeight (evaluated in 64-bit
    //                 arithmetic so no overflow can slip through). Any
    //                 violation fails closed with
    //                 outError="vulkan_multicam_spatial_compositor_invalid_rect".
    // outError      - non-null; set to "" on success or an ASCII failure
    //                 reason ("..._shader_module_failed", "..._descriptor_failed",
    //                 "..._render_pass_failed", "..._pipeline_failed",
    //                 "..._command_buffer_failed", "..._submit_failed",
    //                 "..._wait_failed").
    //
    // All validation runs before any Vulkan call; an invalid call creates no
    // temporary Vulkan object. Returns true only if every Vulkan object
    // creation, the submit, and the fence wait succeeded. Returns false with
    // outError="vulkan_multicam_spatial_compositor_unavailable_on_host" and
    // no Vulkan calls on non-Android builds.
    bool renderSpatialComposite(const VulkanMultiCamSpatialRenderTarget& target,
                                const VulkanMultiCamSpatialLayerImage& primary,
                                const VulkanMultiCamSpatialLayerImage& secondary,
                                const VulkanSpatialViewportRectPx& primaryRect,
                                const VulkanSpatialViewportRectPx& secondaryRect,
                                std::string* outError);

    // Lifecycle telemetry for diagnostics: cumulative count of temporary
    // Vulkan objects this instance created (successful vkCreate*/vkAllocate*)
    // and released (vkDestroy*/vkFree*). They are equal whenever no
    // renderSpatialComposite() call is in progress; a difference indicates a
    // leak.
    uint64_t temporaryObjectsCreated() const { return temporaryObjectsCreated_; }
    uint64_t temporaryObjectsReleased() const { return temporaryObjectsReleased_; }

private:
    uint64_t temporaryObjectsCreated_  = 0;
    uint64_t temporaryObjectsReleased_ = 0;
};

} // namespace render
} // namespace vanguard
