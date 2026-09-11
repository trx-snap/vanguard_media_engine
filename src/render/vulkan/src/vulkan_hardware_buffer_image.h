// vulkan_hardware_buffer_image.h
// Phase 2E/2G/2H/2I/2O1: Private helper - VulkanHardwareBufferImage.
//
// Owns and encapsulates the creation and destruction of Vulkan sampling resources
// for an imported AHardwareBuffer:
//   - VkImage (with external memory info and optional external format)
//   - VkDeviceMemory (dedicated import of AHardwareBuffer)
//   - VkSamplerYcbcrConversion (for external format images)
//   - VkImageView (2D or 2D_ARRAY; chained with YCbCr conversion if external)
//   - VkSampler (chained with YCbCr conversion if external)
//   - VulkanDescriptorResources (Phase 2H/2I: set layout/pool/set/pipelineLayout)
//
// Confined to the private Vulkan render backend implementation.

#pragma once

#include "vanguard/render/hardware_buffer_import.h"
#include <cstdint>
#include <utility>

#if defined(__ANDROID__)

#ifndef VK_USE_PLATFORM_ANDROID_KHR
#define VK_USE_PLATFORM_ANDROID_KHR
#endif

#include <vulkan/vulkan.h>
#include <android/hardware_buffer.h>
#include "vulkan_descriptor_resources.h"

namespace vanguard {
namespace render {

// Session/import-table-scoped shared external-format sampling resources.
// Owned by VulkanHardwareBufferImports::Impl's shared resource cache, keyed
// by the external-format conversion parameters (resolved image format /
// externalFormat, suggested YCbCr model/range/components, chroma offsets,
// and layer count). Every VulkanHardwareBufferImage import whose AHB probes
// to an identical key borrows these same four Vulkan objects instead of
// creating its own, so frames sharing a conversion configuration also share
// one VkPipelineLayout and stop causing per-frame pipeline-layout churn in
// VulkanFrameRenderer.
//
// Outlives every per-import VulkanHardwareBufferImage that borrows it;
// destroyed only at VulkanHardwareBufferImports::shutdown(), after all
// active and retired import records have already been destroyed.
struct VulkanSharedExternalSampling {
    VkSamplerYcbcrConversion conversion          = VK_NULL_HANDLE;
    VkSampler                sampler             = VK_NULL_HANDLE;
    VkDescriptorSetLayout    descriptorSetLayout = VK_NULL_HANDLE;
    VkPipelineLayout         pipelineLayout      = VK_NULL_HANDLE;
};

// Builds a VkSamplerYcbcrConversion and matching VkSampler from the given
// external-format Android hardware buffer format properties.
//
// Used by VulkanHardwareBufferImports::Impl to build a
// VulkanSharedExternalSampling cache entry for a given conversion key. The
// per-import, non-shared path in VulkanHardwareBufferImage::create() keeps
// its own inline conversion/sampler creation unchanged for imports that do
// not use a shared cache entry.
//
// On any failure any partially created object is destroyed (via
// fnDestroyYcbcr for the conversion) and both outputs are set to
// VK_NULL_HANDLE.
HardwareBufferImportResult CreateExternalYcbcrConversionAndSampler(
    VkDevice device,
    PFN_vkCreateSamplerYcbcrConversion fnCreateYcbcr,
    PFN_vkDestroySamplerYcbcrConversion fnDestroyYcbcr,
    const VkAndroidHardwareBufferFormatPropertiesANDROID& fmtProps,
    VkSamplerYcbcrConversion* outConversion,
    VkSampler* outSampler);

struct VulkanHardwareBufferImage {
    VkImage                  image            = VK_NULL_HANDLE;
    VkDeviceMemory           memory           = VK_NULL_HANDLE;
    VkSamplerYcbcrConversion ycbcrConversion  = VK_NULL_HANDLE;
    VkImageView              imageView        = VK_NULL_HANDLE;
    VkSampler                sampler          = VK_NULL_HANDLE;

    // Phase 2G: Binary semaphore imported from the AHardwareBuffer acquire-fence
    // sync-fd.  VK_NULL_HANDLE when acquireFenceFd was -1 (no pending wait).
    // The DAG queue submit will wait on this semaphore before recording the layout
    // transition and sampling draw.  vkDestroySemaphore is called in destroy().
    VkSemaphore              acquireSemaphore = VK_NULL_HANDLE;

    // Phase 2O1: true when acquireSemaphore is non-null AND has not yet been
    // submitted as a wait semaphore in a vkQueueSubmit call.
    // Phase 2O2 sets this to false (via markAcquireSemaphoreSubmitted) ONLY
    // after vkQueueSubmit returns VK_SUCCESS.  If submit fails the flag remains
    // true so the semaphore can be re-presented as a wait on retry.
    // destroy() destroys the semaphore handle regardless of this flag.
    bool                     acquireSemaphorePending = false;

    // Phase 2O2B4: Track current VkImageLayout across multiple render passes.
    // Initialized to VK_IMAGE_LAYOUT_UNDEFINED upon import, updated to
    // VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL after the first successful submit.
    VkImageLayout            currentLayout           = VK_IMAGE_LAYOUT_UNDEFINED;

    // Cached format state.
    VkFormat                 cachedFormat         = VK_FORMAT_UNDEFINED;
    uint64_t                 cachedExternalFormat = 0;
    uint32_t                 cachedLayerCount     = 1; // Phase 2F

    // Phase 2H/2I: Descriptor-set and pipeline-layout resources for sampling
    // this image in the fragment shader. Lives alongside sampler/imageView
    // because all three are per-import/per-conversion resources in the current
    // architecture.
    VulkanDescriptorResources descriptorResources;

