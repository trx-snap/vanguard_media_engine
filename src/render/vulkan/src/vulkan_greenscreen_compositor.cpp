// vulkan_greenscreen_compositor.cpp
// DUET-VULKAN-GREENSCREEN-PIXEL-PROOF: VulkanGreenScreenCompositor
// implementation.
//
// Android-only real implementation is inside #if defined(__ANDROID__).
// Non-Android translation unit compiles to a safe stub that performs no
// Vulkan calls and reports unavailable, matching the other private Vulkan
// helper host stubs. The pure validation, mask texel mapping and CPU
// reference (MapVulkanGreenScreenMaskTexel /
// ComputeVulkanGreenScreenReferencePixel /
// VulkanGreenScreenPixelWithinTolerance / ValidateVulkanGreenScreenInputs)
// compile on every platform.
//
// Every blendGreenScreen() call: validates the target and the three inputs
// (no Vulkan call until all pass), then creates temporary shader modules
// (existing AOT passthrough vertex SPIR-V + the new greenscreen_blend
// fragment SPIR-V), a 3-binding descriptor set layout, one descriptor pool
// holding one set, a pipeline layout (vertex-stage push-constant range
// covering the reused vertex module's 112-byte block), a clear -> store
// render pass, a framebuffer, one blend-disabled fullscreen-triangle
// pipeline, one command buffer from the caller's pool and one fence; records
// one full-viewport draw plus the image-to-buffer copy; submits once; waits
// on the fence; and releases every temporary object before returning on
// every path.

#include "vulkan_greenscreen_compositor.h"

#include <algorithm>
#include <cmath>
#include <cstdlib>
#include <cstring>

#if defined(__ANDROID__)
#include <android/log.h>

#include "shaders/greenscreen_blend_frag_spv.h"
#include "shaders/passthrough_vert_spv.h"
#include "vanguard/render/render_transform.h"
#include "vulkan_shader_module.h"

#define VGLOG_GSC(...) \
    __android_log_print(ANDROID_LOG_DEBUG, "VanguardVkGreenScreen", __VA_ARGS__)
#endif

namespace {

constexpr const char* kErrInvalidArgument = "vulkan_greenscreen_compositor_invalid_argument";
constexpr const char* kErrInvalidFormat   = "vulkan_greenscreen_compositor_invalid_format";
constexpr const char* kErrInvalidImage    = "vulkan_greenscreen_compositor_invalid_image";
constexpr const char* kErrInvalidMaskSize = "vulkan_greenscreen_compositor_invalid_mask_size";
[[maybe_unused]] constexpr const char* kErrShaderModule  = "vulkan_greenscreen_compositor_shader_module_failed";
[[maybe_unused]] constexpr const char* kErrDescriptor    = "vulkan_greenscreen_compositor_descriptor_failed";
[[maybe_unused]] constexpr const char* kErrRenderPass    = "vulkan_greenscreen_compositor_render_pass_failed";
[[maybe_unused]] constexpr const char* kErrPipeline      = "vulkan_greenscreen_compositor_pipeline_failed";
[[maybe_unused]] constexpr const char* kErrCommandBuffer = "vulkan_greenscreen_compositor_command_buffer_failed";
[[maybe_unused]] constexpr const char* kErrSubmit        = "vulkan_greenscreen_compositor_submit_failed";
[[maybe_unused]] constexpr const char* kErrWait          = "vulkan_greenscreen_compositor_wait_failed";

void SetError(std::string* outError, const char* reason) {
    if (outError) *outError = reason;
}

bool SampledImageNull(const vanguard::render::VulkanGreenScreenSampledImage& img) {
#if defined(__ANDROID__)
    return img.imageView == VK_NULL_HANDLE || img.sampler == VK_NULL_HANDLE;
#else
    return img.imageView == nullptr || img.sampler == nullptr;
#endif
}

bool TargetHandlesNull(const vanguard::render::VulkanGreenScreenRenderTarget& t) {
#if defined(__ANDROID__)
    return t.device == VK_NULL_HANDLE || t.queue == VK_NULL_HANDLE ||
           t.commandPool == VK_NULL_HANDLE || t.colorImage == VK_NULL_HANDLE ||
           t.colorImageView == VK_NULL_HANDLE || t.readbackBuffer == VK_NULL_HANDLE;
#else
    return t.device == nullptr || t.queue == nullptr || t.commandPool == nullptr ||
           t.colorImage == nullptr || t.colorImageView == nullptr || t.readbackBuffer == nullptr;
#endif
}

} // namespace

