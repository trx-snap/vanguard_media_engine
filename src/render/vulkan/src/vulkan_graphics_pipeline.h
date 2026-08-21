// vulkan_graphics_pipeline.h
// Phase 2L: Vulkan Graphics Pipeline Foundation.
//
// VulkanGraphicsPipeline is a private move-only RAII helper class managing
// the lifecycle of a single VkPipeline object for graphics rasterization.
//
// Destructor does not call Vulkan because VkDevice is externally owned.
// Callers must explicitly call destroy(device) before destruction.
//
// NOTE: Compute pipeline remains deferred: no compute pipeline is created
// because the current compute shader lacks a storage output target and requires
// descriptor set and pipeline layout expansion.

#pragma once

#include <cstdint>

#if defined(__ANDROID__)
#ifndef VK_USE_PLATFORM_ANDROID_KHR
#define VK_USE_PLATFORM_ANDROID_KHR
#endif
#include <vulkan/vulkan.h>
#endif

namespace vanguard {
namespace render {

class VulkanGraphicsPipeline {
public:
    VulkanGraphicsPipeline() = default;
    ~VulkanGraphicsPipeline() = default;

    // Non-copyable.
    VulkanGraphicsPipeline(const VulkanGraphicsPipeline&) = delete;
    VulkanGraphicsPipeline& operator=(const VulkanGraphicsPipeline&) = delete;

    // Move constructor and move assignment.
    VulkanGraphicsPipeline(VulkanGraphicsPipeline&& other) noexcept;
    VulkanGraphicsPipeline& operator=(VulkanGraphicsPipeline&& other) noexcept;

    // Creates the graphics pipeline for Vulkan 1.1.
    // If already valid, destroys the existing pipeline first using the stored device.
    // Validates all handles are non-null.
    // On failure logs VkResult, ensures handle remains VK_NULL_HANDLE, and returns false.
    bool create(
#if defined(__ANDROID__)
        VkDevice device,
        VkPipelineLayout pipelineLayout,
        VkRenderPass renderPass,
        VkShaderModule vertShader,
        VkShaderModule fragShader
#else
        void* device,
        void* pipelineLayout,
        void* renderPass,
        void* vertShader,
        void* fragShader
#endif
    );

    // Destroys the pipeline. Idempotent and nulls the internal handle.
    void destroy(
#if defined(__ANDROID__)
        VkDevice device = VK_NULL_HANDLE
#else
        void* device = nullptr
#endif
    );

    // Returns true if a valid pipeline handle is held.
    bool isValid() const;

    // Returns the VkPipeline handle converted to uint64_t via memcpy (safe for 32-bit and 64-bit).
    uint64_t getPipelineHandle() const;

#if defined(__ANDROID__)
    // Returns raw VkPipeline handle (Android only).
    VkPipeline get() const { return pipeline_; }
#endif

private:
#if defined(__ANDROID__)
    VkDevice device_ = VK_NULL_HANDLE;
    VkPipeline pipeline_ = VK_NULL_HANDLE;
#else
    void* device_ = nullptr;
    void* pipeline_ = nullptr;
#endif
};

} // namespace render
} // namespace vanguard
