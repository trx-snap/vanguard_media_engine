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

#include "vanguard/render/render_transform.h"

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
    // Phase 10: combined UV transform (vertex) + color matrix (fragment)
    // push constants, identity defaults (UV identity mapping, identity
    // color matrix, zero offset).
    VideoTransformFullPushConstants pushConstants = {
        {
            {1.0f, 0.0f, 0.0f, 0.0f},  // uvTransform0 (u = x)
            {0.0f, 1.0f, 0.0f, 0.0f},  // uvTransform1 (v = y)
        },
        {
            {1.0f, 0.0f, 0.0f, 0.0f},  // color.row0
            {0.0f, 1.0f, 0.0f, 0.0f},  // color.row1
            {0.0f, 0.0f, 1.0f, 0.0f},  // color.row2
            {0.0f, 0.0f, 0.0f, 1.0f},  // color.row3
            {0.0f, 0.0f, 0.0f, 0.0f},  // color.offset
        },
    };
    // Aspect-fit destination sub-rect (viewport/scissor) within the render
    // pass's full extent, in output pixel coordinates. All-zero (the
    // default) means "no destination rect": viewport/scissor cover the full
    // extentWidth x extentHeight, matching pre-existing behavior. The render
    // pass's own renderArea/clear always covers the full extent regardless
    // of this rect, so unfit regions are cleared to clearColor (black).
    int32_t destinationX = 0;
    int32_t destinationY = 0;
    uint32_t destinationWidth = 0;
    uint32_t destinationHeight = 0;
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
    // Phase 10: combined UV transform + color matrix push constants
    // (identity defaults), host-build mirror of the Android field above.
    VideoTransformFullPushConstants pushConstants = {
        {
            {1.0f, 0.0f, 0.0f, 0.0f},
            {0.0f, 1.0f, 0.0f, 0.0f},
        },
        {
            {1.0f, 0.0f, 0.0f, 0.0f},
            {0.0f, 1.0f, 0.0f, 0.0f},
            {0.0f, 0.0f, 1.0f, 0.0f},
            {0.0f, 0.0f, 0.0f, 1.0f},
            {0.0f, 0.0f, 0.0f, 0.0f},
        },
    };
    // Aspect-fit destination sub-rect (host-build mirror of the Android
    // fields above; unused by the host stub implementation).
    int32_t destinationX = 0;
    int32_t destinationY = 0;
    uint32_t destinationWidth = 0;
    uint32_t destinationHeight = 0;
#endif
};

// ---------------------------------------------------------------------------
// P5-COMPOSITOR-TRANS: two-source clip overlap transition pass.
// ---------------------------------------------------------------------------
// One layer draw inside a transition render pass: a fullscreen-triangle draw
// of one imported source image through its own pipeline / pipeline layout /
// descriptor set, scoped by an explicit viewport and an explicit scissor.
// Unlike VulkanGraphicsPassParams::destination*, the viewport here MAY extend
// beyond (or start before) the render area -- off-canvas slide placement --
// while the scissor MUST be a non-empty sub-rect of the render area, since
// the application must confine all rasterization to the render area.
struct VulkanTransitionLayerDraw {
#if defined(__ANDROID__)
    VkPipeline pipeline = VK_NULL_HANDLE;
    VkPipelineLayout pipelineLayout = VK_NULL_HANDLE;
    VkDescriptorSet descriptorSet = VK_NULL_HANDLE;
#else
    void* pipeline = nullptr;
    void* pipelineLayout = nullptr;
    void* descriptorSet = nullptr;
#endif
    VideoTransformFullPushConstants pushConstants = {
        {
            {1.0f, 0.0f, 0.0f, 0.0f},
            {0.0f, 1.0f, 0.0f, 0.0f},
        },
        {
            {1.0f, 0.0f, 0.0f, 0.0f},
            {0.0f, 1.0f, 0.0f, 0.0f},
            {0.0f, 0.0f, 1.0f, 0.0f},
            {0.0f, 0.0f, 0.0f, 1.0f},
            {0.0f, 0.0f, 0.0f, 0.0f},
        },
    };
    int32_t viewportX = 0;
    int32_t viewportY = 0;
    uint32_t viewportWidth = 0;
    uint32_t viewportHeight = 0;
    int32_t scissorX = 0;
    int32_t scissorY = 0;
    uint32_t scissorWidth = 0;
    uint32_t scissorHeight = 0;
    // When true the pipeline was created with VK_DYNAMIC_STATE_BLEND_CONSTANTS
    // and [blendConstant] is set on all four channels before the draw.
    bool useBlendConstants = false;
    float blendConstant = 0.0f;
};

