// vulkan_overlay_frame_renderer.cpp
// P5-OVERLAYS-TRANS / P5-OVERLAYS-PRODUCTION-EXPORT-ROUTE-A: native helper
// sub-slice N1 - VulkanOverlayFrameRenderer implementation.
//
// Android-only real implementation is inside #if defined(__ANDROID__).
// Non-Android translation unit compiles to a safe stub that performs no
// Vulkan calls, matching the other private Vulkan helper host stubs (e.g.
// VulkanBeautyFrameRenderer), except that it returns true (not false) for
// the validated overlayCount == 0 no-op, per this helper's own contract.
//
// This is an isolated, uninstantiated helper: it is not called from
// VulkanFrameRenderer, VulkanBackend, JNI, or Kotlin in this sub-slice.

#include "vulkan_overlay_frame_renderer.h"

#include <memory>
#include <string>

#if defined(__ANDROID__)

#include <cmath>
#include <cstring>
#include <vector>

#ifndef VK_USE_PLATFORM_ANDROID_KHR
#define VK_USE_PLATFORM_ANDROID_KHR
#endif
#include <vulkan/vulkan.h>
#include <android/log.h>

#define VGLOG_OFR(...) \
    __android_log_print(ANDROID_LOG_DEBUG, "VanguardVkOverlayFrameRnd", __VA_ARGS__)

namespace vanguard {
namespace render {

namespace {

constexpr const char* kErrInvalidArgument    = "vulkan_overlay_frame_renderer_invalid_argument";
constexpr const char* kErrInvalidDraw        = "vulkan_overlay_frame_renderer_invalid_draw";
constexpr const char* kErrRenderPassMismatch = "vulkan_overlay_frame_renderer_render_pass_mismatch";
constexpr const char* kErrDescriptorFailed   = "vulkan_overlay_frame_renderer_descriptor_failed";
constexpr const char* kErrPipelineFailed     = "vulkan_overlay_frame_renderer_pipeline_failed";

void SetErr(std::string* outError, const char* reason) {
    if (outError) *outError = reason;
}

// Non-dispatchable Vulkan handles are exactly 8 bytes on every ABI Vulkan
// supports (a pointer on LP64/64-bit targets, a plain uint64_t otherwise),
// so a byte-for-byte memcpy round-trips through uint64_t on either ABI.
static_assert(sizeof(VkImageView) == sizeof(uint64_t),
             "VkImageView must be 8 bytes to round-trip through uint64_t");
static_assert(sizeof(VkSampler) == sizeof(uint64_t),
             "VkSampler must be 8 bytes to round-trip through uint64_t");
static_assert(sizeof(VkRenderPass) == sizeof(uint64_t),
             "VkRenderPass must be 8 bytes to round-trip through uint64_t");

VkImageView ToImageView(uint64_t handle) {
    VkImageView view = VK_NULL_HANDLE;
    std::memcpy(&view, &handle, sizeof(view));
    return view;
}

VkSampler ToSampler(uint64_t handle) {
    VkSampler sampler = VK_NULL_HANDLE;
    std::memcpy(&sampler, &handle, sizeof(sampler));
    return sampler;
}

VkRenderPass ToRenderPass(uint64_t handle) {
    VkRenderPass renderPass = VK_NULL_HANDLE;
    std::memcpy(&renderPass, &handle, sizeof(renderPass));
    return renderPass;
}

bool DrawFieldsFinite(const VulkanOverlayFrameDraw& draw) {
    for (int i = 0; i < 4; ++i) {
        if (!std::isfinite(draw.uvRow0[i]) || !std::isfinite(draw.uvRow1[i])) return false;
    }
    return std::isfinite(draw.opacity);
}

bool DrawScissorValid(const VulkanOverlayFrameDraw& draw, uint32_t canvasWidth, uint32_t canvasHeight) {
    if (draw.scissorWidth == 0 || draw.scissorHeight == 0) return false;
    if (draw.scissorX < 0 || draw.scissorY < 0) return false;
    const uint64_t right  = static_cast<uint64_t>(draw.scissorX) + static_cast<uint64_t>(draw.scissorWidth);
    const uint64_t bottom = static_cast<uint64_t>(draw.scissorY) + static_cast<uint64_t>(draw.scissorHeight);
    return right <= static_cast<uint64_t>(canvasWidth) && bottom <= static_cast<uint64_t>(canvasHeight);
}

} // namespace

struct VulkanOverlayFrameRenderer::Impl {
    VkDescriptorSetLayout setLayout = VK_NULL_HANDLE;
    VkPipelineLayout pipelineLayout = VK_NULL_HANDLE;

