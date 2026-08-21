// vulkan_hardware_buffer_image.h
// Phase 2E: Private helper - VulkanHardwareBufferImage.
//
// Owns and encapsulates the creation and destruction of Vulkan sampling resources
// for an imported AHardwareBuffer:
//   - VkImage (with external memory info and optional external format)
//   - VkDeviceMemory (dedicated import of AHardwareBuffer)
//   - VkSamplerYcbcrConversion (for external format images)
//   - VkImageView (2D or 2D_ARRAY; chained with YCbCr conversion if external)
//   - VkSampler (chained with YCbCr conversion if external)
//
// Confined to the private Vulkan render backend implementation.

#pragma once

#include "vanguard/render/hardware_buffer_import.h"
#include <cstdint>

#if defined(__ANDROID__)

#ifndef VK_USE_PLATFORM_ANDROID_KHR
#define VK_USE_PLATFORM_ANDROID_KHR
#endif

#include <vulkan/vulkan.h>
#include <android/hardware_buffer.h>

namespace vanguard {
namespace render {

struct VulkanHardwareBufferImage {
    VkImage                  image            = VK_NULL_HANDLE;
    VkDeviceMemory           memory           = VK_NULL_HANDLE;
    VkSamplerYcbcrConversion ycbcrConversion  = VK_NULL_HANDLE;
    VkImageView              imageView        = VK_NULL_HANDLE;
    VkSampler                sampler          = VK_NULL_HANDLE;

    // Cached format state.
    VkFormat                 cachedFormat         = VK_FORMAT_UNDEFINED;
    uint64_t                 cachedExternalFormat = 0;
    uint32_t                 cachedLayerCount     = 1; // Phase 2F

    VulkanHardwareBufferImage() = default;

    // Move-only: raw Vulkan handles must not be copied.
    VulkanHardwareBufferImage(const VulkanHardwareBufferImage&) = delete;
    VulkanHardwareBufferImage& operator=(const VulkanHardwareBufferImage&) = delete;

    VulkanHardwareBufferImage(VulkanHardwareBufferImage&& other) noexcept
        : image(other.image),
          memory(other.memory),
          ycbcrConversion(other.ycbcrConversion),
          imageView(other.imageView),
          sampler(other.sampler),
          cachedFormat(other.cachedFormat),
          cachedExternalFormat(other.cachedExternalFormat),
          cachedLayerCount(other.cachedLayerCount) {
        other.image = VK_NULL_HANDLE;
        other.memory = VK_NULL_HANDLE;
        other.ycbcrConversion = VK_NULL_HANDLE;
        other.imageView = VK_NULL_HANDLE;
        other.sampler = VK_NULL_HANDLE;
        other.cachedFormat = VK_FORMAT_UNDEFINED;
        other.cachedExternalFormat = 0;
        other.cachedLayerCount = 1;
    }

    VulkanHardwareBufferImage& operator=(VulkanHardwareBufferImage&& other) noexcept {
        if (this != &other) {
            image = other.image;
            memory = other.memory;
            ycbcrConversion = other.ycbcrConversion;
            imageView = other.imageView;
            sampler = other.sampler;
            cachedFormat = other.cachedFormat;
            cachedExternalFormat = other.cachedExternalFormat;
            cachedLayerCount = other.cachedLayerCount;

            other.image = VK_NULL_HANDLE;
            other.memory = VK_NULL_HANDLE;
            other.ycbcrConversion = VK_NULL_HANDLE;
            other.imageView = VK_NULL_HANDLE;
            other.sampler = VK_NULL_HANDLE;
            other.cachedFormat = VK_FORMAT_UNDEFINED;
            other.cachedExternalFormat = 0;
            other.cachedLayerCount = 1;
        }
        return *this;
    }

    bool isExternalFormat() const {
        return cachedFormat == VK_FORMAT_UNDEFINED;
    }

    bool hasYcbcrConversion() const {
        return ycbcrConversion != VK_NULL_HANDLE;
    }

    // Creates the VkImage, binds imported VkDeviceMemory, and creates
    // VkSamplerYcbcrConversion (if external format), VkImageView, and VkSampler.
    // On any failure, all partially created Vulkan resources are destroyed in
    // strict Phase 2D teardown order and an appropriate error code is returned.
    HardwareBufferImportResult create(
        VkDevice device,
        VkPhysicalDevice physDev,
        AHardwareBuffer* ahbRef,
        const AHardwareBuffer_Desc& desc,
        PFN_vkGetAndroidHardwareBufferPropertiesANDROID fnGetAHBProps,
        PFN_vkCreateSamplerYcbcrConversion fnCreateYcbcr,
        PFN_vkDestroySamplerYcbcrConversion fnDestroyYcbcr);

    // Destroys all owned Vulkan resources in Phase 2D teardown order:
    //   vkDestroySampler -> vkDestroyImageView -> vkDestroySamplerYcbcrConversion
    //   -> vkDestroyImage -> vkFreeMemory
    void destroy(
        VkDevice device,
        PFN_vkDestroySamplerYcbcrConversion fnDestroyYcbcr);

    // Phase 2F: Records a pipeline-barrier image-layout transition into an
    // already-recording command buffer.  Does NOT submit the command buffer.
    // - Returns immediately if commandBuffer or image is VK_NULL_HANDLE.
    // - For external-format images, only UNDEFINED -> SHADER_READ_ONLY_OPTIMAL
    //   is permitted; any other layout pair is silently ignored.
    void recordLayoutTransition(
        VkCommandBuffer commandBuffer,
        VkImageLayout oldLayout,
        VkImageLayout newLayout,
        VkPipelineStageFlags srcStageMask,
        VkPipelineStageFlags dstStageMask,
        VkAccessFlags srcAccessMask,
        VkAccessFlags dstAccessMask,
        uint32_t srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
        uint32_t dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED) const;
};

} // namespace render
} // namespace vanguard

#else // !__ANDROID__

namespace vanguard {
namespace render {

// Minimal dummy struct for host builds.
struct VulkanHardwareBufferImage {
    bool isExternalFormat() const { return false; }
    bool hasYcbcrConversion() const { return false; }
};

} // namespace render
} // namespace vanguard

#endif // __ANDROID__
