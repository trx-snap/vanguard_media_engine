// vulkan_surface_swapchain.h
// Phase 2K: Vulkan Render Pass + Swapchain Framebuffer Foundation.
//
// Owns Vulkan WSI handles (VkSurfaceKHR, VkSwapchainKHR, swapchain images,
// extent, format, render pass, image views, framebuffers) behind a PImpl.
// All Vulkan and Android headers are confined to the .cpp translation unit;
// this header includes only <cstdint> and <memory>.
//
// Handles passed as void* are dispatchable Vulkan objects cast by the caller
// (VulkanBackend::Impl).  The helper casts them back inside the .cpp.
//
// nativeWindow (ANativeWindow*) is BORROWED. The helper does not acquire,
// release, or outlive-store it.

#pragma once
#include <cstdint>
#include <memory>

namespace vanguard {
namespace render {

class VulkanSurfaceSwapchain {
public:
    VulkanSurfaceSwapchain();
    ~VulkanSurfaceSwapchain();

    // Non-copyable, non-movable.
    VulkanSurfaceSwapchain(const VulkanSurfaceSwapchain&) = delete;
    VulkanSurfaceSwapchain& operator=(const VulkanSurfaceSwapchain&) = delete;

    // Attach: create VkSurfaceKHR + VkSwapchainKHR + render targets.
    // All handle parameters are dispatchable Vulkan objects cast to void*.
    // nativeWindow is a borrowed ANativeWindow* cast to void*.
    // Returns false and leaves state clean on any failure.
    bool attach(void* instanceHandle,
                void* physicalDeviceHandle,
                void* deviceHandle,
                uint32_t queueFamilyIndex,
                void* nativeWindow,
                uint32_t width,
                uint32_t height);

    // Recreate swapchain + render targets for new dimensions (uses oldSwapchain
    // path). Safe to call only when already attached.
    //
    // WSI retirement semantics: vkCreateSwapchainKHR retires oldSwapchain
    // regardless of success (Khronos VkSwapchainCreateInfoKHR spec).
    //   - Failure before vkCreateSwapchainKHR: old swapchain/render targets
    //     are fully preserved; returns false; caller may retry.
    //   - Failure at or after vkCreateSwapchainKHR: fail-closed -- destroy new
    //     render targets and new swapchain, then vkDeviceWaitIdle, then destroy
    //     old render targets, old swapchain (retired), and surface; state
    //     cleared, attached set to false; returns false. Caller must reattach.
    //   - On full success: vkDeviceWaitIdle, old render targets destroyed, old
    //     swapchain destroyed, new state committed (render targets + swapchain).
    bool resize(uint32_t width, uint32_t height);

    // Idempotent teardown. Waits for device idle, destroys render targets,
    // swapchain, and surface handles. Does NOT release the native window.
    void detach();

    bool hasSurface() const;

    // --- Phase 2K render-target accessors (private-helper API) ---
    // Return Vulkan non-dispatchable handles as opaque uint64_t values.
    // Using uint64_t is safe on 32-bit Android where non-dispatchable handles
    // are always 64-bit integers and must not be truncated to pointer width.
    // Host stubs return 0. Android variants are only valid when attached.

    // Returns VkRenderPass as an opaque uint64_t handle, or 0 if not attached.
    uint64_t getRenderPassHandle() const;

    // Returns the number of framebuffers/image views (== swapchain image count)
    // when attached, otherwise 0.
    uint32_t getImageCount() const;

    // Returns VkImageView as an opaque uint64_t handle for swapchain image at
    // `index`, or 0 if not attached or index is out of range.
    uint64_t getImageViewHandle(uint32_t index) const;

    // Returns VkFramebuffer as an opaque uint64_t handle for swapchain image at
    // `index`, or 0 if not attached or index is out of range.
    uint64_t getFramebufferHandle(uint32_t index) const;

private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};

} // namespace render
} // namespace vanguard
