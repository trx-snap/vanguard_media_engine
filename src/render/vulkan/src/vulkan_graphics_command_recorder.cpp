// vulkan_graphics_command_recorder.cpp
// Phase 2M: Vulkan Graphics Command Recording Foundation.
//
// On Android (__ANDROID__):
//   Stateless helper that records graphics render-pass commands into a
//   caller-supplied VkCommandBuffer for fullscreen rasterization passes.
//
// On non-Android host builds:
//   Provides safe stubs compiling cleanly without the Vulkan SDK.
//
// NOTE: Compute pipeline remains deferred: compute pipeline still requires
// storage output target plus descriptor/pipeline layout expansion.

#include "vulkan_graphics_command_recorder.h"

#if defined(__ANDROID__)

#include <android/log.h>

#define VGLOG_CR(...) \
    __android_log_print(ANDROID_LOG_ERROR, "VanguardGraphicsCommandRecorder", __VA_ARGS__)

namespace vanguard {
namespace render {

namespace {

// Validates all required handles and parameters before recording.
static bool validateGraphicsPassParams(const VulkanGraphicsPassParams& params) {
    if (params.commandBuffer == VK_NULL_HANDLE) {
        VGLOG_CR("Validation failed: commandBuffer is VK_NULL_HANDLE");
        return false;
    }
    if (params.renderPass == VK_NULL_HANDLE) {
        VGLOG_CR("Validation failed: renderPass is VK_NULL_HANDLE");
        return false;
    }
    if (params.framebuffer == VK_NULL_HANDLE) {
        VGLOG_CR("Validation failed: framebuffer is VK_NULL_HANDLE");
        return false;
    }
    if (params.pipelineLayout == VK_NULL_HANDLE) {
        VGLOG_CR("Validation failed: pipelineLayout is VK_NULL_HANDLE");
        return false;
    }
    if (params.descriptorSet == VK_NULL_HANDLE) {
        VGLOG_CR("Validation failed: descriptorSet is VK_NULL_HANDLE");
        return false;
    }
    if (params.pipeline == VK_NULL_HANDLE) {
        VGLOG_CR("Validation failed: pipeline is VK_NULL_HANDLE");
        return false;
    }
    if (params.extentWidth == 0 || params.extentHeight == 0) {
        VGLOG_CR("Validation failed: invalid extents (%u x %u)",
                 params.extentWidth, params.extentHeight);
        return false;
    }
    if (params.transitionSourceImage) {
        if (params.sourceImage == nullptr) {
            VGLOG_CR("Validation failed: transitionSourceImage is true but sourceImage is nullptr");
            return false;
        }
        if (params.sourceImage->image == VK_NULL_HANDLE) {
            VGLOG_CR("Validation failed: transitionSourceImage is true but sourceImage->image is VK_NULL_HANDLE");
            return false;
        }
    }
    return true;
}

} // anonymous namespace

bool VulkanGraphicsCommandRecorder::recordGraphicsPass(const VulkanGraphicsPassParams& params) {
    if (!validateGraphicsPassParams(params)) {
        return false;
    }

    // Optional layout transition for imported source image before render pass.
    if (params.transitionSourceImage) {
        params.sourceImage->recordLayoutTransition(
            params.commandBuffer,
            params.sourceOldLayout,
            params.sourceNewLayout,
            params.srcStageMask,
            params.dstStageMask,
            params.srcAccessMask,
            params.dstAccessMask,
            params.srcQueueFamilyIndex,
            params.dstQueueFamilyIndex);
    }

    VkClearValue clearValue{};
    clearValue.color = params.clearColor;

    VkRenderPassBeginInfo renderPassBeginInfo{};
    renderPassBeginInfo.sType = VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO;
    renderPassBeginInfo.pNext = nullptr;
    renderPassBeginInfo.renderPass = params.renderPass;
    renderPassBeginInfo.framebuffer = params.framebuffer;
    renderPassBeginInfo.renderArea.offset = {0, 0};
    renderPassBeginInfo.renderArea.extent = {params.extentWidth, params.extentHeight};
    renderPassBeginInfo.clearValueCount = 1;
    renderPassBeginInfo.pClearValues = &clearValue;

    vkCmdBeginRenderPass(params.commandBuffer, &renderPassBeginInfo, VK_SUBPASS_CONTENTS_INLINE);

    VkViewport viewport{};
    viewport.x = 0.0f;
    viewport.y = 0.0f;
    viewport.width = static_cast<float>(params.extentWidth);
    viewport.height = static_cast<float>(params.extentHeight);
    viewport.minDepth = 0.0f;
    viewport.maxDepth = 1.0f;
    vkCmdSetViewport(params.commandBuffer, 0, 1, &viewport);

    VkRect2D scissor{};
    scissor.offset = {0, 0};
    scissor.extent = {params.extentWidth, params.extentHeight};
    vkCmdSetScissor(params.commandBuffer, 0, 1, &scissor);

    vkCmdBindPipeline(params.commandBuffer, VK_PIPELINE_BIND_POINT_GRAPHICS, params.pipeline);

    vkCmdBindDescriptorSets(
        params.commandBuffer,
        VK_PIPELINE_BIND_POINT_GRAPHICS,
        params.pipelineLayout,
        0,
        1,
        &params.descriptorSet,
        0,
        nullptr);

    // Phase 4B2C: push UV transform constants for vertex-shader rotation.
    // VkPushConstantRange: VERTEX stage, offset 0, size 32.
    vkCmdPushConstants(
        params.commandBuffer,
        params.pipelineLayout,
        VK_SHADER_STAGE_VERTEX_BIT,
        0,
        sizeof(params.uvTransformPushConstants),
        params.uvTransformPushConstants);

    vkCmdDraw(params.commandBuffer, 3, 1, 0, 0);

    vkCmdEndRenderPass(params.commandBuffer);

    return true;
}

bool VulkanGraphicsCommandRecorder::recordCompletePass(
    const VulkanGraphicsPassParams& params,
    VkCommandBufferUsageFlags flags) {
    if (!validateGraphicsPassParams(params)) {
        return false;
    }

    VkCommandBufferBeginInfo beginInfo{};
    beginInfo.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
    beginInfo.pNext = nullptr;
    beginInfo.flags = flags;
    beginInfo.pInheritanceInfo = nullptr;

    VkResult res = vkBeginCommandBuffer(params.commandBuffer, &beginInfo);
    if (res != VK_SUCCESS) {
        VGLOG_CR("vkBeginCommandBuffer failed: %d", res);
        return false;
    }

    if (!recordGraphicsPass(params)) {
        return false;
    }

    res = vkEndCommandBuffer(params.commandBuffer);
    if (res != VK_SUCCESS) {
        VGLOG_CR("vkEndCommandBuffer failed: %d", res);
        return false;
    }

    return true;
}

} // namespace render
} // namespace vanguard

#else // !__ANDROID__

namespace vanguard {
namespace render {

bool VulkanGraphicsCommandRecorder::recordGraphicsPass(const VulkanGraphicsPassParams& params) {
    (void)params;
    return false;
}

bool VulkanGraphicsCommandRecorder::recordCompletePass(
    const VulkanGraphicsPassParams& params,
    uint32_t flags) {
    (void)params;
    (void)flags;
    return false;
}

} // namespace render
} // namespace vanguard

#endif // __ANDROID__
