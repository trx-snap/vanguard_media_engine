// vulkan_graphics_pipeline.cpp
// Phase 2L: Vulkan Graphics Pipeline Foundation.
//
// On Android (__ANDROID__):
//   Creates and destroys exactly one VkPipeline object configured for
//   Vulkan 1.1 fullscreen quad rendering with dynamic viewport and scissor.
//
// On non-Android host builds:
//   Provides safe stubs compiling cleanly without the Vulkan SDK.
//
// NOTE: Compute pipeline remains deferred: no compute pipeline is created
// because the current compute shader lacks a storage output target and requires
// descriptor set and pipeline layout expansion.

#include "vulkan_graphics_pipeline.h"

#include <cstring>

#if defined(__ANDROID__)

#include <android/log.h>

#define VGLOG_GP(...) \
    __android_log_print(ANDROID_LOG_DEBUG, "VanguardGraphicsPipeline", __VA_ARGS__)

namespace vanguard {
namespace render {

namespace {

// Portable helper: convert any Vulkan non-dispatchable handle to uint64_t
// without truncation or undefined behaviour.
// Safe on 32-bit (uint64_t handle) and 64-bit (pointer handle) Android ABIs.
template <typename VkHandle>
static inline uint64_t vkHandleToU64(VkHandle h) {
    static_assert(sizeof(VkHandle) <= sizeof(uint64_t),
                  "VkHandle too large for uint64_t");
    uint64_t v = 0;
    // NOLINTNEXTLINE(bugprone-undefined-memory-manipulation)
    std::memcpy(&v, &h, sizeof(VkHandle));
    return v;
}

} // anonymous namespace

// ---------------------------------------------------------------------------
// Move semantics (Android)
// ---------------------------------------------------------------------------

VulkanGraphicsPipeline::VulkanGraphicsPipeline(VulkanGraphicsPipeline&& other) noexcept
    : device_(other.device_),
      pipeline_(other.pipeline_) {
    other.device_ = VK_NULL_HANDLE;
    other.pipeline_ = VK_NULL_HANDLE;
}

VulkanGraphicsPipeline& VulkanGraphicsPipeline::operator=(VulkanGraphicsPipeline&& other) noexcept {
    if (this != &other) {
        destroy(device_);
        device_ = other.device_;
        pipeline_ = other.pipeline_;
        other.device_ = VK_NULL_HANDLE;
        other.pipeline_ = VK_NULL_HANDLE;
    }
    return *this;
}

// ---------------------------------------------------------------------------
// create() (Android)
// ---------------------------------------------------------------------------

bool VulkanGraphicsPipeline::create(VkDevice device,
                                    VkPipelineLayout pipelineLayout,
                                    VkRenderPass renderPass,
                                    VkShaderModule vertShader,
                                    VkShaderModule fragShader) {
    if (device == VK_NULL_HANDLE) {
        VGLOG_GP("create: device is VK_NULL_HANDLE");
        return false;
    }
    if (pipelineLayout == VK_NULL_HANDLE) {
        VGLOG_GP("create: pipelineLayout is VK_NULL_HANDLE");
        return false;
    }
    if (renderPass == VK_NULL_HANDLE) {
        VGLOG_GP("create: renderPass is VK_NULL_HANDLE");
        return false;
    }
    if (vertShader == VK_NULL_HANDLE) {
        VGLOG_GP("create: vertShader is VK_NULL_HANDLE");
        return false;
    }
    if (fragShader == VK_NULL_HANDLE) {
        VGLOG_GP("create: fragShader is VK_NULL_HANDLE");
        return false;
    }

    if (isValid()) {
        VGLOG_GP("create: pipeline already valid; destroying existing pipeline first");
        destroy();
    }

    // 1. Shader Stages (vertex and fragment, entry point main, no specialization)
    VkPipelineShaderStageCreateInfo shaderStages[2]{};

    shaderStages[0].sType  = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO;
    shaderStages[0].stage  = VK_SHADER_STAGE_VERTEX_BIT;
    shaderStages[0].module = vertShader;
    shaderStages[0].pName  = "main";
    shaderStages[0].pSpecializationInfo = nullptr;

    shaderStages[1].sType  = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO;
    shaderStages[1].stage  = VK_SHADER_STAGE_FRAGMENT_BIT;
    shaderStages[1].module = fragShader;
    shaderStages[1].pName  = "main";
    shaderStages[1].pSpecializationInfo = nullptr;

    // 2. Vertex Input State (zero bindings and zero attributes)
    VkPipelineVertexInputStateCreateInfo vertexInputInfo{};
    vertexInputInfo.sType                           = VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO;
    vertexInputInfo.vertexBindingDescriptionCount   = 0;
    vertexInputInfo.pVertexBindingDescriptions      = nullptr;
    vertexInputInfo.vertexAttributeDescriptionCount = 0;
    vertexInputInfo.pVertexAttributeDescriptions     = nullptr;

    // 3. Input Assembly State (VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST, primitiveRestartEnable false)
    VkPipelineInputAssemblyStateCreateInfo inputAssembly{};
    inputAssembly.sType                  = VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO;
    inputAssembly.topology               = VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST;
    inputAssembly.primitiveRestartEnable = VK_FALSE;

    // 4. Dynamic State & Viewport State (viewport and scissor counts 1, dynamic states)
    VkDynamicState dynamicStates[] = {
        VK_DYNAMIC_STATE_VIEWPORT,
        VK_DYNAMIC_STATE_SCISSOR
    };

    VkPipelineDynamicStateCreateInfo dynamicState{};
    dynamicState.sType             = VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO;
    dynamicState.dynamicStateCount = static_cast<uint32_t>(sizeof(dynamicStates) / sizeof(dynamicStates[0]));
    dynamicState.pDynamicStates    = dynamicStates;

    VkPipelineViewportStateCreateInfo viewportState{};
    viewportState.sType         = VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO;
    viewportState.viewportCount = 1;
    viewportState.pViewports    = nullptr;
    viewportState.scissorCount  = 1;
    viewportState.pScissors     = nullptr;

    // 5. Rasterization State (fill, cull none, frontFace CCW, lineWidth 1.0)
    VkPipelineRasterizationStateCreateInfo rasterizer{};
    rasterizer.sType                   = VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO;
    rasterizer.depthClampEnable        = VK_FALSE;
    rasterizer.rasterizerDiscardEnable = VK_FALSE;
    rasterizer.polygonMode             = VK_POLYGON_MODE_FILL;
    rasterizer.cullMode                = VK_CULL_MODE_NONE;
    rasterizer.frontFace               = VK_FRONT_FACE_COUNTER_CLOCKWISE;
    rasterizer.depthBiasEnable         = VK_FALSE;
    rasterizer.depthBiasConstantFactor = 0.0f;
    rasterizer.depthBiasClamp          = 0.0f;
    rasterizer.depthBiasSlopeFactor    = 0.0f;
    rasterizer.lineWidth               = 1.0f;

    // 6. Multisample State (1 sample, sample shading disabled)
    VkPipelineMultisampleStateCreateInfo multisampling{};
    multisampling.sType                 = VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO;
    multisampling.rasterizationSamples  = VK_SAMPLE_COUNT_1_BIT;
    multisampling.sampleShadingEnable   = VK_FALSE;
    multisampling.minSampleShading      = 1.0f;
    multisampling.pSampleMask           = nullptr;
    multisampling.alphaToCoverageEnable = VK_FALSE;
    multisampling.alphaToOneEnable      = VK_FALSE;

    // 7. Color Blend State (one attachment, blend disabled, RGBA write mask)
    VkPipelineColorBlendAttachmentState colorBlendAttachment{};
    colorBlendAttachment.blendEnable         = VK_FALSE;
    colorBlendAttachment.srcColorBlendFactor = VK_BLEND_FACTOR_ONE;
    colorBlendAttachment.dstColorBlendFactor = VK_BLEND_FACTOR_ZERO;
    colorBlendAttachment.colorBlendOp        = VK_BLEND_OP_ADD;
    colorBlendAttachment.srcAlphaBlendFactor = VK_BLEND_FACTOR_ONE;
    colorBlendAttachment.dstAlphaBlendFactor = VK_BLEND_FACTOR_ZERO;
    colorBlendAttachment.alphaBlendOp        = VK_BLEND_OP_ADD;
    colorBlendAttachment.colorWriteMask      = VK_COLOR_COMPONENT_R_BIT |
                                               VK_COLOR_COMPONENT_G_BIT |
                                               VK_COLOR_COMPONENT_B_BIT |
                                               VK_COLOR_COMPONENT_A_BIT;

    VkPipelineColorBlendStateCreateInfo colorBlending{};
    colorBlending.sType           = VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO;
    colorBlending.logicOpEnable   = VK_FALSE;
    colorBlending.logicOp         = VK_LOGIC_OP_COPY;
    colorBlending.attachmentCount = 1;
    colorBlending.pAttachments    = &colorBlendAttachment;
    colorBlending.blendConstants[0] = 0.0f;
    colorBlending.blendConstants[1] = 0.0f;
    colorBlending.blendConstants[2] = 0.0f;
    colorBlending.blendConstants[3] = 0.0f;

    // 8. Assemble VkGraphicsPipelineCreateInfo (Vulkan 1.1)
    VkGraphicsPipelineCreateInfo pipelineInfo{};
    pipelineInfo.sType               = VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO;
    pipelineInfo.stageCount          = 2;
    pipelineInfo.pStages             = shaderStages;
    pipelineInfo.pVertexInputState   = &vertexInputInfo;
    pipelineInfo.pInputAssemblyState = &inputAssembly;
    pipelineInfo.pTessellationState  = nullptr;
    pipelineInfo.pViewportState      = &viewportState;
    pipelineInfo.pRasterizationState = &rasterizer;
    pipelineInfo.pMultisampleState   = &multisampling;
    pipelineInfo.pDepthStencilState  = nullptr;
    pipelineInfo.pColorBlendState    = &colorBlending;
    pipelineInfo.pDynamicState       = &dynamicState;
    pipelineInfo.layout              = pipelineLayout;
    pipelineInfo.renderPass          = renderPass;
    pipelineInfo.subpass             = 0;
    pipelineInfo.basePipelineHandle  = VK_NULL_HANDLE;
    pipelineInfo.basePipelineIndex   = -1;

    VkPipeline newPipeline = VK_NULL_HANDLE;
    VkResult result = vkCreateGraphicsPipelines(
        device,
        VK_NULL_HANDLE,
        1,
        &pipelineInfo,
        nullptr,
        &newPipeline);

    if (result != VK_SUCCESS) {
        VGLOG_GP("vkCreateGraphicsPipelines failed: %d", static_cast<int>(result));
        pipeline_ = VK_NULL_HANDLE;
        device_ = VK_NULL_HANDLE;
        return false;
    }

    pipeline_ = newPipeline;
    device_ = device;
    VGLOG_GP("VkPipeline created successfully");
    return true;
}

// ---------------------------------------------------------------------------
// destroy() (Android)
// ---------------------------------------------------------------------------

void VulkanGraphicsPipeline::destroy(VkDevice device) {
    VkDevice dev = (device != VK_NULL_HANDLE) ? device : device_;
    if (pipeline_ != VK_NULL_HANDLE) {
        if (dev != VK_NULL_HANDLE) {
            vkDestroyPipeline(dev, pipeline_, nullptr);
        }
        pipeline_ = VK_NULL_HANDLE;
    }
    device_ = VK_NULL_HANDLE;
}

// ---------------------------------------------------------------------------
// Accessors (Android)
// ---------------------------------------------------------------------------

bool VulkanGraphicsPipeline::isValid() const {
    return pipeline_ != VK_NULL_HANDLE;
}

uint64_t VulkanGraphicsPipeline::getPipelineHandle() const {
    if (pipeline_ == VK_NULL_HANDLE) {
        return 0;
    }
    return vkHandleToU64(pipeline_);
}

} // namespace render
} // namespace vanguard

