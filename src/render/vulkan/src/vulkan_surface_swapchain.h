// vulkan_surface_swapchain.h
// Phase 2B2: private helper - VulkanSurfaceSwapchain.
//
// Owns Vulkan WSI handles (VkSurfaceKHR, VkSwapchainKHR, swapchain images,
// extent, format) behind a PImpl. All Vulkan and Android headers are confined
// to the .cpp translation unit; this header includes only <cstdint> and
// <memory>.
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

    // Attach: create VkSurfaceKHR + VkSwapchainKHR.
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

    // Recreate swapchain for new dimensions (uses oldSwapchain path).
    // Safe to call only when already attached. Returns false on failure;
    // on partial failure the old swapchain is preserved.
    bool resize(uint32_t width, uint32_t height);

    // Idempotent teardown. Waits for device idle, destroys WSI handles.
    // Does NOT release the native window.
    void detach();

    bool hasSurface() const;

private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};

} // namespace render
} // namespace vanguard