namespace vanguard {
namespace render {

VulkanGreenScreenCompositor::VulkanGreenScreenCompositor() = default;
VulkanGreenScreenCompositor::~VulkanGreenScreenCompositor() = default;

// ── Pure CPU reference + validation (all platforms) ─────────────────────────

bool MapVulkanGreenScreenMaskTexel(uint32_t x,
                                   uint32_t y,
                                   uint32_t outputWidth,
                                   uint32_t outputHeight,
                                   uint32_t maskWidth,
                                   uint32_t maskHeight,
                                   uint32_t* outMaskX,
                                   uint32_t* outMaskY) {
    if (outMaskX == nullptr || outMaskY == nullptr) return false;
    if (outputWidth == 0 || outputHeight == 0 || maskWidth == 0 || maskHeight == 0) return false;
    if (x >= outputWidth || y >= outputHeight) return false;
    // floor((x + 0.5) * maskWidth / outputWidth) == ((2x + 1) * maskWidth) / (2 * outputWidth)
    // in exact integer arithmetic (64-bit to stay overflow-free).
    const uint64_t mx = ((2ull * x + 1ull) * maskWidth) / (2ull * outputWidth);
    const uint64_t my = ((2ull * y + 1ull) * maskHeight) / (2ull * outputHeight);
    *outMaskX = static_cast<uint32_t>(std::min<uint64_t>(mx, maskWidth - 1ull));
    *outMaskY = static_cast<uint32_t>(std::min<uint64_t>(my, maskHeight - 1ull));
    return true;
}

void ComputeVulkanGreenScreenReferencePixel(const uint8_t background[4],
                                            const uint8_t foreground[4],
                                            uint8_t maskValue,
                                            uint8_t outPixel[4]) {
    const double m = static_cast<double>(maskValue);
    for (int c = 0; c < 4; ++c) {
        const double bg = static_cast<double>(background[c]);
        const double fg = static_cast<double>(foreground[c]);
        // 255 * mix(bg/255, fg/255, m/255) == (bg * (255 - m) + fg * m) / 255.
        const double v = (bg * (255.0 - m) + fg * m) / 255.0;
        long r = std::lround(v); // round-half-away-from-zero
        if (r < 0) r = 0;
        if (r > 255) r = 255;
        outPixel[c] = static_cast<uint8_t>(r);
    }
}

bool VulkanGreenScreenPixelWithinTolerance(const uint8_t actual[4],
                                           const uint8_t expected[4],
                                           int tolerance,
                                           int* outMaxDelta) {
    int maxDelta = 0;
    for (int c = 0; c < 4; ++c) {
        const int d = std::abs(static_cast<int>(actual[c]) - static_cast<int>(expected[c]));
        if (d > maxDelta) maxDelta = d;
    }
    if (outMaxDelta) *outMaxDelta = maxDelta;
    return maxDelta <= tolerance;
}

bool ValidateVulkanGreenScreenInputs(const VulkanGreenScreenRenderTarget& target,
                                     const VulkanGreenScreenInputs& inputs,
                                     std::string* outError) {
    const uint64_t requiredReadbackBytes =
        static_cast<uint64_t>(target.extentWidth) * static_cast<uint64_t>(target.extentHeight) * 4ull;
    if (TargetHandlesNull(target) || target.extentWidth == 0 || target.extentHeight == 0 ||
        static_cast<uint64_t>(target.readbackBufferSizeBytes) < requiredReadbackBytes) {
        SetError(outError, kErrInvalidArgument);
        return false;
    }
    if (static_cast<uint32_t>(target.colorFormat) != kVulkanGreenScreenColorFormatValue) {
        SetError(outError, kErrInvalidFormat);
        return false;
    }
    if (SampledImageNull(inputs.background) || SampledImageNull(inputs.foreground) ||
        SampledImageNull(inputs.mask)) {
        SetError(outError, kErrInvalidImage);
        return false;
    }
    if (inputs.maskWidth == 0 || inputs.maskHeight == 0) {
        SetError(outError, kErrInvalidMaskSize);
        return false;
    }
    if (outError) outError->clear();
    return true;
}

#if defined(__ANDROID__)
namespace {

constexpr uint64_t kFenceTimeoutNs = 5000000000ull; // 5 s

// The reused passthrough_vert_spv.h vertex module declares the full 112-byte
// VideoTransformFullPushConstants block; the pipeline layout's vertex-stage
// range must cover all of it even though only the two UV rows matter here.
constexpr uint32_t kVertexPushConstantBytes = static_cast<uint32_t>(sizeof(VideoTransformFullPushConstants));
static_assert(kVertexPushConstantBytes == 112u, "VideoTransformFullPushConstants must be 112 bytes");

// Every temporary Vulkan object one blendGreenScreen() call creates.
// Release() destroys / frees each non-null handle in reverse dependency
// order and counts releases so the owner can prove created == released. The
// descriptor set is freed implicitly with its pool (the pool is the counted
// object).
struct Temporaries {
    VkDevice              device         = VK_NULL_HANDLE;
    VkCommandPool         commandPool    = VK_NULL_HANDLE;
    VulkanShaderModule    vertex;
    VulkanShaderModule    fragment;
    VkDescriptorSetLayout setLayout      = VK_NULL_HANDLE;
    VkDescriptorPool      descriptorPool = VK_NULL_HANDLE;
    VkDescriptorSet       set            = VK_NULL_HANDLE; // freed with the pool
    VkPipelineLayout      pipelineLayout = VK_NULL_HANDLE;
    VkRenderPass          renderPass     = VK_NULL_HANDLE;
    VkFramebuffer         framebuffer    = VK_NULL_HANDLE;
    VkPipeline            pipeline       = VK_NULL_HANDLE;
    VkCommandBuffer       commandBuffer  = VK_NULL_HANDLE;
    VkFence               fence          = VK_NULL_HANDLE;
    uint64_t              created        = 0;
    uint64_t              released       = 0;