#else // !__ANDROID__

// ---------------------------------------------------------------------------
// Non-Android host stubs
// ---------------------------------------------------------------------------

namespace vanguard {
namespace render {

VulkanGraphicsPipeline::VulkanGraphicsPipeline(VulkanGraphicsPipeline&& other) noexcept
    : device_(other.device_),
      pipeline_(other.pipeline_) {
    other.device_ = nullptr;
    other.pipeline_ = nullptr;
}

VulkanGraphicsPipeline& VulkanGraphicsPipeline::operator=(VulkanGraphicsPipeline&& other) noexcept {
    if (this != &other) {
        destroy(device_);
        device_ = other.device_;
        pipeline_ = other.pipeline_;
        other.device_ = nullptr;
        other.pipeline_ = nullptr;
    }
    return *this;
}

bool VulkanGraphicsPipeline::create(void* /*device*/,
                                    void* /*pipelineLayout*/,
                                    void* /*renderPass*/,
                                    void* /*vertShader*/,
                                    void* /*fragShader*/) {
    return false;
}

void VulkanGraphicsPipeline::destroy(void* /*device*/) {
    pipeline_ = nullptr;
    device_ = nullptr;
}

bool VulkanGraphicsPipeline::isValid() const {
    return false;
}

uint64_t VulkanGraphicsPipeline::getPipelineHandle() const {
    return 0;
}

} // namespace render
} // namespace vanguard

#endif // __ANDROID__
