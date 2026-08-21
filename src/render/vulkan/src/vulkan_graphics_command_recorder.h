// vulkan_graphics_command_recorder.h
// Phase 2M: Vulkan Graphics Command Recording Foundation.
//
// VulkanGraphicsCommandRecorder is a private, stateless helper class with
// static methods only. Emits graphics command sequences into a caller-supplied
// VkCommandBuffer for rasterization passes.
//
// NOTE: Compute pipeline remains deferred: compute pipeline still requires
// storage output target plus descriptor/pipeline layout expansion.

#pragma once

#include <cstdint>

#if defined(__ANDROID__)
#ifndef VK_USE_PLATFORM_ANDROID_KHR
#define VK_USE_PLATFORM_ANDROID_KHR
#endif
#include <vulkan/vulkan.h>
#include "vulkan_hardware_buffer_image.h"
#else
namespace vanguard {
namespace render {
struct VulkanHardwareBufferImage;
} // namespace render
} // namespace vanguard
#endif

namespace vanguard {
namespace render {

struct VulkanGraphicsPassParams {
#if defined(__ANDROID__)
    VkCommandBuffer commandBuffer = VK_NULL_HANDLE;
    VkRenderPass renderPass = VK_NULL_HANDLE;
    VkFramebuffer framebuffer = VK_NULL_HANDLE;
    uint32_t extentWidth = 0;
    uint32_t extentHeight = 0;
    VkPipelineLayout pipelineLayout = VK_NULL_HANDLE;
    VkDescriptorSet descriptorSet = VK_NULL_HANDLE;
    VkPipeline pipeline = VK_NULL_HANDLE;
    VkClearColorValue clearColor = {{0.0f, 0.0f, 0.0f, 1.0f}};
    bool transitionSourceImage = false;
    const VulkanHardwareBufferImage* sourceImage = nullptr;
    VkImageLayout sourceOldLayout = VK_IMAGE_LAYOUT_UNDEFINED;
    VkImageLayout sourceNewLayout = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
    VkPipelineStageFlags srcStageMask = VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT;
    VkPipelineStageFlags dstStageMask = VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT;
    VkAccessFlags srcAccessMask = 0;
    VkAccessFlags dstAccessMask = VK_ACCESS_SHADER_READ_BIT;
    uint32_t srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
    uint32_t dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
#else
    void* commandBuffer = nullptr;
    void* renderPass = nullptr;
    void* framebuffer = nullptr;
    uint32_t extentWidth = 0;
    uint32_t extentHeight = 0;
    void* pipelineLayout = nullptr;
    void* descriptorSet = nullptr;
    void* pipeline = nullptr;
    float clearColor[4] = {0.0f, 0.0f, 0.0f, 1.0f};
    bool transitionSourceImage = false;
    const VulkanHardwareBufferImage* sourceImage = nullptr;
    uint32_t sourceOldLayout = 0;
    uint32_t sourceNewLayout = 0;
    uint32_t srcStageMask = 0;
    uint32_t dstStageMask = 0;
    uint32_t srcAccessMask = 0;
    uint32_t dstAccessMask = 0;
    uint32_t srcQueueFamilyIndex = (~0U);
    uint32_t dstQueueFamilyIndex = (~0U);
#endif
};

class VulkanGraphicsCommandRecorder {
public:
    VulkanGraphicsCommandRecorder() = delete;
    ~VulkanGraphicsCommandRecorder() = delete;
    VulkanGraphicsCommandRecorder(const VulkanGraphicsCommandRecorder&) = delete;
    VulkanGraphicsCommandRecorder& operator=(const VulkanGraphicsCommandRecorder&) = delete;

    static bool recordGraphicsPass(const VulkanGraphicsPassParams& params);
    static bool recordCompletePass(
        const VulkanGraphicsPassParams& params,
#if defined(__ANDROID__)
        VkCommandBufferUsageFlags flags = 0
#else
        uint32_t flags = 0
#endif
    );
};

} // namespace render
} // namespace vanguard
