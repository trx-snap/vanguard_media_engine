// vulkan_hardware_buffer_imports.h
// Phase 2E/2G/2O1: Private helper - VulkanHardwareBufferImports.
//
// Owns the AHardwareBuffer->Vulkan import table including sampling resources
// (VkSamplerYcbcrConversion, VkImageView, VkSampler) and Phase 2G acquire-fence
// semaphore import (VkSemaphore).
// All Vulkan and Android headers are confined to the .cpp translation unit;
// this header includes only <cstdint>, <memory>, and the public shared opaque
// types.
//
// Void* handles passed to import() are AHardwareBuffer* cast by the caller
// (VulkanBackend::Impl).  The helper casts them back inside the .cpp.
//
// AHardwareBuffer symbols are loaded at runtime via dlopen/dlsym from
// libandroid.so.  vkGetAndroidHardwareBufferPropertiesANDROID,
// vkCreateSamplerYcbcrConversion, vkDestroySamplerYcbcrConversion, and
// vkImportSemaphoreFdKHR are loaded via vkGetDeviceProcAddr.  No strong references
// to AHardwareBuffer_* or to Android/Vulkan extension structs appear in this header.

#pragma once
#include "vanguard/render/hardware_buffer_import.h"
#include "vulkan_hardware_buffer_image.h"
#include <cstdint>
#include <memory>

namespace vanguard {
namespace render {

class VulkanHardwareBufferImports {
public:
    VulkanHardwareBufferImports();
    ~VulkanHardwareBufferImports();

    // Non-copyable, non-movable.
    VulkanHardwareBufferImports(const VulkanHardwareBufferImports&) = delete;
    VulkanHardwareBufferImports& operator=(
        const VulkanHardwareBufferImports&) = delete;

    // Must be called once after VkDevice creation.
    // deviceHandle   - VkDevice cast to void*.
    // physDevHandle  - VkPhysicalDevice cast to void*.
    // Returns false if required Android or Vulkan symbols cannot be resolved,
    // including vkCreateSamplerYcbcrConversion /
    // vkDestroySamplerYcbcrConversion entry points.
    bool initialize(void* deviceHandle, void* physDevHandle);

    // Idempotent teardown.  Destroys all import records (acquireSemaphore,
    // VkSampler, VkImageView, VkSamplerYcbcrConversion, VkImage, VkDeviceMemory,
    // AHB refs) in teardown order before the caller destroys VkDevice.
    void shutdown();

    // Import an AHardwareBuffer into Vulkan.
    //
    // hardwareBuffer  - non-null AHardwareBuffer* cast to void*.
    // acquireFenceFd  - acquire fence fd or -1; ownership transfers at call
    //                   entry on all return paths.
    // outHandle       - non-null; set to kInvalidHardwareBufferHandle on failure.
    // outDescriptor   - non-null; zeroed on failure.
    HardwareBufferImportResult importBuffer(
        void* hardwareBuffer,
        int acquireFenceFd,
        HardwareBufferHandle* outHandle,
        HardwareBufferDescriptor* outDescriptor);

    // Release a previously imported buffer by handle.
    // Phase 2P1: transfers the stored latestReleaseFenceFd to *outReleaseFenceFd
    // when provided; otherwise closes it. Sets the stored field to -1 before
    // destroyRecord. Destroys imported resources in teardown order.
    // outReleaseFenceFd - optional; set to -1 if non-null and no fd is stored.
    HardwareBufferImportResult releaseBuffer(
        HardwareBufferHandle handle,
        int* outReleaseFenceFd);

    // Phase 2P1: Transfer the latest release-fence fd to the import record for
    // handle. Ownership of fd>=0 transfers at entry on all paths.
    // Valid handle: close prior valid stored FD, store incoming value
    // (including -1), return true.
    // Invalid handle: close incoming valid FD, return false.
    bool setLatestReleaseFenceFd(HardwareBufferHandle handle, int fd);

    // Returns true iff handle is an active import.
    bool hasBuffer(HardwareBufferHandle handle) const;

    // ---------------------------------------------------------------------------
    // Phase 2O1: Acquire-semaphore pending-state accessors.
    //
    // These are read-only inspection seams for the renderFrame path (Phase 2O2).
    // The semaphore ownership remains with the ImportRecord at all times;
    // only the pending flag is toggled.
    // ---------------------------------------------------------------------------

    // Returns a pointer to the immutable VulkanHardwareBufferImage for handle,
    // or nullptr if handle is not an active import.
    const VulkanHardwareBufferImage* getImage(HardwareBufferHandle handle) const;

    // Returns the VkSemaphore handle (as uint64_t via memcpy) for handle's
    // acquire semaphore if it is pending (acquireSemaphorePending == true),
    // otherwise returns 0.
    // Returning 0 means: no semaphore to wait on (either none was imported, or
    // it has already been submitted).
    uint64_t getPendingAcquireSemaphoreHandle(HardwareBufferHandle handle) const;

    // Marks the acquire semaphore for handle as submitted (sets
    // acquireSemaphorePending = false).
    // Must be called ONLY after vkQueueSubmit returns VK_SUCCESS.
    // Returns false if handle is not active or if the semaphore was not pending.
    // Does NOT take or null out the semaphore handle; destroy() still owns it.
    bool markAcquireSemaphoreSubmitted(HardwareBufferHandle handle);

    // ---------------------------------------------------------------------------
    // Phase 2O2B4: Image layout tracking accessors.
    // ---------------------------------------------------------------------------

    // Returns the current VkImageLayout (as uint32_t) for handle's imported image,
    // or 0 (VK_IMAGE_LAYOUT_UNDEFINED) if handle is invalid.
    uint32_t getImageLayout(HardwareBufferHandle handle) const;

    // Updates the current VkImageLayout for handle's imported image.
    // Must be called ONLY after vkQueueSubmit returns VK_SUCCESS.
    // Returns false if handle is not active.
    bool setImageLayout(HardwareBufferHandle handle, uint32_t newLayout);

private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};

} // namespace render
} // namespace vanguard
