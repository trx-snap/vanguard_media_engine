// vulkan_hardware_buffer_imports.h
// Phase 2D: Private helper - VulkanHardwareBufferImports.
//
// Owns the AHardwareBuffer->Vulkan import table including Phase 2D sampling
// resources (VkSamplerYcbcrConversion, VkImageView, VkSampler).
// All Vulkan and Android headers are confined to the .cpp translation unit;
// this header includes only <cstdint>, <memory>, and the public shared opaque
// types.
//
// Void* handles passed to import() are AHardwareBuffer* cast by the caller
// (VulkanBackend::Impl).  The helper casts them back inside the .cpp.
//
// AHardwareBuffer symbols are loaded at runtime via dlopen/dlsym from
// libandroid.so.  vkGetAndroidHardwareBufferPropertiesANDROID,
// vkCreateSamplerYcbcrConversion, and vkDestroySamplerYcbcrConversion are
// loaded via vkGetDeviceProcAddr.  No strong references to AHardwareBuffer_*
// or to Android/Vulkan extension structs appear in this header.

#pragma once
#include "vanguard/render/hardware_buffer_import.h"
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
    // including Phase 2D vkCreateSamplerYcbcrConversion /
    // vkDestroySamplerYcbcrConversion entry points.
    bool initialize(void* deviceHandle, void* physDevHandle);

    // Idempotent teardown.  Destroys all import records (VkSampler, VkImageView,
    // VkSamplerYcbcrConversion, VkImage, VkDeviceMemory, AHB refs, stored fds)
    // in Phase 2D teardown order before the caller destroys VkDevice.
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
    // Destroys sampling resources in Phase 2D teardown order.
    // outReleaseFenceFd - optional; set to -1 if non-null.
    HardwareBufferImportResult releaseBuffer(
        HardwareBufferHandle handle,
        int* outReleaseFenceFd);

    // Returns true iff handle is an active import.
    bool hasBuffer(HardwareBufferHandle handle) const;

private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};

} // namespace render
} // namespace vanguard
