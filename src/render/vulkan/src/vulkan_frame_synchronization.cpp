// vulkan_frame_synchronization.cpp
// Phase 2N: Vulkan Frame Synchronization & Command Buffer Foundation.
//
// On Android (__ANDROID__):
//   Manages per-frame synchronization resources (binary semaphores and fences)
//   and primary command buffers.
//
// On non-Android host builds:
//   Provides safe stubs compiling cleanly without the Vulkan SDK.
//
// NOTE: Compute pipeline remains deferred: compute pipeline still requires
// storage output target plus descriptor/pipeline layout expansion.
// NOTE: Release fence export remains deferred: release fence export requires
// external fence fd support/probing (e.g. VK_KHR_external_fence_fd) and remains
// later work.

#include "vulkan_frame_synchronization.h"

#if defined(__ANDROID__)

#include <android/log.h>

#define VGLOG_FS(...) \
    __android_log_print(ANDROID_LOG_ERROR, "VanguardFrameSynchronization", __VA_ARGS__)

namespace vanguard {
namespace render {

// ---------------------------------------------------------------------------
// Move semantics (Android)
// ---------------------------------------------------------------------------

VulkanFrameSynchronization::VulkanFrameSynchronization(VulkanFrameSynchronization&& other) noexcept
    : device_(other.device_),
      commandPool_(other.commandPool_),
      frames_(std::move(other.frames_)),
      initialized_(other.initialized_) {
    other.device_ = VK_NULL_HANDLE;
    other.commandPool_ = VK_NULL_HANDLE;
    other.frames_.clear();
    other.initialized_ = false;
}

VulkanFrameSynchronization& VulkanFrameSynchronization::operator=(VulkanFrameSynchronization&& other) noexcept {
    if (this != &other) {
        shutdown();
        device_ = other.device_;
        commandPool_ = other.commandPool_;
        frames_ = std::move(other.frames_);
        initialized_ = other.initialized_;

        other.device_ = VK_NULL_HANDLE;
        other.commandPool_ = VK_NULL_HANDLE;
        other.frames_.clear();
        other.initialized_ = false;
    }
    return *this;
}

// ---------------------------------------------------------------------------
// initialize() (Android)
// ---------------------------------------------------------------------------

bool VulkanFrameSynchronization::initialize(VkDevice device,
                                            VkCommandPool commandPool,
                                            uint32_t frameCount) {
    if (device == VK_NULL_HANDLE) {
        VGLOG_FS("initialize: device is VK_NULL_HANDLE");
        return false;
    }
    if (commandPool == VK_NULL_HANDLE) {
        VGLOG_FS("initialize: commandPool is VK_NULL_HANDLE");
        return false;
    }
    if (frameCount < kMinFramesInFlight || frameCount > kMaxFramesInFlight) {
        VGLOG_FS("initialize: frameCount %u out of range [%u, %u]",
                 frameCount, kMinFramesInFlight, kMaxFramesInFlight);
        return false;
    }

    if (initialized_) {
        shutdown();
    }

    // Allocate primary command buffers
    VkCommandBufferAllocateInfo allocInfo{};
    allocInfo.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO;
    allocInfo.pNext = nullptr;
    allocInfo.commandPool = commandPool;
    allocInfo.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY;
    allocInfo.commandBufferCount = frameCount;

    std::vector<VkCommandBuffer> cmdBuffers(frameCount, VK_NULL_HANDLE);
    VkResult res = vkAllocateCommandBuffers(device, &allocInfo, cmdBuffers.data());
    if (res != VK_SUCCESS) {
        VGLOG_FS("initialize: vkAllocateCommandBuffers failed: %d", static_cast<int>(res));
        return false;
    }

    VkSemaphoreCreateInfo semInfo{};
    semInfo.sType = VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO;
    semInfo.pNext = nullptr;
    semInfo.flags = 0;

    VkFenceCreateInfo fenceInfo{};
    fenceInfo.sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO;
    fenceInfo.pNext = nullptr;
    fenceInfo.flags = VK_FENCE_CREATE_SIGNALED_BIT;

    std::vector<VulkanFrameSyncResources> newFrames(frameCount);
    bool success = true;

    for (uint32_t i = 0; i < frameCount; ++i) {
        newFrames[i].commandBuffer = cmdBuffers[i];

        res = vkCreateSemaphore(device, &semInfo, nullptr, &newFrames[i].imageAvailableSemaphore);
        if (res != VK_SUCCESS) {
            VGLOG_FS("initialize: vkCreateSemaphore (imageAvailable) failed for frame %u: %d",
                     i, static_cast<int>(res));
            success = false;
            break;
        }

        res = vkCreateFence(device, &fenceInfo, nullptr, &newFrames[i].inFlightFence);
        if (res != VK_SUCCESS) {
            VGLOG_FS("initialize: vkCreateFence failed for frame %u: %d",
                     i, static_cast<int>(res));
            success = false;
            break;
        }
    }

    if (!success) {
        // Rollback created sync primitives
        for (auto& frame : newFrames) {
            if (frame.inFlightFence != VK_NULL_HANDLE) {
                vkDestroyFence(device, frame.inFlightFence, nullptr);
                frame.inFlightFence = VK_NULL_HANDLE;
            }
            if (frame.imageAvailableSemaphore != VK_NULL_HANDLE) {
                vkDestroySemaphore(device, frame.imageAvailableSemaphore, nullptr);
                frame.imageAvailableSemaphore = VK_NULL_HANDLE;
            }
        }
        vkFreeCommandBuffers(device, commandPool, static_cast<uint32_t>(cmdBuffers.size()), cmdBuffers.data());
        return false;
    }

    frames_ = std::move(newFrames);
    device_ = device;
    commandPool_ = commandPool;
    initialized_ = true;
    return true;
}

// ---------------------------------------------------------------------------
// shutdown() (Android)
// ---------------------------------------------------------------------------

void VulkanFrameSynchronization::shutdown(VkDevice device, VkCommandPool commandPool) {
    VkDevice dev = (device != VK_NULL_HANDLE) ? device : device_;
    VkCommandPool pool = (commandPool != VK_NULL_HANDLE) ? commandPool : commandPool_;

    if (dev != VK_NULL_HANDLE) {
        // Destroy fences and semaphores first
        for (auto& frame : frames_) {
            if (frame.inFlightFence != VK_NULL_HANDLE) {
                vkDestroyFence(dev, frame.inFlightFence, nullptr);
                frame.inFlightFence = VK_NULL_HANDLE;
            }
            if (frame.imageAvailableSemaphore != VK_NULL_HANDLE) {
                vkDestroySemaphore(dev, frame.imageAvailableSemaphore, nullptr);
                frame.imageAvailableSemaphore = VK_NULL_HANDLE;
            }
        }

        // Free command buffers
        if (pool != VK_NULL_HANDLE) {
            std::vector<VkCommandBuffer> cmdBuffers;
            cmdBuffers.reserve(frames_.size());
            for (const auto& frame : frames_) {
                if (frame.commandBuffer != VK_NULL_HANDLE) {
                    cmdBuffers.push_back(frame.commandBuffer);
                }
            }
            if (!cmdBuffers.empty()) {
                vkFreeCommandBuffers(dev, pool, static_cast<uint32_t>(cmdBuffers.size()), cmdBuffers.data());
            }
        }
    }

    frames_.clear();
    device_ = VK_NULL_HANDLE;
    commandPool_ = VK_NULL_HANDLE;
    initialized_ = false;
}

// ---------------------------------------------------------------------------
// Accessors & helpers (Android)
// ---------------------------------------------------------------------------

bool VulkanFrameSynchronization::isInitialized() const {
    return initialized_;
}

uint32_t VulkanFrameSynchronization::getFrameCount() const {
    return static_cast<uint32_t>(frames_.size());
}

const VulkanFrameSyncResources* VulkanFrameSynchronization::getFrame(uint32_t frameIndex) const {
    if (!initialized_ || frameIndex >= frames_.size()) {
        return nullptr;
    }
    return &frames_[frameIndex];
}

bool VulkanFrameSynchronization::waitForFrameFence(uint32_t frameIndex, uint64_t timeoutNs) const {
    if (!initialized_ || frameIndex >= frames_.size() || device_ == VK_NULL_HANDLE) {
        return false;
    }
    VkFence fence = frames_[frameIndex].inFlightFence;
    if (fence == VK_NULL_HANDLE) {
        return false;
    }
    VkResult res = vkWaitForFences(device_, 1, &fence, VK_TRUE, timeoutNs);
    return (res == VK_SUCCESS);
}

bool VulkanFrameSynchronization::resetFrameFence(uint32_t frameIndex) const {
    if (!initialized_ || frameIndex >= frames_.size() || device_ == VK_NULL_HANDLE) {
        return false;
    }
    VkFence fence = frames_[frameIndex].inFlightFence;
    if (fence == VK_NULL_HANDLE) {
        return false;
    }
    VkResult res = vkResetFences(device_, 1, &fence);
    return (res == VK_SUCCESS);
}

bool VulkanFrameSynchronization::resetCommandBuffer(uint32_t frameIndex, VkCommandBufferResetFlags flags) const {
    if (!initialized_ || frameIndex >= frames_.size()) {
        return false;
    }
    VkCommandBuffer cmd = frames_[frameIndex].commandBuffer;
    if (cmd == VK_NULL_HANDLE) {
        return false;
    }
    VkResult res = vkResetCommandBuffer(cmd, flags);
    return (res == VK_SUCCESS);
}

} // namespace render
} // namespace vanguard