    void Release() {
        if (fence != VK_NULL_HANDLE) {
            vkDestroyFence(device, fence, nullptr);
            fence = VK_NULL_HANDLE;
            ++released;
        }
        if (commandBuffer != VK_NULL_HANDLE) {
            vkFreeCommandBuffers(device, commandPool, 1, &commandBuffer);
            commandBuffer = VK_NULL_HANDLE;
            ++released;
        }
        if (pipeline != VK_NULL_HANDLE) {
            vkDestroyPipeline(device, pipeline, nullptr);
            pipeline = VK_NULL_HANDLE;
            ++released;
        }
        if (framebuffer != VK_NULL_HANDLE) {
            vkDestroyFramebuffer(device, framebuffer, nullptr);
            framebuffer = VK_NULL_HANDLE;
            ++released;
        }
        if (renderPass != VK_NULL_HANDLE) {
            vkDestroyRenderPass(device, renderPass, nullptr);
            renderPass = VK_NULL_HANDLE;
            ++released;
        }
        if (pipelineLayout != VK_NULL_HANDLE) {
            vkDestroyPipelineLayout(device, pipelineLayout, nullptr);
            pipelineLayout = VK_NULL_HANDLE;
            ++released;
        }
        if (descriptorPool != VK_NULL_HANDLE) {
            vkDestroyDescriptorPool(device, descriptorPool, nullptr);
            descriptorPool = VK_NULL_HANDLE;
            set = VK_NULL_HANDLE;
            ++released;
        }
        if (setLayout != VK_NULL_HANDLE) {
            vkDestroyDescriptorSetLayout(device, setLayout, nullptr);
            setLayout = VK_NULL_HANDLE;
            ++released;
        }
        if (fragment.get() != VK_NULL_HANDLE) {
            fragment.destroy(device);
            ++released;
        }
        if (vertex.get() != VK_NULL_HANDLE) {
            vertex.destroy(device);
            ++released;
        }
    }
};

bool CreateShaderModules(Temporaries& t, std::string* outError) {
    if (!t.vertex.create(t.device, shaders::kPassthroughVertSpv, shaders::kPassthroughVertSpvSize,
                         "greenscreen_passthrough_vert")) {
        SetError(outError, kErrShaderModule);
        return false;
    }
    ++t.created;
    if (!t.fragment.create(t.device, shaders::kGreenScreenBlendFragSpv, shaders::kGreenScreenBlendFragSpvSize,
                           "greenscreen_blend_frag")) {
        SetError(outError, kErrShaderModule);
        return false;
    }
    ++t.created;
    return true;
}

// Descriptor set layout (bindings 0/1/2 = background/foreground/mask
// combined image samplers, fragment stage), one pool with one set written
// with the caller's three view/sampler pairs, and the pipeline layout
// carrying the vertex-stage 112-byte push-constant range.
bool CreateDescriptorObjects(Temporaries& t,
                             const VulkanGreenScreenInputs& inputs,
                             std::string* outError) {
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
    if (vkCreateDescriptorSetLayout(t.device, &layoutCI, nullptr, &t.setLayout) != VK_SUCCESS) {
        t.setLayout = VK_NULL_HANDLE;
        SetError(outError, kErrDescriptor);
        return false;
    }
    ++t.created;

    VkDescriptorPoolSize poolSize{};
    poolSize.type            = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
    poolSize.descriptorCount = 3;

    VkDescriptorPoolCreateInfo poolCI{};
    poolCI.sType         = VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO;
    poolCI.maxSets       = 1;
    poolCI.poolSizeCount = 1;
    poolCI.pPoolSizes    = &poolSize;
    if (vkCreateDescriptorPool(t.device, &poolCI, nullptr, &t.descriptorPool) != VK_SUCCESS) {
        t.descriptorPool = VK_NULL_HANDLE;
        SetError(outError, kErrDescriptor);
        return false;
    }
    ++t.created;

    VkDescriptorSetAllocateInfo allocInfo{};
    allocInfo.sType              = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO;
    allocInfo.descriptorPool     = t.descriptorPool;
    allocInfo.descriptorSetCount = 1;
    allocInfo.pSetLayouts        = &t.setLayout;
    if (vkAllocateDescriptorSets(t.device, &allocInfo, &t.set) != VK_SUCCESS) {
        t.set = VK_NULL_HANDLE;
        SetError(outError, kErrDescriptor);
        return false;
    }

    const VulkanGreenScreenSampledImage* sources[3] = {
        &inputs.background, &inputs.foreground, &inputs.mask};
    VkDescriptorImageInfo imageInfos[3]{};
    VkWriteDescriptorSet  writes[3]{};
    for (uint32_t i = 0; i < 3; ++i) {
        imageInfos[i].sampler     = sources[i]->sampler;
        imageInfos[i].imageView   = sources[i]->imageView;
        imageInfos[i].imageLayout = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
        writes[i].sType           = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
        writes[i].dstSet          = t.set;
        writes[i].dstBinding      = i;
        writes[i].dstArrayElement = 0;
        writes[i].descriptorCount = 1;
        writes[i].descriptorType  = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
        writes[i].pImageInfo      = &imageInfos[i];
    }
    vkUpdateDescriptorSets(t.device, 3, writes, 0, nullptr);

    VkPushConstantRange vertexRange{};
    vertexRange.stageFlags = VK_SHADER_STAGE_VERTEX_BIT;
    vertexRange.offset     = 0;
    vertexRange.size       = kVertexPushConstantBytes;

    VkPipelineLayoutCreateInfo plCI{};
    plCI.sType                  = VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO;
    plCI.setLayoutCount         = 1;
    plCI.pSetLayouts            = &t.setLayout;
    plCI.pushConstantRangeCount = 1;
    plCI.pPushConstantRanges    = &vertexRange;
    if (vkCreatePipelineLayout(t.device, &plCI, nullptr, &t.pipelineLayout) != VK_SUCCESS) {
        t.pipelineLayout = VK_NULL_HANDLE;
        SetError(outError, kErrDescriptor);
        return false;
    }
    ++t.created;
    return true;
}

// Single-attachment render pass (clear -> store, UNDEFINED ->
// TRANSFER_SRC_OPTIMAL) plus the framebuffer over the caller's color view.
bool CreateRenderPassObjects(Temporaries& t,
                             const VulkanGreenScreenRenderTarget& target,
                             std::string* outError) {
    VkAttachmentDescription color{};
    color.format         = target.colorFormat;
    color.samples        = VK_SAMPLE_COUNT_1_BIT;
    color.loadOp         = VK_ATTACHMENT_LOAD_OP_CLEAR;
    color.storeOp        = VK_ATTACHMENT_STORE_OP_STORE;
    color.stencilLoadOp  = VK_ATTACHMENT_LOAD_OP_DONT_CARE;
    color.stencilStoreOp = VK_ATTACHMENT_STORE_OP_DONT_CARE;
    color.initialLayout  = VK_IMAGE_LAYOUT_UNDEFINED;
    color.finalLayout    = VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL;

    VkAttachmentReference colorRef{};
    colorRef.attachment = 0;
    colorRef.layout     = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL;

    VkSubpassDescription subpass{};
    subpass.pipelineBindPoint    = VK_PIPELINE_BIND_POINT_GRAPHICS;
    subpass.colorAttachmentCount = 1;
    subpass.pColorAttachments    = &colorRef;

    VkSubpassDependency deps[2]{};
    deps[0].srcSubpass    = VK_SUBPASS_EXTERNAL;
    deps[0].dstSubpass    = 0;
    deps[0].srcStageMask  = VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT | VK_PIPELINE_STAGE_TRANSFER_BIT;
    deps[0].dstStageMask  = VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT;
    deps[0].srcAccessMask = VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT | VK_ACCESS_TRANSFER_READ_BIT;
    deps[0].dstAccessMask = VK_ACCESS_COLOR_ATTACHMENT_READ_BIT | VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT;
    deps[1].srcSubpass    = 0;
    deps[1].dstSubpass    = VK_SUBPASS_EXTERNAL;
    deps[1].srcStageMask  = VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT;
    deps[1].dstStageMask  = VK_PIPELINE_STAGE_TRANSFER_BIT;
    deps[1].srcAccessMask = VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT;
    deps[1].dstAccessMask = VK_ACCESS_TRANSFER_READ_BIT;

    VkRenderPassCreateInfo rpCI{};
    rpCI.sType           = VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO;
    rpCI.attachmentCount = 1;
    rpCI.pAttachments    = &color;
    rpCI.subpassCount    = 1;
    rpCI.pSubpasses      = &subpass;
    rpCI.dependencyCount = 2;
    rpCI.pDependencies   = deps;
    if (vkCreateRenderPass(t.device, &rpCI, nullptr, &t.renderPass) != VK_SUCCESS) {
        t.renderPass = VK_NULL_HANDLE;
        SetError(outError, kErrRenderPass);
        return false;
    }
    ++t.created;

    VkFramebufferCreateInfo fbCI{};
    fbCI.sType           = VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO;
    fbCI.renderPass      = t.renderPass;
    fbCI.attachmentCount = 1;
    fbCI.pAttachments    = &target.colorImageView;
    fbCI.width           = target.extentWidth;
    fbCI.height          = target.extentHeight;
    fbCI.layers          = 1;
    if (vkCreateFramebuffer(t.device, &fbCI, nullptr, &t.framebuffer) != VK_SUCCESS) {
        t.framebuffer = VK_NULL_HANDLE;
        SetError(outError, kErrRenderPass);
        return false;
    }
    ++t.created;
    return true;
}

// Fullscreen-triangle graphics pipeline (no vertex input, dynamic
// viewport/scissor) with the fixed-function blend stage DISABLED: the
// fragment shader's mix() result is written straight to the attachment.
bool CreateBlendPipeline(Temporaries& t, std::string* outError) {
    VkPipelineShaderStageCreateInfo stages[2]{};
    stages[0].sType  = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO;
    stages[0].stage  = VK_SHADER_STAGE_VERTEX_BIT;
    stages[0].module = t.vertex.get();
    stages[0].pName  = "main";
    stages[1].sType  = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO;
    stages[1].stage  = VK_SHADER_STAGE_FRAGMENT_BIT;
    stages[1].module = t.fragment.get();
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

    VkPipelineColorBlendAttachmentState attachment{};
    attachment.blendEnable    = VK_FALSE; // pinned: shader mix only, no fixed-function blend
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
    pipelineCI.layout              = t.pipelineLayout;
    pipelineCI.renderPass          = t.renderPass;
    pipelineCI.subpass             = 0;
    pipelineCI.basePipelineIndex   = -1;

    VkPipeline pipeline = VK_NULL_HANDLE;
    if (vkCreateGraphicsPipelines(t.device, VK_NULL_HANDLE, 1, &pipelineCI, nullptr, &pipeline) != VK_SUCCESS) {
        t.pipeline = VK_NULL_HANDLE;
        SetError(outError, kErrPipeline);
        return false;
    }
    t.pipeline = pipeline;
    ++t.created;
    return true;
}

// Identity UV rows (u = x, v = y over the full viewport) plus an identity
// colour matrix for completeness; the fragment stage never reads the block.
VideoTransformFullPushConstants IdentityPushConstants() {
    VideoTransformFullPushConstants pc{};
    pc.uv.uvTransform0[0] = 1.0f;
    pc.uv.uvTransform1[1] = 1.0f;
    pc.color.row0[0] = 1.0f;
    pc.color.row1[1] = 1.0f;
    pc.color.row2[2] = 1.0f;
    pc.color.row3[3] = 1.0f;
    return pc;
}

// Allocates + records the whole command buffer: clear render pass with one
// full-viewport fullscreen-triangle draw, then the image-to-buffer copy and
// host-read barrier.
bool RecordCommands(Temporaries& t,
                    const VulkanGreenScreenRenderTarget& target,
                    std::string* outError) {
    VkCommandBufferAllocateInfo cbAI{};
    cbAI.sType              = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO;
    cbAI.commandPool        = t.commandPool;
    cbAI.level              = VK_COMMAND_BUFFER_LEVEL_PRIMARY;
    cbAI.commandBufferCount = 1;
    if (vkAllocateCommandBuffers(t.device, &cbAI, &t.commandBuffer) != VK_SUCCESS) {
        t.commandBuffer = VK_NULL_HANDLE;
        SetError(outError, kErrCommandBuffer);
        return false;
    }
    ++t.created;

    VkCommandBufferBeginInfo beginInfo{};
    beginInfo.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
    beginInfo.flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
    if (vkBeginCommandBuffer(t.commandBuffer, &beginInfo) != VK_SUCCESS) {
        SetError(outError, kErrCommandBuffer);
        return false;
    }

    VkClearValue clearValue{};
    clearValue.color = target.clearColor;

    VkRenderPassBeginInfo rpBegin{};
    rpBegin.sType             = VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO;
    rpBegin.renderPass        = t.renderPass;
    rpBegin.framebuffer       = t.framebuffer;
    rpBegin.renderArea.offset = {0, 0};
    rpBegin.renderArea.extent = {target.extentWidth, target.extentHeight};
    rpBegin.clearValueCount   = 1;
    rpBegin.pClearValues      = &clearValue;
    vkCmdBeginRenderPass(t.commandBuffer, &rpBegin, VK_SUBPASS_CONTENTS_INLINE);

    VkViewport viewport{};
    viewport.x        = 0.0f;
    viewport.y        = 0.0f;
    viewport.width    = static_cast<float>(target.extentWidth);
    viewport.height   = static_cast<float>(target.extentHeight);
    viewport.minDepth = 0.0f;
    viewport.maxDepth = 1.0f;
    vkCmdSetViewport(t.commandBuffer, 0, 1, &viewport);
    VkRect2D scissor{};
    scissor.offset = {0, 0};
    scissor.extent = {target.extentWidth, target.extentHeight};
    vkCmdSetScissor(t.commandBuffer, 0, 1, &scissor);

    vkCmdBindPipeline(t.commandBuffer, VK_PIPELINE_BIND_POINT_GRAPHICS, t.pipeline);
    vkCmdBindDescriptorSets(t.commandBuffer, VK_PIPELINE_BIND_POINT_GRAPHICS, t.pipelineLayout,
                            0, 1, &t.set, 0, nullptr);
    const VideoTransformFullPushConstants pc = IdentityPushConstants();
    vkCmdPushConstants(t.commandBuffer, t.pipelineLayout, VK_SHADER_STAGE_VERTEX_BIT,
                       0, kVertexPushConstantBytes, &pc);
    vkCmdDraw(t.commandBuffer, 3, 1, 0, 0);
    vkCmdEndRenderPass(t.commandBuffer);

    VkBufferImageCopy region{};
    region.bufferOffset                    = 0;
    region.bufferRowLength                 = 0; // tightly packed
    region.bufferImageHeight               = 0;
    region.imageSubresource.aspectMask     = VK_IMAGE_ASPECT_COLOR_BIT;
    region.imageSubresource.mipLevel       = 0;
    region.imageSubresource.baseArrayLayer = 0;
    region.imageSubresource.layerCount     = 1;
    region.imageOffset                     = {0, 0, 0};
    region.imageExtent                     = {target.extentWidth, target.extentHeight, 1};
    vkCmdCopyImageToBuffer(t.commandBuffer, target.colorImage, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
                           target.readbackBuffer, 1, &region);

    VkBufferMemoryBarrier hostBarrier{};
    hostBarrier.sType               = VK_STRUCTURE_TYPE_BUFFER_MEMORY_BARRIER;
    hostBarrier.srcAccessMask       = VK_ACCESS_TRANSFER_WRITE_BIT;
    hostBarrier.dstAccessMask       = VK_ACCESS_HOST_READ_BIT;
    hostBarrier.srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
    hostBarrier.dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
    hostBarrier.buffer              = target.readbackBuffer;
    hostBarrier.offset              = 0;
    hostBarrier.size                = VK_WHOLE_SIZE;
    vkCmdPipelineBarrier(t.commandBuffer, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_HOST_BIT,
                         0, 0, nullptr, 1, &hostBarrier, 0, nullptr);

    if (vkEndCommandBuffer(t.commandBuffer) != VK_SUCCESS) {
        SetError(outError, kErrCommandBuffer);
        return false;
    }
    return true;
}

// Submits once with a fresh fence and waits. On a wait timeout / failure the
// queue is drained with vkQueueWaitIdle so Release() never destroys objects
// still in flight.
bool SubmitAndWait(Temporaries& t, VkQueue queue, std::string* outError) {
    VkFenceCreateInfo fenceCI{};
    fenceCI.sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO;
    if (vkCreateFence(t.device, &fenceCI, nullptr, &t.fence) != VK_SUCCESS) {
        t.fence = VK_NULL_HANDLE;
        SetError(outError, kErrSubmit);
        return false;
    }
    ++t.created;

    VkSubmitInfo submit{};
    submit.sType              = VK_STRUCTURE_TYPE_SUBMIT_INFO;
    submit.commandBufferCount = 1;
    submit.pCommandBuffers    = &t.commandBuffer;
    if (vkQueueSubmit(queue, 1, &submit, t.fence) != VK_SUCCESS) {
        SetError(outError, kErrSubmit);
        return false;
    }

    const VkResult waitResult = vkWaitForFences(t.device, 1, &t.fence, VK_TRUE, kFenceTimeoutNs);
    if (waitResult != VK_SUCCESS) {
        VGLOG_GSC("vkWaitForFences returned %d; draining queue before release", static_cast<int>(waitResult));
        vkQueueWaitIdle(queue);
        SetError(outError, kErrWait);
        return false;
    }
    return true;
}

} // namespace
#endif // __ANDROID__

bool VulkanGreenScreenCompositor::blendGreenScreen(const VulkanGreenScreenRenderTarget& target,
                                                   const VulkanGreenScreenInputs& inputs,
                                                   std::string* outError) {
    if (outError) {
        outError->clear();
    }

#if defined(__ANDROID__)
    // Fail-closed validation: no Vulkan call is issued until every check passes.
    if (!ValidateVulkanGreenScreenInputs(target, inputs, outError)) {
        return false;
    }

    // Vulkan work. Every temporary object is released on every path below.
    Temporaries t;
    t.device      = target.device;
    t.commandPool = target.commandPool;

    const bool ok = CreateShaderModules(t, outError) &&
                    CreateDescriptorObjects(t, inputs, outError) &&
                    CreateRenderPassObjects(t, target, outError) &&
                    CreateBlendPipeline(t, outError) &&
                    RecordCommands(t, target, outError) &&
                    SubmitAndWait(t, target.queue, outError);

    t.Release();
    temporaryObjectsCreated_  += t.created;
    temporaryObjectsReleased_ += t.released;
    if (t.created != t.released) {
        VGLOG_GSC("temporary object count mismatch: created=%llu released=%llu",
                  static_cast<unsigned long long>(t.created),
                  static_cast<unsigned long long>(t.released));
    }
    return ok;
#else
    (void)target;
    (void)inputs;
    SetError(outError, "vulkan_greenscreen_compositor_unavailable_on_host");
    return false;
#endif
}

} // namespace render
} // namespace vanguard