// Upper bound on layer draws per transition pass: "from" content, "to"
// content, plus up to four black letterbox bands for the "to" layer.
constexpr uint32_t kVulkanTransitionMaxLayerDraws = 8;

struct VulkanTransitionPassParams {
#if defined(__ANDROID__)
    VkCommandBuffer commandBuffer = VK_NULL_HANDLE;
    VkRenderPass renderPass = VK_NULL_HANDLE;
    VkFramebuffer framebuffer = VK_NULL_HANDLE;
    VkClearColorValue clearColor = {{0.0f, 0.0f, 0.0f, 1.0f}};
    // Optional pre-pass layout transitions for the two imported sources
    // (UNDEFINED -> SHADER_READ_ONLY_OPTIMAL on first use, same stage/access
    // masks as the single-source pass).
    bool transitionFromImage = false;
    const VulkanHardwareBufferImage* fromImage = nullptr;
    VkImageLayout fromOldLayout = VK_IMAGE_LAYOUT_UNDEFINED;
    bool transitionToImage = false;
    const VulkanHardwareBufferImage* toImage = nullptr;
    VkImageLayout toOldLayout = VK_IMAGE_LAYOUT_UNDEFINED;
#else
    void* commandBuffer = nullptr;
    void* renderPass = nullptr;
    void* framebuffer = nullptr;
    float clearColor[4] = {0.0f, 0.0f, 0.0f, 1.0f};
    bool transitionFromImage = false;
    const VulkanHardwareBufferImage* fromImage = nullptr;
    uint32_t fromOldLayout = 0;
    bool transitionToImage = false;
    const VulkanHardwareBufferImage* toImage = nullptr;
    uint32_t toOldLayout = 0;
#endif
    uint32_t extentWidth = 0;
    uint32_t extentHeight = 0;
    VulkanTransitionLayerDraw draws[kVulkanTransitionMaxLayerDraws];
    uint32_t drawCount = 0;
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

    // P5-COMPOSITOR-TRANS: begins the command buffer, records optional
    // source layout transitions, one clear render pass over the full extent
    // and every layer draw in order, then ends the command buffer. Validates
    // every handle / extent / scissor before recording anything; returns
    // false (recording nothing) on any invalid parameter.
    static bool recordTransitionPass(
        const VulkanTransitionPassParams& params,
#if defined(__ANDROID__)
        VkCommandBufferUsageFlags flags = 0
#else
        uint32_t flags = 0
#endif
    );

    // P5-BEAUTY-V2-TRANSITION-COMP: validated body-only seam for use after
    // the caller has already called vkBeginCommandBuffer itself (the beauty
    // transition path, which must interleave beauty pre-passes between begin
    // and this body). Validates every handle / extent / scissor exactly like
    // [recordTransitionPass] above, then records the optional source layout
    // transitions, one clear render pass over the full extent, and every
    // layer draw in order -- WITHOUT beginning or ending the command buffer.
    // Returns false (recording nothing) on any invalid parameter.
    static bool recordTransitionPassBody(const VulkanTransitionPassParams& params);
};

} // namespace render
} // namespace vanguard