    VkPipeline pipeline = VK_NULL_HANDLE;
    VkRenderPass cachedRenderPass = VK_NULL_HANDLE;
    VkShaderModule cachedVertexModule = VK_NULL_HANDLE;
    VkShaderModule cachedFragmentModule = VK_NULL_HANDLE;

    VkDescriptorPool pool = VK_NULL_HANDLE;
    uint32_t poolCapacity = 0; // max descriptor sets the current pool supports

    // Descriptor set layout (binding 0 combined image sampler, fragment
    // stage) and pipeline layout (shared 112-byte VideoTransformFullPushConstants
    // range). Idempotent: safe to call again after a partial failure, since
    // each half only (re)creates its own still-null handle.
    bool ensureSharedLayouts(VkDevice device, std::string* outFailureReason) {
        if (setLayout == VK_NULL_HANDLE) {
            VkDescriptorSetLayoutBinding binding{};
            binding.binding            = 0;
            binding.descriptorType     = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
            binding.descriptorCount    = 1;
            binding.stageFlags         = VK_SHADER_STAGE_FRAGMENT_BIT;
            binding.pImmutableSamplers = nullptr;

            VkDescriptorSetLayoutCreateInfo layoutCI{};
            layoutCI.sType        = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO;
            layoutCI.bindingCount = 1;
            layoutCI.pBindings    = &binding;
            if (vkCreateDescriptorSetLayout(device, &layoutCI, nullptr, &setLayout) != VK_SUCCESS) {
                setLayout = VK_NULL_HANDLE;
                SetErr(outFailureReason, kErrDescriptorFailed);
                return false;
            }
        }

        if (pipelineLayout == VK_NULL_HANDLE) {
            VkPushConstantRange pushRange{};
            pushRange.stageFlags = VK_SHADER_STAGE_VERTEX_BIT | VK_SHADER_STAGE_FRAGMENT_BIT;
            pushRange.offset     = 0;
            pushRange.size       = static_cast<uint32_t>(sizeof(VideoTransformFullPushConstants));

            VkPipelineLayoutCreateInfo plCI{};
            plCI.sType                  = VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO;
            plCI.setLayoutCount         = 1;
            plCI.pSetLayouts            = &setLayout;
            plCI.pushConstantRangeCount = 1;
            plCI.pPushConstantRanges    = &pushRange;
            if (vkCreatePipelineLayout(device, &plCI, nullptr, &pipelineLayout) != VK_SUCCESS) {
                pipelineLayout = VK_NULL_HANDLE;
                SetErr(outFailureReason, kErrDescriptorFailed);
                return false;
            }
        }
        return true;
    }