#else // !__ANDROID__

// ---------------------------------------------------------------------------
// Non-Android host stubs
// ---------------------------------------------------------------------------

namespace vanguard {
namespace render {

VulkanFrameSynchronization::VulkanFrameSynchronization(VulkanFrameSynchronization&& other) noexcept
    : device_(other.device_),
      commandPool_(other.commandPool_),
      frames_(std::move(other.frames_)),
      initialized_(other.initialized_) {
    other.device_ = nullptr;
    other.commandPool_ = nullptr;
    other.frames_.clear();
    other.initialized_ = false;
}

VulkanFrameSynchronization& VulkanFrameSynchronization::operator=(VulkanFrameSynchronization&& other) noexcept {
    if (this != &other) {
        shutdown();
        device_ = other.device_;
        commandPool_ = other.commandPool_;
        frames_ = std::move(other.frames_);
        initialized_ = other.initialized_;

        other.device_ = nullptr;
        other.commandPool_ = nullptr;
        other.frames_.clear();
        other.initialized_ = false;
    }
    return *this;
}

bool VulkanFrameSynchronization::initialize(void* /*device*/,
                                            void* /*commandPool*/,
                                            uint32_t /*frameCount*/) {
    return false;
}

void VulkanFrameSynchronization::shutdown(void* /*device*/, void* /*commandPool*/) {
    frames_.clear();
    device_ = nullptr;
    commandPool_ = nullptr;
    initialized_ = false;
}

bool VulkanFrameSynchronization::isInitialized() const {
    return false;
}

uint32_t VulkanFrameSynchronization::getFrameCount() const {
    return 0;
}

const VulkanFrameSyncResources* VulkanFrameSynchronization::getFrame(uint32_t /*frameIndex*/) const {
    return nullptr;
}

bool VulkanFrameSynchronization::waitForFrameFence(uint32_t /*frameIndex*/, uint64_t /*timeoutNs*/) const {
    return false;
}

bool VulkanFrameSynchronization::resetFrameFence(uint32_t /*frameIndex*/) const {
    return false;
}

bool VulkanFrameSynchronization::resetCommandBuffer(uint32_t /*frameIndex*/, uint32_t /*flags*/) const {
    return false;
}

} // namespace render
} // namespace vanguard

#endif // __ANDROID__