    // True when ycbcrConversion / sampler were borrowed from a
    // VulkanSharedExternalSampling cache entry (shared-layout path) rather
    // than created and owned by this import. When true, destroy() must not
    // call fnDestroyYcbcr / vkDestroySampler on them; the shared cache (or
    // another import still using the same handles) owns that lifetime.
    bool ycbcrConversionBorrowed = false;
    bool samplerBorrowed         = false;

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
          acquireSemaphore(other.acquireSemaphore),
          acquireSemaphorePending(other.acquireSemaphorePending),
          currentLayout(other.currentLayout),
          cachedFormat(other.cachedFormat),
          cachedExternalFormat(other.cachedExternalFormat),
          cachedLayerCount(other.cachedLayerCount),
          descriptorResources(std::move(other.descriptorResources)),
          ycbcrConversionBorrowed(other.ycbcrConversionBorrowed),
          samplerBorrowed(other.samplerBorrowed) {
        other.image = VK_NULL_HANDLE;
        other.memory = VK_NULL_HANDLE;
        other.ycbcrConversion = VK_NULL_HANDLE;
        other.imageView = VK_NULL_HANDLE;
        other.sampler = VK_NULL_HANDLE;
        other.acquireSemaphore = VK_NULL_HANDLE;
        other.acquireSemaphorePending = false;
        other.currentLayout = VK_IMAGE_LAYOUT_UNDEFINED;
        other.cachedFormat = VK_FORMAT_UNDEFINED;
        other.cachedExternalFormat = 0;
        other.cachedLayerCount = 1;
        other.ycbcrConversionBorrowed = false;
        other.samplerBorrowed = false;
    }

    VulkanHardwareBufferImage& operator=(VulkanHardwareBufferImage&& other) noexcept {
        if (this != &other) {
            image = other.image;
            memory = other.memory;
            ycbcrConversion = other.ycbcrConversion;
            imageView = other.imageView;
            sampler = other.sampler;
            acquireSemaphore = other.acquireSemaphore;
            acquireSemaphorePending = other.acquireSemaphorePending;
            currentLayout = other.currentLayout;
            cachedFormat = other.cachedFormat;
            cachedExternalFormat = other.cachedExternalFormat;
            cachedLayerCount = other.cachedLayerCount;
            descriptorResources = std::move(other.descriptorResources);
            ycbcrConversionBorrowed = other.ycbcrConversionBorrowed;
            samplerBorrowed = other.samplerBorrowed;

            other.image = VK_NULL_HANDLE;
            other.memory = VK_NULL_HANDLE;
            other.ycbcrConversion = VK_NULL_HANDLE;
            other.imageView = VK_NULL_HANDLE;
            other.sampler = VK_NULL_HANDLE;
            other.acquireSemaphore = VK_NULL_HANDLE;
            other.acquireSemaphorePending = false;
            other.currentLayout = VK_IMAGE_LAYOUT_UNDEFINED;
            other.cachedFormat = VK_FORMAT_UNDEFINED;
            other.cachedExternalFormat = 0;
            other.cachedLayerCount = 1;
            other.ycbcrConversionBorrowed = false;
            other.samplerBorrowed = false;
        }
        return *this;
    }

    bool isExternalFormat() const {
        return cachedFormat == VK_FORMAT_UNDEFINED;
    }

    bool hasYcbcrConversion() const {
        return ycbcrConversion != VK_NULL_HANDLE;
    }

    // Phase 2G: Returns the imported acquire-fence semaphore, or VK_NULL_HANDLE
    // if no fence was pending (acquireFenceFd was -1).
    // The DAG queue submit uses this to wait before the layout transition + draw.
    VkSemaphore getAcquireSemaphore() const {
        return acquireSemaphore;
    }

    // Creates the VkImage, binds imported VkDeviceMemory, and creates
    // VkSamplerYcbcrConversion (if external format), VkImageView, and VkSampler.
    // On any failure, all partially created Vulkan resources are destroyed in
    // strict Phase 2D teardown order and an appropriate error code is returned.
    //
    // sharedExternal: optional. When non-null AND this buffer resolves to an
    // external format, the supplied VkSamplerYcbcrConversion is used for
    // VkImageView creation, the supplied VkSampler is used for descriptor
    // resources (via VulkanDescriptorResources::createWithSharedLayout), and
    // neither is destroyed by destroy() (ycbcrConversionBorrowed/
    // samplerBorrowed are set to true). When null, or when the buffer is not
    // external format, behavior is unchanged: this import creates and owns
    // its own conversion, sampler, and descriptor/pipeline layout objects.
    HardwareBufferImportResult create(
        VkDevice device,
        VkPhysicalDevice physDev,
        AHardwareBuffer* ahbRef,
        const AHardwareBuffer_Desc& desc,
        PFN_vkGetAndroidHardwareBufferPropertiesANDROID fnGetAHBProps,
        PFN_vkCreateSamplerYcbcrConversion fnCreateYcbcr,
        PFN_vkDestroySamplerYcbcrConversion fnDestroyYcbcr,
        const VulkanSharedExternalSampling* sharedExternal = nullptr);

    // Destroys all owned Vulkan resources in teardown order:
    //   vkDestroySemaphore (acquireSemaphore, Phase 2G)
    //   -> vkDestroySampler -> vkDestroyImageView
    //   -> vkDestroySamplerYcbcrConversion
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
    bool acquireSemaphorePending = false; // Phase 2O1: always false on host.
    uint32_t currentLayout = 0;           // Phase 2O2B4: current layout tracking on host.
    bool isExternalFormat() const { return false; }
    bool hasYcbcrConversion() const { return false; }
};

} // namespace render
} // namespace vanguard

#endif // __ANDROID__