    // Straight-alpha source-over blend pipeline mirroring
    // vulkan_overlay_compositor.cpp's CreateBlendPipeline (fullscreen
    // triangle, no vertex input, dynamic viewport/scissor). Built once
    // against the first call's renderPass/vertexModule/fragmentModule and
    // reused; a later call with a different renderPass or shader module
    // fails closed instead of silently rebuilding (which could invalidate a
    // pipeline an in-flight command buffer still references).
    bool ensurePipeline(VkDevice device, VkShaderModule vertexModule, VkShaderModule fragmentModule,
                       VkRenderPass renderPass, std::string* outFailureReason) {
        if (pipeline != VK_NULL_HANDLE) {
            if (renderPass != cachedRenderPass || vertexModule != cachedVertexModule ||
                fragmentModule != cachedFragmentModule) {
                SetErr(outFailureReason, kErrRenderPassMismatch);
                return false;
            }
            return true;
        }

        VkPipelineShaderStageCreateInfo stages[2]{};
        stages[0].sType  = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO;
        stages[0].stage  = VK_SHADER_STAGE_VERTEX_BIT;
        stages[0].module = vertexModule;
        stages[0].pName  = "main";
        stages[1].sType  = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO;
        stages[1].stage  = VK_SHADER_STAGE_FRAGMENT_BIT;
        stages[1].module = fragmentModule;
        stages[1].pName  = "main";

        VkPipelineVertexInputStateCreateInfo vertexInput{};
        vertexInput.sType = VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO;

        VkPipelineInputAssemblyStateCreateInfo inputAssembly{};
        inputAssembly.sType    = VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO;
        inputAssembly.topology = VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST;

        const VkDynamicState dynamicStates[] = {VK_DYNAMIC_STATE_VIEWPORT, VK_DYNAMIC_STATE_SCISSOR};
        VkPipelineDynamicStateCreateInfo dynamicState{};
        dynamicState.sType             = VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO;
        dynamicState.dynamicStateCount = 2;
        dynamicState.pDynamicStates    = dynamicStates;

        VkPipelineViewportStateCreateInfo viewportState{};
        viewportState.sType         = VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO;
        viewportState.viewportCount = 1;
        viewportState.scissorCount  = 1;

        VkPipelineRasterizationStateCreateInfo rasterizer{};
        rasterizer.sType       = VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO;
        rasterizer.polygonMode = VK_POLYGON_MODE_FILL;
        rasterizer.cullMode    = VK_CULL_MODE_NONE;
        rasterizer.frontFace   = VK_FRONT_FACE_COUNTER_CLOCKWISE;
        rasterizer.lineWidth   = 1.0f;

        VkPipelineMultisampleStateCreateInfo multisampling{};
        multisampling.sType                = VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO;
        multisampling.rasterizationSamples = VK_SAMPLE_COUNT_1_BIT;
        multisampling.minSampleShading     = 1.0f;

        // Straight-alpha source-over: colour = srcRGB * srcA + dstRGB * (1 - srcA),
        // alpha = srcA + dstA * (1 - srcA).
        VkPipelineColorBlendAttachmentState attachment{};
        attachment.blendEnable         = VK_TRUE;
        attachment.srcColorBlendFactor = VK_BLEND_FACTOR_SRC_ALPHA;
        attachment.dstColorBlendFactor = VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA;
        attachment.colorBlendOp        = VK_BLEND_OP_ADD;
        attachment.srcAlphaBlendFactor = VK_BLEND_FACTOR_ONE;
        attachment.dstAlphaBlendFactor = VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA;
        attachment.alphaBlendOp        = VK_BLEND_OP_ADD;
        attachment.colorWriteMask      = VK_COLOR_COMPONENT_R_BIT | VK_COLOR_COMPONENT_G_BIT |
                                         VK_COLOR_COMPONENT_B_BIT | VK_COLOR_COMPONENT_A_BIT;

        VkPipelineColorBlendStateCreateInfo colorBlend{};
        colorBlend.sType           = VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO;
        colorBlend.logicOpEnable   = VK_FALSE;
        colorBlend.logicOp         = VK_LOGIC_OP_COPY;
        colorBlend.attachmentCount = 1;
        colorBlend.pAttachments    = &attachment;

        VkGraphicsPipelineCreateInfo pipelineCI{};
        pipelineCI.sType               = VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO;
        pipelineCI.stageCount          = 2;
        pipelineCI.pStages             = stages;
        pipelineCI.pVertexInputState   = &vertexInput;
        pipelineCI.pInputAssemblyState = &inputAssembly;
        pipelineCI.pViewportState      = &viewportState;
        pipelineCI.pRasterizationState = &rasterizer;
        pipelineCI.pMultisampleState   = &multisampling;
        pipelineCI.pColorBlendState    = &colorBlend;
        pipelineCI.pDynamicState       = &dynamicState;
        pipelineCI.layout              = pipelineLayout;
        pipelineCI.renderPass          = renderPass;
        pipelineCI.subpass             = 0;
        pipelineCI.basePipelineIndex   = -1;

        VkPipeline created = VK_NULL_HANDLE;
        if (vkCreateGraphicsPipelines(device, VK_NULL_HANDLE, 1, &pipelineCI, nullptr, &created) != VK_SUCCESS) {
            SetErr(outFailureReason, kErrPipelineFailed);
            return false;
        }
        pipeline             = created;
        cachedRenderPass     = renderPass;
        cachedVertexModule   = vertexModule;
        cachedFragmentModule = fragmentModule;
        return true;
    }

