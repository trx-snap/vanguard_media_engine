// vulkan_greenscreen_frame_renderer.cpp
// DUET-VULKAN-GREENSCREEN-FRAME-RENDERER: VulkanGreenScreenFrameRenderer
// implementation.
//
// Android-only real implementation is inside #if defined(__ANDROID__).
// Non-Android translation unit compiles to a safe stub that performs no
// Vulkan calls and returns false with a clear failure token.

#include "vulkan_greenscreen_frame_renderer.h"

#include <memory>
#include <string>

#if defined(__ANDROID__)

#include <cstring>
#include <vector>

#ifndef VK_USE_PLATFORM_ANDROID_KHR
#define VK_USE_PLATFORM_ANDROID_KHR
#endif
#include <vulkan/vulkan.h>
#include <android/log.h>

#include "shaders/greenscreen_blend_frag_spv.h"
#include "shaders/passthrough_vert_spv.h"
#include "vanguard/render/render_transform.h"

#define VGLOG_GSFR(...) \
    __android_log_print(ANDROID_LOG_DEBUG, "VanguardVkGreenScreenFrameRnd", __VA_ARGS__)

namespace vanguard {
namespace render {

namespace {

constexpr const char* kErrInvalidArgument    = "vulkan_greenscreen_frame_renderer_invalid_argument";
constexpr const char* kErrInvalidImage        = "vulkan_greenscreen_frame_renderer_invalid_image";
constexpr const char* kErrInvalidMaskSize     = "vulkan_greenscreen_frame_renderer_invalid_mask_size";
constexpr const char* kErrRenderPassMismatch = "vulkan_greenscreen_frame_renderer_render_pass_mismatch";
constexpr const char* kErrShaderModuleFailed = "vulkan_greenscreen_frame_renderer_shader_module_failed";
constexpr const char* kErrDescriptorFailed   = "vulkan_greenscreen_frame_renderer_descriptor_failed";
constexpr const char* kErrPipelineFailed     = "vulkan_greenscreen_frame_renderer_pipeline_failed";

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

} // namespace

struct VulkanGreenScreenFrameRenderer::Impl {
    static constexpr uint32_t kPoolCapacity = 16;

    VkShaderModule vertexShaderModule   = VK_NULL_HANDLE;
    VkShaderModule fragmentShaderModule = VK_NULL_HANDLE;

    VkDescriptorSetLayout setLayout     = VK_NULL_HANDLE;
    VkPipelineLayout pipelineLayout     = VK_NULL_HANDLE;

    VkDescriptorPool pool               = VK_NULL_HANDLE;
    std::vector<VkDescriptorSet> descriptorSets;
    uint32_t nextSetIndex               = 0;

    VkPipeline pipeline                 = VK_NULL_HANDLE;
    VkRenderPass cachedRenderPass       = VK_NULL_HANDLE;

    bool ensureShaderModules(VkDevice device, std::string* outFailureReason) {
        if (vertexShaderModule == VK_NULL_HANDLE) {
            VkShaderModuleCreateInfo ci{};
            ci.sType    = VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO;
            ci.codeSize = shaders::kPassthroughVertSpvSize;
            ci.pCode    = shaders::kPassthroughVertSpv;
            if (vkCreateShaderModule(device, &ci, nullptr, &vertexShaderModule) != VK_SUCCESS) {
                vertexShaderModule = VK_NULL_HANDLE;
                SetErr(outFailureReason, kErrShaderModuleFailed);
                return false;
            }
        }
        if (fragmentShaderModule == VK_NULL_HANDLE) {
            VkShaderModuleCreateInfo ci{};
            ci.sType    = VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO;
            ci.codeSize = shaders::kGreenScreenBlendFragSpvSize;
            ci.pCode    = shaders::kGreenScreenBlendFragSpv;
            if (vkCreateShaderModule(device, &ci, nullptr, &fragmentShaderModule) != VK_SUCCESS) {
                fragmentShaderModule = VK_NULL_HANDLE;
                SetErr(outFailureReason, kErrShaderModuleFailed);
                return false;
            }
        }
        return true;
    }

