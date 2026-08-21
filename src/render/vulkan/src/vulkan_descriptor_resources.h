// vulkan_descriptor_resources.h
// Phase 2H: Private helper - VulkanDescriptorResources.
//
// Owns the descriptor-set resources required to bind a single
// AHardwareBuffer-imported image for sampling in the fragment shader:
//   - VkDescriptorSetLayout  (binding 0, COMBINED_IMAGE_SAMPLER, immutable)
//   - VkDescriptorPool       (one descriptor, maxSets 1)
//   - VkDescriptorSet        (written with the imageView; freed with the pool)
//
// VkPipelineLayout is deliberately excluded; it is deferred until the
// shader/pipeline interface exists (Phase 2I+).
//
// Confined to the private Vulkan render backend implementation.

#pragma once

#include "vanguard/render/hardware_buffer_import.h"

#if defined(__ANDROID__)

#ifndef VK_USE_PLATFORM_ANDROID_KHR
#define VK_USE_PLATFORM_ANDROID_KHR
#endif

#include <vulkan/vulkan.h>

namespace vanguard {
namespace render {

struct VulkanDescriptorResources {
    VkDescriptorSetLayout descriptorSetLayout = VK_NULL_HANDLE;
    VkDescriptorPool      descriptorPool      = VK_NULL_HANDLE;
    VkDescriptorSet       descriptorSet       = VK_NULL_HANDLE;

    VulkanDescriptorResources() = default;

    // Move-only: raw Vulkan handles must not be copied.
    VulkanDescriptorResources(const VulkanDescriptorResources&) = delete;
    VulkanDescriptorResources& operator=(const VulkanDescriptorResources&) = delete;

    VulkanDescriptorResources(VulkanDescriptorResources&& other) noexcept
        : descriptorSetLayout(other.descriptorSetLayout),
          descriptorPool(other.descriptorPool),
          descriptorSet(other.descriptorSet) {
        other.descriptorSetLayout = VK_NULL_HANDLE;
        other.descriptorPool      = VK_NULL_HANDLE;
        other.descriptorSet       = VK_NULL_HANDLE;
    }

    VulkanDescriptorResources& operator=(VulkanDescriptorResources&& other) noexcept {
        if (this != &other) {
            descriptorSetLayout = other.descriptorSetLayout;
            descriptorPool      = other.descriptorPool;
            descriptorSet       = other.descriptorSet;

            other.descriptorSetLayout = VK_NULL_HANDLE;
            other.descriptorPool      = VK_NULL_HANDLE;
            other.descriptorSet       = VK_NULL_HANDLE;
        }
        return *this;
    }

    // Creates descriptorSetLayout, descriptorPool, and descriptorSet, then
    // writes imageView into binding 0 using VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL.
    // The supplied immutableSampler is baked into the layout at binding 0;
    // consequently the VkWriteDescriptorSet uses sampler = VK_NULL_HANDLE.
    // On any failure all partially created resources are destroyed and
    // kVulkanFailure is returned.
    HardwareBufferImportResult create(VkDevice device,
                                      VkSampler immutableSampler,
                                      VkImageView imageView);

    // Destroys descriptorPool (which implicitly frees descriptorSet) then
    // destroys descriptorSetLayout. Sets all handles to VK_NULL_HANDLE.
    void destroy(VkDevice device);
};

} // namespace render
} // namespace vanguard

#else // !__ANDROID__

namespace vanguard {
namespace render {

// Minimal dummy struct for host builds.
struct VulkanDescriptorResources {};

} // namespace render
} // namespace vanguard

#endif // __ANDROID__