    // Grow-only descriptor pool: (re)created only when `overlayCount`
    // exceeds the current capacity; otherwise reset so every call starts
    // from zero allocated sets without a destroy/create round trip.
    bool ensurePool(VkDevice device, uint32_t overlayCount, std::string* outFailureReason) {
        if (overlayCount <= poolCapacity) {
            if (vkResetDescriptorPool(device, pool, 0) != VK_SUCCESS) {
                SetErr(outFailureReason, kErrDescriptorFailed);
                return false;
            }
            return true;
        }

        if (pool != VK_NULL_HANDLE) {
            vkDestroyDescriptorPool(device, pool, nullptr);
            pool = VK_NULL_HANDLE;
            poolCapacity = 0;
        }

        VkDescriptorPoolSize poolSize{};
        poolSize.type            = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
        poolSize.descriptorCount = overlayCount;

        VkDescriptorPoolCreateInfo poolCI{};
        poolCI.sType         = VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO;
        poolCI.maxSets       = overlayCount;
        poolCI.poolSizeCount = 1;
        poolCI.pPoolSizes    = &poolSize;
        if (vkCreateDescriptorPool(device, &poolCI, nullptr, &pool) != VK_SUCCESS) {
            pool = VK_NULL_HANDLE;
            SetErr(outFailureReason, kErrDescriptorFailed);
            return false;
        }
        poolCapacity = overlayCount;
        return true;
    }

    void destroyPipeline(VkDevice device) {
        if (pipeline != VK_NULL_HANDLE) {
            vkDestroyPipeline(device, pipeline, nullptr);
            pipeline = VK_NULL_HANDLE;
        }
        cachedRenderPass     = VK_NULL_HANDLE;
        cachedVertexModule   = VK_NULL_HANDLE;
        cachedFragmentModule = VK_NULL_HANDLE;
    }

