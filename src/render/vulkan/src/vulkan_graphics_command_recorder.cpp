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
    // A non-default destination rect (any field non-zero) must be a fully
    // valid, non-empty sub-rect of the render pass's full extent.
    const bool hasDestinationRect =
        params.destinationX != 0 || params.destinationY != 0 ||
        params.destinationWidth != 0 || params.destinationHeight != 0;
    if (hasDestinationRect) {
        if (params.destinationWidth == 0 || params.destinationHeight == 0) {
            VGLOG_CR("Validation failed: destination rect has zero width/height (%u x %u)",
                     params.destinationWidth, params.destinationHeight);
            return false;
        }
        if (params.destinationX < 0 || params.destinationY < 0) {
            VGLOG_CR("Validation failed: destination rect has negative origin (%d, %d)",
                     params.destinationX, params.destinationY);
            return false;
        }
        const uint64_t right =
            static_cast<uint64_t>(params.destinationX) + static_cast<uint64_t>(params.destinationWidth);
        const uint64_t bottom =
            static_cast<uint64_t>(params.destinationY) + static_cast<uint64_t>(params.destinationHeight);
        if (right > params.extentWidth || bottom > params.extentHeight) {
            VGLOG_CR("Validation failed: destination rect (%d, %d, %u x %u) exceeds extent (%u x %u)",
                     params.destinationX, params.destinationY,
                     params.destinationWidth, params.destinationHeight,
                     params.extentWidth, params.extentHeight);
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

    // Aspect-fit destination sub-rect: renderArea/clear above always cover
    // the full extent (so letterbox/pillarbox regions are cleared to
    // clearColor), while the viewport/scissor below are scoped to the
    // destination rect when one was supplied, so the source image is only
    // drawn into that sub-rect. Validated by validateGraphicsPassParams
    // above to be non-empty and within extent whenever any field is non-zero.
    const bool hasDestinationRect =
        params.destinationX != 0 || params.destinationY != 0 ||
        params.destinationWidth != 0 || params.destinationHeight != 0;
    const int32_t destX = hasDestinationRect ? params.destinationX : 0;
    const int32_t destY = hasDestinationRect ? params.destinationY : 0;
    const uint32_t destWidth = hasDestinationRect ? params.destinationWidth : params.extentWidth;
    const uint32_t destHeight = hasDestinationRect ? params.destinationHeight : params.extentHeight;

    VkViewport viewport{};
    viewport.x = static_cast<float>(destX);
    viewport.y = static_cast<float>(destY);
    viewport.width = static_cast<float>(destWidth);
    viewport.height = static_cast<float>(destHeight);
    viewport.minDepth = 0.0f;
    viewport.maxDepth = 1.0f;
    vkCmdSetViewport(params.commandBuffer, 0, 1, &viewport);

    VkRect2D scissor{};
    scissor.offset = {destX, destY};
    scissor.extent = {destWidth, destHeight};
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

    // Phase 10: push the combined UV transform (vertex) + color matrix
    // (fragment) constants in one call. VkPushConstantRange: VERTEX|FRAGMENT
    // stage, offset 0, size sizeof(VideoTransformFullPushConstants).
    vkCmdPushConstants(
        params.commandBuffer,
        params.pipelineLayout,
        VK_SHADER_STAGE_VERTEX_BIT | VK_SHADER_STAGE_FRAGMENT_BIT,
        0,
        sizeof(params.pushConstants),
        &params.pushConstants);

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
