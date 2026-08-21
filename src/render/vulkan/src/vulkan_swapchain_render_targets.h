// vulkan_swapchain_render_targets.h
// Phase 2K: Vulkan Render Pass + Swapchain Framebuffer Foundation.
//
// VulkanSwapchainRenderTargets owns the GPU render-target objects that
// correspond to one swapchain:
//   - VkRenderPass (single-subpass, one color attachment)
//   - vector<VkImageView>  (one view per swapchain image)
//   - vector<VkFramebuffer> (one framebuffer per image view)
//
// Lifetime is managed by VulkanSurfaceSwapchain, which calls
// create() / destroy() around swapchain creation/destruction.
// All Vulkan and Android headers are confined to the .cpp translation unit;
// this header includes only <cstdint> and <memory>.
//
// Handles are returned as opaque uint64_t values (safe on 32-bit Android
// where non-dispatchable handles are always 64-bit integers).
//
// NOTE: Compute pipeline remains deferred. The current compute shader has no
// storage output target; future compute work requires descriptor and pipeline
// layout expansion before a VkPipeline can be created here.

#pragma once
#include <cstdint>
#include <memory>

namespace vanguard {
namespace render {

class VulkanSwapchainRenderTargets {
public:
    VulkanSwapchainRenderTargets();
    ~VulkanSwapchainRenderTargets();

    // Non-copyable, non-movable.
    VulkanSwapchainRenderTargets(const VulkanSwapchainRenderTargets&) = delete;
    VulkanSwapchainRenderTargets& operator=(const VulkanSwapchainRenderTargets&) = delete;

    // Create render-pass, image views, and framebuffers for the given
    // swapchain images. deviceHandle is VkDevice cast to void*.
    // imageHandles is an array of VkImage handles encoded as uint64_t via
    // memcpy (portable across 32-bit uint64_t handles and 64-bit pointer
    // handles per the vkHandleToU64 convention). imageCount is the array
    // length. format is the VkFormat value cast to uint32_t.
    // extentWidth/extentHeight are the swapchain extent dimensions.
    // Returns false and leaves state fully clean on any failure.
    bool create(void* deviceHandle,
                uint32_t format,
                uint32_t extentWidth,
                uint32_t extentHeight,
                const uint64_t* imageHandles,
                uint32_t imageCount);

    // Destroy all GPU objects in safe order: framebuffers -> imageViews ->
    // renderPass. Safe to call when not created (idempotent). deviceHandle
    // must be the same VkDevice used during create().
    void destroy(void* deviceHandle);

    // Returns true when render targets are successfully created.
    bool isCreated() const;

    // Returns the swapchain image count (== framebuffer/image-view count),
    // or 0 if not created.
    uint32_t getImageCount() const;

    // Returns VkRenderPass as an opaque uint64_t handle, or 0 if not created.
    uint64_t getRenderPassHandle() const;

    // Returns VkImageView as an opaque uint64_t for the given index,
    // or 0 if not created or index is out of range.
    uint64_t getImageViewHandle(uint32_t index) const;

    // Returns VkFramebuffer as an opaque uint64_t for the given index,
    // or 0 if not created or index is out of range.
    uint64_t getFramebufferHandle(uint32_t index) const;

private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};

} // namespace render
} // namespace vanguard
