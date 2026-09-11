// vulkan_descriptor_resources.h
// Phase 2I: Private helper - VulkanDescriptorResources.
//
// Owns the descriptor-set and pipeline-layout resources required to bind a
// single AHardwareBuffer-imported image for sampling in the fragment shader:
//   - VkDescriptorSetLayout  (binding 0, COMBINED_IMAGE_SAMPLER, immutable)
//   - VkDescriptorPool       (one descriptor, maxSets 1)
//   - VkDescriptorSet        (written with the imageView; freed with the pool)
//   - VkPipelineLayout       (one set layout, Phase 4B2C: vertex push constants,
//                             extended Phase 10: fragment color-matrix push constants)
//
// Phase 4B2C: VkPushConstantRange for VideoTransformPushConstants (32 bytes,
// VK_SHADER_STAGE_VERTEX_BIT) added to pipeline layout. Phase 10: widened to
// VideoTransformFullPushConstants (112 bytes, VK_SHADER_STAGE_VERTEX_BIT |
// VK_SHADER_STAGE_FRAGMENT_BIT) so the fragment stage can also read its
// color-matrix half of the same combined push-constant block.
//
// Deferred to later phases: shader modules, pipeline objects, command buffers,
// queue submit, render pass / framebuffer / dynamic rendering, presentation.
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

// Builds descriptorSetLayout (binding 0, COMBINED_IMAGE_SAMPLER, immutable
// sampler baked in) and pipelineLayout (one set layout + the video-transform
// push-constant range) from immutableSampler alone, with no descriptor pool,
// set, or imageView involved.
//
// Used by VulkanHardwareBufferImports::Impl to build the session/import-table
// -scoped shared layout objects that multiple per-import
// VulkanDescriptorResources instances subsequently bind against via
// createWithSharedLayout(), instead of every import creating its own
// descriptorSetLayout/pipelineLayout (the per-frame churn that causes
// VulkanFrameRenderer's pipeline-layout mismatch check to fire every frame).
//
// On any failure all partially created objects are destroyed and both
// outputs are set to VK_NULL_HANDLE.
HardwareBufferImportResult CreateSharedDescriptorLayouts(
    VkDevice device,
    VkSampler immutableSampler,
    VkDescriptorSetLayout* outSetLayout,
    VkPipelineLayout* outPipelineLayout);

struct VulkanDescriptorResources {
    VkDescriptorSetLayout descriptorSetLayout = VK_NULL_HANDLE;
    VkDescriptorPool      descriptorPool      = VK_NULL_HANDLE;
    VkDescriptorSet       descriptorSet       = VK_NULL_HANDLE;
    VkPipelineLayout      pipelineLayout      = VK_NULL_HANDLE;

    // True when descriptorSetLayout/pipelineLayout are owned by this instance
    // (created via create()) and must be destroyed by destroy(). False when
    // they were borrowed from a shared cache via createWithSharedLayout(); in
    // that case destroy() must leave them untouched since other imports and
    // the shared cache itself are still using the same handles.
    bool ownsLayouts = true;

    VulkanDescriptorResources() = default;

    // Move-only: raw Vulkan handles must not be copied.
    VulkanDescriptorResources(const VulkanDescriptorResources&) = delete;
    VulkanDescriptorResources& operator=(const VulkanDescriptorResources&) = delete;

    VulkanDescriptorResources(VulkanDescriptorResources&& other) noexcept
        : descriptorSetLayout(other.descriptorSetLayout),
          descriptorPool(other.descriptorPool),
          descriptorSet(other.descriptorSet),
          pipelineLayout(other.pipelineLayout),
          ownsLayouts(other.ownsLayouts) {
        other.descriptorSetLayout = VK_NULL_HANDLE;
        other.descriptorPool      = VK_NULL_HANDLE;
        other.descriptorSet       = VK_NULL_HANDLE;
        other.pipelineLayout      = VK_NULL_HANDLE;
        other.ownsLayouts         = true;
    }

    VulkanDescriptorResources& operator=(VulkanDescriptorResources&& other) noexcept {
        if (this != &other) {
            descriptorSetLayout = other.descriptorSetLayout;
            descriptorPool      = other.descriptorPool;
            descriptorSet       = other.descriptorSet;
            pipelineLayout      = other.pipelineLayout;
            ownsLayouts         = other.ownsLayouts;

            other.descriptorSetLayout = VK_NULL_HANDLE;
            other.descriptorPool      = VK_NULL_HANDLE;
            other.descriptorSet       = VK_NULL_HANDLE;
            other.pipelineLayout      = VK_NULL_HANDLE;
            other.ownsLayouts         = true;
        }
        return *this;
    }

    // Creates descriptorSetLayout, descriptorPool, descriptorSet, and
    // pipelineLayout (Phase 2I), then writes imageView into binding 0 using
    // VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL.
    // The supplied immutableSampler is baked into the layout at binding 0;
    // consequently the VkWriteDescriptorSet uses sampler = VK_NULL_HANDLE.
    // On any failure all partially created resources are destroyed and
    // kVulkanFailure is returned. ownsLayouts is true after success.
    HardwareBufferImportResult create(VkDevice device,
                                      VkSampler immutableSampler,
                                      VkImageView imageView);

    // Shared-layout path: borrows an existing descriptorSetLayout and
    // pipelineLayout (created via CreateSharedDescriptorLayouts and owned by
    // a shared cache) and creates only descriptorPool, descriptorSet, and the
    // descriptor write for imageView. sampler = VK_NULL_HANDLE in the write
    // because the immutable sampler is already baked into sharedSetLayout.
    // ownsLayouts is set to false immediately so destroy() never destroys the
    // borrowed layout objects, even on a partial-failure cleanup path.
    // On any failure the owned descriptorPool/descriptorSet are destroyed and
    // kVulkanFailure is returned; sharedSetLayout/sharedPipelineLayout are
    // never touched.
    HardwareBufferImportResult createWithSharedLayout(
        VkDevice device,
        VkDescriptorSetLayout sharedSetLayout,
        VkPipelineLayout sharedPipelineLayout,
        VkImageView imageView);

    // Destroys descriptorPool (which implicitly frees descriptorSet).
    // Destroys pipelineLayout and descriptorSetLayout only when ownsLayouts
    // is true; when false (shared-layout path) those handles are simply
    // cleared without being destroyed, since a shared cache or other imports
    // still reference them.
    // Sets all handles to VK_NULL_HANDLE and ownsLayouts back to true.
    // Idempotent (null-handle guards).
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
