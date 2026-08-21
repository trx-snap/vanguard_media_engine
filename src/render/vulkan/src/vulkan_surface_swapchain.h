// vulkan_surface_swapchain.h
// Phase 2K: Vulkan Render Pass + Swapchain Framebuffer Foundation.
// Phase 2O1: SwapchainResult enum + public helper WSI seam methods.
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

// ---------------------------------------------------------------------------
// Phase 2O1: SwapchainResult - explicit WSI operation outcome.
//
// Maps Vulkan WSI result codes exactly:
//   VK_SUCCESS                   -> kSuccess
//   VK_SUBOPTIMAL_KHR            -> kSuboptimal
//   VK_ERROR_OUT_OF_DATE_KHR     -> kOutOfDate
//   VK_ERROR_SURFACE_LOST_KHR    -> kSurfaceLost
//   VK_ERROR_DEVICE_LOST         -> kDeviceLost
//   any other VkResult           -> kError
//
// Vulkan headers remain confined to vulkan_surface_swapchain.cpp.
// ---------------------------------------------------------------------------
enum class SwapchainResult {
    kSuccess,
    kSuboptimal,
    kOutOfDate,
    kSurfaceLost,
    kDeviceLost,
    kError,
};

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

    // Phase 2O2B4: Returns VkSemaphore as an opaque uint64_t handle for present
    // synchronization for swapchain image at `index`, or 0 if not attached or
    // index is out of range.
    uint64_t getPresentReadySemaphoreHandle(uint32_t index) const;

    // --- Phase 2O1: WSI seam methods ---
    // Called by VulkanBackend::renderFrame (Phase 2O2).  Not called in this phase.
    //
    // semaphoreHandle / fenceHandle / waitSemaphoreHandle are opaque uint64_t
    // values that the caller (VulkanBackend::Impl) encodes from Vulkan
    // non-dispatchable handles via memcpy.  queueHandle is a dispatchable
    // VkQueue cast to void*.

    // Acquire the next swapchain image.
    // semaphoreHandle - VkSemaphore as uint64_t to signal on acquire, or 0.
    // fenceHandle     - VkFence as uint64_t to signal on acquire, or 0.
    // outImageIndex   - non-null; receives the acquired image index on kSuccess
    //                   or kSuboptimal.
    // timeoutNs       - timeout in nanoseconds passed to vkAcquireNextImageKHR.
    SwapchainResult acquireNextImage(uint64_t semaphoreHandle,
                                     uint64_t fenceHandle,
                                     uint32_t* outImageIndex,
                                     uint64_t timeoutNs);

    // Present an already-rendered swapchain image.
    // queueHandle           - VkQueue as void* (dispatchable handle).
    // waitSemaphoreHandle   - VkSemaphore as uint64_t to wait on before present.
    // imageIndex            - index returned by a successful acquireNextImage.
    SwapchainResult presentImage(void* queueHandle,
                                  uint64_t waitSemaphoreHandle,
                                  uint32_t imageIndex);

    // Return the current swapchain extent dimensions.
    // Both return 0 when not attached.
    uint32_t getExtentWidth() const;
    uint32_t getExtentHeight() const;

private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};

} // namespace render
} // namespace vanguard