    void destroyAll(VkDevice device) {
        destroyPipeline(device);
        if (pipelineLayout != VK_NULL_HANDLE) {
            vkDestroyPipelineLayout(device, pipelineLayout, nullptr);
            pipelineLayout = VK_NULL_HANDLE;
        }
        if (setLayout != VK_NULL_HANDLE) {
            vkDestroyDescriptorSetLayout(device, setLayout, nullptr);
            setLayout = VK_NULL_HANDLE;
        }
        if (pool != VK_NULL_HANDLE) {
            vkDestroyDescriptorPool(device, pool, nullptr);
            pool = VK_NULL_HANDLE;
            poolCapacity = 0;
        }
    }
};

VulkanOverlayFrameRenderer::VulkanOverlayFrameRenderer() : impl_(std::make_unique<Impl>()) {}
VulkanOverlayFrameRenderer::~VulkanOverlayFrameRenderer() = default;

bool VulkanOverlayFrameRenderer::recordOverlayDraws(
    void* devicePtr,
    void* commandBufferPtr,
    void* vertexModulePtr,
    void* fragmentModulePtr,
    uint64_t renderPassHandle,
    uint32_t canvasWidth,
    uint32_t canvasHeight,
    const VulkanOverlayFrameDraw* draws,
    uint32_t overlayCount,
    std::string* outFailureReason) {
    if (outFailureReason) outFailureReason->clear();

    if (overlayCount == 0) {
        return true; // validated no-op: zero Vulkan calls regardless of other args
    }

    VkDevice device               = reinterpret_cast<VkDevice>(devicePtr);
    VkCommandBuffer commandBuffer = reinterpret_cast<VkCommandBuffer>(commandBufferPtr);
    VkShaderModule vertexModule   = reinterpret_cast<VkShaderModule>(vertexModulePtr);
    VkShaderModule fragmentModule = reinterpret_cast<VkShaderModule>(fragmentModulePtr);
    VkRenderPass renderPass       = ToRenderPass(renderPassHandle);

    if (device == VK_NULL_HANDLE || commandBuffer == VK_NULL_HANDLE ||
        vertexModule == VK_NULL_HANDLE || fragmentModule == VK_NULL_HANDLE ||
        renderPass == VK_NULL_HANDLE || canvasWidth == 0 || canvasHeight == 0 ||
        draws == nullptr) {
        SetErr(outFailureReason, kErrInvalidArgument);
        return false;
    }

    for (uint32_t i = 0; i < overlayCount; ++i) {
        const VulkanOverlayFrameDraw& d = draws[i];
        if (d.imageViewHandle == 0 || d.samplerHandle == 0) {
            SetErr(outFailureReason, kErrInvalidDraw);
            return false;
        }
        if (!DrawFieldsFinite(d) || d.opacity < 0.0f || d.opacity > 1.0f) {
            SetErr(outFailureReason, kErrInvalidDraw);
            return false;
        }
        if (!DrawScissorValid(d, canvasWidth, canvasHeight)) {
            SetErr(outFailureReason, kErrInvalidDraw);
            return false;
        }
    }

    // Vulkan work below. Every check above ran with zero Vulkan calls.
    if (!impl_->ensureSharedLayouts(device, outFailureReason)) return false;
    if (!impl_->ensurePipeline(device, vertexModule, fragmentModule, renderPass, outFailureReason)) return false;
    if (!impl_->ensurePool(device, overlayCount, outFailureReason)) return false;

    std::vector<VkDescriptorSetLayout> layouts(overlayCount, impl_->setLayout);
    std::vector<VkDescriptorSet> sets(overlayCount, VK_NULL_HANDLE);
    VkDescriptorSetAllocateInfo allocInfo{};
    allocInfo.sType              = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO;
    allocInfo.descriptorPool     = impl_->pool;
    allocInfo.descriptorSetCount = overlayCount;
    allocInfo.pSetLayouts        = layouts.data();
    if (vkAllocateDescriptorSets(device, &allocInfo, sets.data()) != VK_SUCCESS) {
        SetErr(outFailureReason, kErrDescriptorFailed);
        return false;
    }

    std::vector<VkDescriptorImageInfo> imageInfos(overlayCount);
    std::vector<VkWriteDescriptorSet> writes(overlayCount);
    for (uint32_t i = 0; i < overlayCount; ++i) {
        imageInfos[i]             = VkDescriptorImageInfo{};
        imageInfos[i].sampler     = ToSampler(draws[i].samplerHandle);
        imageInfos[i].imageView   = ToImageView(draws[i].imageViewHandle);
        imageInfos[i].imageLayout = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;

        writes[i]                 = VkWriteDescriptorSet{};
        writes[i].sType           = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
        writes[i].dstSet          = sets[i];
        writes[i].dstBinding      = 0;
        writes[i].dstArrayElement = 0;
        writes[i].descriptorCount = 1;
        writes[i].descriptorType  = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
        writes[i].pImageInfo      = &imageInfos[i];
    }
    vkUpdateDescriptorSets(device, overlayCount, writes.data(), 0, nullptr);

    vkCmdBindPipeline(commandBuffer, VK_PIPELINE_BIND_POINT_GRAPHICS, impl_->pipeline);

    // Full-canvas viewport so the vertex shader's base (x, y) spans the whole
    // canvas; per-draw scissor limits the fill to the caller-clipped rect.
    VkViewport viewport{};
    viewport.x        = 0.0f;
    viewport.y        = 0.0f;
    viewport.width    = static_cast<float>(canvasWidth);
    viewport.height   = static_cast<float>(canvasHeight);
    viewport.minDepth = 0.0f;
    viewport.maxDepth = 1.0f;
    vkCmdSetViewport(commandBuffer, 0, 1, &viewport);

    for (uint32_t i = 0; i < overlayCount; ++i) {
        const VulkanOverlayFrameDraw& d = draws[i];

        VkRect2D scissor{};
        scissor.offset = {d.scissorX, d.scissorY};
        scissor.extent = {d.scissorWidth, d.scissorHeight};
        vkCmdSetScissor(commandBuffer, 0, 1, &scissor);

        vkCmdBindDescriptorSets(commandBuffer, VK_PIPELINE_BIND_POINT_GRAPHICS, impl_->pipelineLayout,
                                0, 1, &sets[i], 0, nullptr);

        // Push constants: UV rows verbatim; identity colour rows 0..2 and
        // (0, 0, 0, opacity) in row 3 so only the sampled alpha is scaled
        // and RGB stays straight.
        VideoTransformFullPushConstants pc{};
        std::memcpy(pc.uv.uvTransform0, d.uvRow0, sizeof(pc.uv.uvTransform0));
        std::memcpy(pc.uv.uvTransform1, d.uvRow1, sizeof(pc.uv.uvTransform1));
        pc.color.row0[0] = 1.0f;
        pc.color.row1[1] = 1.0f;
        pc.color.row2[2] = 1.0f;
        pc.color.row3[3] = d.opacity;
        vkCmdPushConstants(commandBuffer, impl_->pipelineLayout,
                           VK_SHADER_STAGE_VERTEX_BIT | VK_SHADER_STAGE_FRAGMENT_BIT,
                           0, static_cast<uint32_t>(sizeof(pc)), &pc);

        vkCmdDraw(commandBuffer, 3, 1, 0, 0);
    }

    return true;
}

void VulkanOverlayFrameRenderer::invalidate(void* devicePtr) {
    VkDevice device = reinterpret_cast<VkDevice>(devicePtr);
    if (device == VK_NULL_HANDLE) return;
    impl_->destroyPipeline(device);
}

void VulkanOverlayFrameRenderer::shutdown(void* devicePtr) {
    VkDevice device = reinterpret_cast<VkDevice>(devicePtr);
    if (device == VK_NULL_HANDLE) return;
    impl_->destroyAll(device);
}

} // namespace render
} // namespace vanguard