    bool ensureSharedLayouts(VkDevice device, std::string* outFailureReason) {
        if (setLayout == VK_NULL_HANDLE) {
            VkDescriptorSetLayoutBinding bindings[3]{};
            for (uint32_t i = 0; i < 3; ++i) {
                bindings[i].binding            = i;
                bindings[i].descriptorType     = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
                bindings[i].descriptorCount    = 1;
                bindings[i].stageFlags         = VK_SHADER_STAGE_FRAGMENT_BIT;
                bindings[i].pImmutableSamplers = nullptr;
            }

            VkDescriptorSetLayoutCreateInfo layoutCI{};
            layoutCI.sType        = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO;
            layoutCI.bindingCount = 3;
            layoutCI.pBindings    = bindings;
            if (vkCreateDescriptorSetLayout(device, &layoutCI, nullptr, &setLayout) != VK_SUCCESS) {
                setLayout = VK_NULL_HANDLE;
                SetErr(outFailureReason, kErrDescriptorFailed);
                return false;
            }
        }

        if (pipelineLayout == VK_NULL_HANDLE) {
            VkPushConstantRange pushRange{};
            pushRange.stageFlags = VK_SHADER_STAGE_VERTEX_BIT;
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

    bool ensureDescriptorPool(VkDevice device, std::string* outFailureReason) {
        if (pool != VK_NULL_HANDLE) {
            return true;
        }

        VkDescriptorPoolSize poolSize{};
        poolSize.type            = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
        poolSize.descriptorCount = 3 * kPoolCapacity;

        VkDescriptorPoolCreateInfo poolCI{};
        poolCI.sType         = VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO;
        poolCI.maxSets       = kPoolCapacity;
        poolCI.poolSizeCount = 1;
        poolCI.pPoolSizes    = &poolSize;
        if (vkCreateDescriptorPool(device, &poolCI, nullptr, &pool) != VK_SUCCESS) {
            pool = VK_NULL_HANDLE;
            SetErr(outFailureReason, kErrDescriptorFailed);
            return false;
        }

        std::vector<VkDescriptorSetLayout> layouts(kPoolCapacity, setLayout);
        descriptorSets.resize(kPoolCapacity, VK_NULL_HANDLE);
        VkDescriptorSetAllocateInfo allocInfo{};
        allocInfo.sType              = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO;
        allocInfo.descriptorPool     = pool;
        allocInfo.descriptorSetCount = kPoolCapacity;
        allocInfo.pSetLayouts        = layouts.data();
        if (vkAllocateDescriptorSets(device, &allocInfo, descriptorSets.data()) != VK_SUCCESS) {
            vkDestroyDescriptorPool(device, pool, nullptr);
            pool = VK_NULL_HANDLE;
            descriptorSets.clear();
            SetErr(outFailureReason, kErrDescriptorFailed);
            return false;
        }
        nextSetIndex = 0;
        return true;
    }

    bool ensurePipeline(VkDevice device, VkRenderPass renderPass, std::string* outFailureReason) {
        if (pipeline != VK_NULL_HANDLE) {
            if (renderPass != cachedRenderPass) {
                SetErr(outFailureReason, kErrRenderPassMismatch);
                return false;
            }
            return true;
        }

        VkPipelineShaderStageCreateInfo stages[2]{};
        stages[0].sType  = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO;
        stages[0].stage  = VK_SHADER_STAGE_VERTEX_BIT;
        stages[0].module = vertexShaderModule;
        stages[0].pName  = "main";
        stages[1].sType  = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO;
        stages[1].stage  = VK_SHADER_STAGE_FRAGMENT_BIT;
        stages[1].module = fragmentShaderModule;
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

        // Fixed-function blend disabled; fragment shader mix() output is written directly
        VkPipelineColorBlendAttachmentState attachment{};
        attachment.blendEnable    = VK_FALSE;
        attachment.colorWriteMask = VK_COLOR_COMPONENT_R_BIT | VK_COLOR_COMPONENT_G_BIT |
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
        pipeline         = created;
        cachedRenderPass = renderPass;
        return true;
    }

    void destroyPipeline(VkDevice device) {
        if (pipeline != VK_NULL_HANDLE) {
            vkDestroyPipeline(device, pipeline, nullptr);
            pipeline = VK_NULL_HANDLE;
        }
        cachedRenderPass = VK_NULL_HANDLE;
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
            descriptorSets.clear();
            nextSetIndex = 0;
        }
        if (fragmentShaderModule != VK_NULL_HANDLE) {
            vkDestroyShaderModule(device, fragmentShaderModule, nullptr);
            fragmentShaderModule = VK_NULL_HANDLE;
        }
        if (vertexShaderModule != VK_NULL_HANDLE) {
            vkDestroyShaderModule(device, vertexShaderModule, nullptr);
            vertexShaderModule = VK_NULL_HANDLE;
        }
    }
};

VulkanGreenScreenFrameRenderer::VulkanGreenScreenFrameRenderer() : impl_(std::make_unique<Impl>()) {}
VulkanGreenScreenFrameRenderer::~VulkanGreenScreenFrameRenderer() = default;

bool VulkanGreenScreenFrameRenderer::recordGreenScreenDraw(
    void* devicePtr,
    void* commandBufferPtr,
    uint64_t renderPassHandle,
    uint32_t canvasWidth,
    uint32_t canvasHeight,
    const VulkanGreenScreenFrameInputs& inputs,
    std::string* outFailureReason) {
    if (outFailureReason) outFailureReason->clear();

    if (devicePtr == nullptr || commandBufferPtr == nullptr ||
        renderPassHandle == 0 || canvasWidth == 0 || canvasHeight == 0) {
        SetErr(outFailureReason, kErrInvalidArgument);
        return false;
    }

    if (inputs.backgroundImageView == 0 || inputs.backgroundSampler == 0 ||
        inputs.foregroundImageView == 0 || inputs.foregroundSampler == 0 ||
        inputs.maskImageView == 0 || inputs.maskSampler == 0) {
        SetErr(outFailureReason, kErrInvalidImage);
        return false;
    }

    if (inputs.maskWidth == 0 || inputs.maskHeight == 0) {
        SetErr(outFailureReason, kErrInvalidMaskSize);
        return false;
    }

    VkDevice device               = reinterpret_cast<VkDevice>(devicePtr);
    VkCommandBuffer commandBuffer = reinterpret_cast<VkCommandBuffer>(commandBufferPtr);
    VkRenderPass renderPass       = ToRenderPass(renderPassHandle);

    if (!impl_->ensureShaderModules(device, outFailureReason)) return false;
    if (!impl_->ensureSharedLayouts(device, outFailureReason)) return false;
    if (!impl_->ensureDescriptorPool(device, outFailureReason)) return false;
    if (!impl_->ensurePipeline(device, renderPass, outFailureReason)) return false;

    VkDescriptorSet currentSet = impl_->descriptorSets[impl_->nextSetIndex];
    impl_->nextSetIndex = (impl_->nextSetIndex + 1) % impl_->kPoolCapacity;

    VkDescriptorImageInfo imageInfos[3]{};
    imageInfos[0].sampler     = ToSampler(inputs.backgroundSampler);
    imageInfos[0].imageView   = ToImageView(inputs.backgroundImageView);
    imageInfos[0].imageLayout = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;

    imageInfos[1].sampler     = ToSampler(inputs.foregroundSampler);
    imageInfos[1].imageView   = ToImageView(inputs.foregroundImageView);
    imageInfos[1].imageLayout = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;

    imageInfos[2].sampler     = ToSampler(inputs.maskSampler);
    imageInfos[2].imageView   = ToImageView(inputs.maskImageView);
    imageInfos[2].imageLayout = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;

    VkWriteDescriptorSet writes[3]{};
    for (uint32_t i = 0; i < 3; ++i) {
        writes[i].sType           = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
        writes[i].dstSet          = currentSet;
        writes[i].dstBinding      = i;
        writes[i].dstArrayElement = 0;
        writes[i].descriptorCount = 1;
        writes[i].descriptorType  = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
        writes[i].pImageInfo      = &imageInfos[i];
    }
    vkUpdateDescriptorSets(device, 3, writes, 0, nullptr);

    vkCmdBindPipeline(commandBuffer, VK_PIPELINE_BIND_POINT_GRAPHICS, impl_->pipeline);

    VkViewport viewport{};
    viewport.x        = 0.0f;
    viewport.y        = 0.0f;
    viewport.width    = static_cast<float>(canvasWidth);
    viewport.height   = static_cast<float>(canvasHeight);
    viewport.minDepth = 0.0f;
    viewport.maxDepth = 1.0f;
    vkCmdSetViewport(commandBuffer, 0, 1, &viewport);

    VkRect2D scissor{};
    scissor.offset = {0, 0};
    scissor.extent = {canvasWidth, canvasHeight};
    vkCmdSetScissor(commandBuffer, 0, 1, &scissor);

    vkCmdBindDescriptorSets(commandBuffer, VK_PIPELINE_BIND_POINT_GRAPHICS, impl_->pipelineLayout,
                            0, 1, &currentSet, 0, nullptr);

    VideoTransformFullPushConstants pc{};
    pc.uv.uvTransform0[0] = 1.0f;
    pc.uv.uvTransform1[1] = 1.0f;
    pc.color.row0[0] = 1.0f;
    pc.color.row1[1] = 1.0f;
    pc.color.row2[2] = 1.0f;
    pc.color.row3[3] = 1.0f;
    vkCmdPushConstants(commandBuffer, impl_->pipelineLayout, VK_SHADER_STAGE_VERTEX_BIT,
                       0, static_cast<uint32_t>(sizeof(pc)), &pc);

    vkCmdDraw(commandBuffer, 3, 1, 0, 0);

    return true;
}

void VulkanGreenScreenFrameRenderer::invalidate(void* devicePtr) {
    VkDevice device = reinterpret_cast<VkDevice>(devicePtr);
    if (device == VK_NULL_HANDLE || !impl_) return;
    impl_->destroyPipeline(device);
}

void VulkanGreenScreenFrameRenderer::shutdown(void* devicePtr) {
    VkDevice device = reinterpret_cast<VkDevice>(devicePtr);
    if (device == VK_NULL_HANDLE || !impl_) return;
    impl_->destroyAll(device);
}

} // namespace render
} // namespace vanguard

#else // !defined(__ANDROID__) - host build

namespace vanguard {
namespace render {

struct VulkanGreenScreenFrameRenderer::Impl {};

VulkanGreenScreenFrameRenderer::VulkanGreenScreenFrameRenderer() : impl_(std::make_unique<Impl>()) {}
VulkanGreenScreenFrameRenderer::~VulkanGreenScreenFrameRenderer() = default;

bool VulkanGreenScreenFrameRenderer::recordGreenScreenDraw(
    void* /*device*/,
    void* /*commandBuffer*/,
    uint64_t /*renderPass*/,
    uint32_t /*canvasWidth*/,
    uint32_t /*canvasHeight*/,
    const VulkanGreenScreenFrameInputs& /*inputs*/,
    std::string* outFailureReason) {
    if (outFailureReason) {
        *outFailureReason = "vulkan_greenscreen_frame_renderer_unavailable_on_host";
    }
    return false;
}

void VulkanGreenScreenFrameRenderer::invalidate(void* /*device*/) {
    // no-op on host
}

void VulkanGreenScreenFrameRenderer::shutdown(void* /*device*/) {
    // no-op on host
}

} // namespace render
} // namespace vanguard

#endif // __ANDROID__
