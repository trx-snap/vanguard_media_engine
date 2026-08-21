// vulkan_descriptor_resources.cpp
// Phase 2I: Vulkan descriptor resource and pipeline layout creation/teardown
// for imported AHardwareBuffer images.
//
// Creates exactly:
//   - VkDescriptorSetLayout  binding 0, COMBINED_IMAGE_SAMPLER, immutable sampler
//   - VkPipelineLayout       one set layout, no push constants (Phase 2I)
//   - VkDescriptorPool       one COMBINED_IMAGE_SAMPLER, maxSets 1
//   - VkDescriptorSet        allocated from the pool, written with imageView
//
// Deferred: shader modules, pipeline objects, command buffers, queue submit,
// render pass / framebuffer / dynamic rendering, presentation.

#include "vulkan_descriptor_resources.h"

#if defined(__ANDROID__)

#include <android/log.h>

#define VGLOG_DESC(...) \
    __android_log_print(ANDROID_LOG_DEBUG, "VanguardDescriptorRes", __VA_ARGS__)

namespace vanguard {
namespace render {

HardwareBufferImportResult VulkanDescriptorResources::create(
    VkDevice device,
    VkSampler immutableSampler,
    VkImageView imageView)
{
    // -------------------------------------------------------------------------
    // 0. Defensive guard - reject null handles before touching any Vulkan API.
    // -------------------------------------------------------------------------
    if (device == VK_NULL_HANDLE ||
        immutableSampler == VK_NULL_HANDLE ||
        imageView == VK_NULL_HANDLE) {
        VGLOG_DESC("create: invalid argument - device=%p, "
                   "sampler or imageView is VK_NULL_HANDLE",
                   static_cast<void*>(device));
        return HardwareBufferImportResult::kInvalidArgument;
    }

    // -------------------------------------------------------------------------
    // 1. VkDescriptorSetLayout
    //    Binding 0: COMBINED_IMAGE_SAMPLER, count 1, FRAGMENT|COMPUTE stage,
    //    immutable sampler baked in.
    // -------------------------------------------------------------------------
    VkDescriptorSetLayoutBinding binding{};
    binding.binding            = 0;
    binding.descriptorType     = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
    binding.descriptorCount    = 1;
    binding.stageFlags         = VK_SHADER_STAGE_FRAGMENT_BIT | VK_SHADER_STAGE_COMPUTE_BIT;
    binding.pImmutableSamplers = &immutableSampler;

    VkDescriptorSetLayoutCreateInfo layoutCI{};
    layoutCI.sType        = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO;
    layoutCI.pNext        = nullptr;
    layoutCI.flags        = 0;
    layoutCI.bindingCount = 1;
    layoutCI.pBindings    = &binding;

    VkResult vr = vkCreateDescriptorSetLayout(device, &layoutCI, nullptr,
                                               &descriptorSetLayout);
    if (vr != VK_SUCCESS) {
        VGLOG_DESC("vkCreateDescriptorSetLayout failed: %d",
                   static_cast<int>(vr));
        destroy(device);
        return HardwareBufferImportResult::kVulkanFailure;
    }

    // -------------------------------------------------------------------------
    // 2. VkPipelineLayout (Phase 2I)
    //    One descriptor set layout, no push constants.
    //    Shaders, pipeline objects, command buffers, queue submit,
    //    render pass / framebuffer / dynamic rendering remain deferred.
    // -------------------------------------------------------------------------
    VkPipelineLayoutCreateInfo plCI{};
    plCI.sType                  = VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO;
    plCI.pNext                  = nullptr;
    plCI.flags                  = 0;
    plCI.setLayoutCount         = 1;
    plCI.pSetLayouts            = &descriptorSetLayout;
    plCI.pushConstantRangeCount = 0;
    plCI.pPushConstantRanges    = nullptr;

    vr = vkCreatePipelineLayout(device, &plCI, nullptr, &pipelineLayout);
    if (vr != VK_SUCCESS) {
        VGLOG_DESC("vkCreatePipelineLayout failed: %d",
                   static_cast<int>(vr));
        destroy(device);
        return HardwareBufferImportResult::kVulkanFailure;
    }

    // -------------------------------------------------------------------------
    // 3. VkDescriptorPool
    //    One COMBINED_IMAGE_SAMPLER descriptor, maxSets 1.
    //    No FREE_DESCRIPTOR_SET_BIT: the set is freed by destroying the pool.
    // -------------------------------------------------------------------------
    VkDescriptorPoolSize poolSize{};
    poolSize.type            = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
    poolSize.descriptorCount = 1;

    VkDescriptorPoolCreateInfo poolCI{};
    poolCI.sType         = VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO;
    poolCI.pNext         = nullptr;
    poolCI.flags         = 0; // no FREE_DESCRIPTOR_SET_BIT
    poolCI.maxSets       = 1;
    poolCI.poolSizeCount = 1;
    poolCI.pPoolSizes    = &poolSize;

    vr = vkCreateDescriptorPool(device, &poolCI, nullptr, &descriptorPool);
    if (vr != VK_SUCCESS) {
        VGLOG_DESC("vkCreateDescriptorPool failed: %d",
                   static_cast<int>(vr));
        destroy(device);
        return HardwareBufferImportResult::kVulkanFailure;
    }

    // -------------------------------------------------------------------------
    // 4. VkDescriptorSet allocation
    // -------------------------------------------------------------------------
    VkDescriptorSetAllocateInfo allocInfo{};
    allocInfo.sType              = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO;
    allocInfo.pNext              = nullptr;
    allocInfo.descriptorPool     = descriptorPool;
    allocInfo.descriptorSetCount = 1;
    allocInfo.pSetLayouts        = &descriptorSetLayout;

    vr = vkAllocateDescriptorSets(device, &allocInfo, &descriptorSet);
    if (vr != VK_SUCCESS) {
        VGLOG_DESC("vkAllocateDescriptorSets failed: %d",
                   static_cast<int>(vr));
        destroy(device);
        return HardwareBufferImportResult::kVulkanFailure;
    }

    // -------------------------------------------------------------------------
    // 5. VkWriteDescriptorSet
    //    sampler = VK_NULL_HANDLE because the layout uses an immutable sampler.
    //    imageView = supplied imageView.
    //    imageLayout = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL.
    // -------------------------------------------------------------------------
    VkDescriptorImageInfo imageInfo{};
    imageInfo.sampler     = VK_NULL_HANDLE; // immutable sampler in layout
    imageInfo.imageView   = imageView;
    imageInfo.imageLayout = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;

    VkWriteDescriptorSet write{};
    write.sType            = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
    write.pNext            = nullptr;
    write.dstSet           = descriptorSet;
    write.dstBinding       = 0;
    write.dstArrayElement  = 0;
    write.descriptorCount  = 1;
    write.descriptorType   = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
    write.pImageInfo       = &imageInfo;
    write.pBufferInfo      = nullptr;
    write.pTexelBufferView = nullptr;

    vkUpdateDescriptorSets(device, 1, &write, 0, nullptr);

    return HardwareBufferImportResult::kSuccess;
}

void VulkanDescriptorResources::destroy(VkDevice device)
{
    // Destroying the pool implicitly frees descriptorSet; null it immediately
    // to prevent any attempt at a double-free if called again.
    descriptorSet = VK_NULL_HANDLE;

    if (descriptorPool != VK_NULL_HANDLE) {
        vkDestroyDescriptorPool(device, descriptorPool, nullptr);
        descriptorPool = VK_NULL_HANDLE;
    }
    // pipelineLayout must be destroyed before descriptorSetLayout because the
    // layout was used to create it. Both are safe to destroy after the pool
    // (which only references descriptorSetLayout indirectly via the set).
    if (pipelineLayout != VK_NULL_HANDLE) {
        vkDestroyPipelineLayout(device, pipelineLayout, nullptr);
        pipelineLayout = VK_NULL_HANDLE;
    }
    if (descriptorSetLayout != VK_NULL_HANDLE) {
        vkDestroyDescriptorSetLayout(device, descriptorSetLayout, nullptr);
        descriptorSetLayout = VK_NULL_HANDLE;
    }
}

} // namespace render
} // namespace vanguard

#else // !__ANDROID__

namespace vanguard {
namespace render {
// Stubs for host build
} // namespace render
} // namespace vanguard

#endif // __ANDROID__