#else // !defined(__ANDROID__) - host build

namespace vanguard {
namespace render {

struct VulkanOverlayFrameRenderer::Impl {};

VulkanOverlayFrameRenderer::VulkanOverlayFrameRenderer() : impl_(std::make_unique<Impl>()) {}
VulkanOverlayFrameRenderer::~VulkanOverlayFrameRenderer() = default;

bool VulkanOverlayFrameRenderer::recordOverlayDraws(
    void* /*device*/,
    void* /*commandBuffer*/,
    void* /*vertexModule*/,
    void* /*fragmentModule*/,
    uint64_t /*renderPass*/,
    uint32_t /*canvasWidth*/,
    uint32_t /*canvasHeight*/,
    const VulkanOverlayFrameDraw* /*draws*/,
    uint32_t overlayCount,
    std::string* outFailureReason) {
    if (outFailureReason) outFailureReason->clear();
    if (overlayCount == 0) {
        return true; // validated no-op: zero Vulkan calls regardless of other args
    }
    if (outFailureReason) *outFailureReason = "vulkan_overlay_frame_renderer_unavailable_on_host";
    return false;
}

void VulkanOverlayFrameRenderer::invalidate(void* /*device*/) {
    // no-op on host
}

void VulkanOverlayFrameRenderer::shutdown(void* /*device*/) {
    // no-op on host
}

} // namespace render
} // namespace vanguard

#endif // __ANDROID__
