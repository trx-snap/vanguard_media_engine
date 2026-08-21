// vulkan_frame_synchronization.h
// Phase 2N: Vulkan Frame Synchronization & Command Buffer Foundation.
// Phase 2O2B4: Presentation semaphores are owned per swapchain-image in
// VulkanSurfaceSwapchain (Khronos WSI lifecycle requirement).
//
// VulkanFrameSynchronization is a private move-only helper class managing
// per-frame-in-flight execution and synchronization resources:
//   - VkCommandBuffer (allocated from borrowed command pool)
//   - VkSemaphore imageAvailableSemaphore (binary semaphore for swapchain acquisition)
//   - VkFence inFlightFence (signaled initially to allow first frame wait)
//
// VkDevice and VkCommandPool are borrowed during initialize/shutdown and stored
// internally only for explicit shutdown or move-assignment cleanup.
// The destructor does NOT call Vulkan; the caller must call shutdown() before
// VkDevice or VkCommandPool destruction.
//
// NOTE: Compute pipeline remains deferred: compute pipeline still requires
// storage output target plus descriptor/pipeline layout expansion.
// NOTE: Release fence export remains deferred: release fence export requires
// external fence fd support/probing (e.g. VK_KHR_external_fence_fd) and remains
// later work.

#pragma once

#include <cstdint>
#include <vector>

#if defined(__ANDROID__)
#ifndef VK_USE_PLATFORM_ANDROID_KHR
#define VK_USE_PLATFORM_ANDROID_KHR
#endif
#include <vulkan/vulkan.h>
#endif

namespace vanguard {
namespace render {

#if defined(__ANDROID__)

struct VulkanFrameSyncResources {
    VkCommandBuffer commandBuffer = VK_NULL_HANDLE;
    VkSemaphore imageAvailableSemaphore = VK_NULL_HANDLE;
    VkFence inFlightFence = VK_NULL_HANDLE;
};

#else

struct VulkanFrameSyncResources {
    void* commandBuffer = nullptr;
    void* imageAvailableSemaphore = nullptr;
    void* inFlightFence = nullptr;
};

#endif

class VulkanFrameSynchronization {
public:
    static constexpr uint32_t kDefaultFramesInFlight = 2;
    static constexpr uint32_t kMinFramesInFlight = 1;
    static constexpr uint32_t kMaxFramesInFlight = 3;

    VulkanFrameSynchronization() = default;
    ~VulkanFrameSynchronization() = default;

    // Non-copyable.
    VulkanFrameSynchronization(const VulkanFrameSynchronization&) = delete;
    VulkanFrameSynchronization& operator=(const VulkanFrameSynchronization&) = delete;

    // Move constructor and move assignment.
    VulkanFrameSynchronization(VulkanFrameSynchronization&& other) noexcept;
    VulkanFrameSynchronization& operator=(VulkanFrameSynchronization&& other) noexcept;

    // Initialize per-frame synchronization and command buffer resources.
    // frameCount must be in [kMinFramesInFlight, kMaxFramesInFlight].
    bool initialize(
#if defined(__ANDROID__)
        VkDevice device,
        VkCommandPool commandPool,
        uint32_t frameCount = kDefaultFramesInFlight
#else
        void* device,
        void* commandPool,
        uint32_t frameCount = kDefaultFramesInFlight
#endif
    );

    // Shutdown and destroy owned per-frame Vulkan resources.
    // Idempotent. Clears stored handles, frames, and initialized flag.
    void shutdown(
#if defined(__ANDROID__)
        VkDevice device = VK_NULL_HANDLE,
        VkCommandPool commandPool = VK_NULL_HANDLE
#else
        void* device = nullptr,
        void* commandPool = nullptr
#endif
    );

    // Returns true if initialized with active per-frame resources.
    bool isInitialized() const;

    // Returns the number of frames in flight.
    uint32_t getFrameCount() const;

    // Returns pointer to sync resources for frameIndex, or nullptr if out of range / not initialized.
    const VulkanFrameSyncResources* getFrame(uint32_t frameIndex) const;

    // Waits for the frame's in-flight fence. Returns true on VK_SUCCESS only.
    bool waitForFrameFence(uint32_t frameIndex, uint64_t timeoutNs = UINT64_MAX) const;

    // Resets the frame's in-flight fence. Returns true on VK_SUCCESS only.
    bool resetFrameFence(uint32_t frameIndex) const;

    // Resets the frame's command buffer. Returns true on VK_SUCCESS only.
    bool resetCommandBuffer(
        uint32_t frameIndex,
#if defined(__ANDROID__)
        VkCommandBufferResetFlags flags = 0
#else
        uint32_t flags = 0
#endif
    ) const;

private:
#if defined(__ANDROID__)
    VkDevice device_ = VK_NULL_HANDLE;
    VkCommandPool commandPool_ = VK_NULL_HANDLE;
#else
    void* device_ = nullptr;
    void* commandPool_ = nullptr;
#endif
    std::vector<VulkanFrameSyncResources> frames_;
    bool initialized_ = false;
};

} // namespace render
} // namespace vanguard
