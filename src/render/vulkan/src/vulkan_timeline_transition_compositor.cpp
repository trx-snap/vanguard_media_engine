// vulkan_timeline_transition_compositor.cpp
// P5-COMPOSITOR-TRANS (sub-slice VULKAN-RENDER): VulkanTimelineTransitionCompositor
// implementation.
//
// Android-only real implementation is inside #if defined(__ANDROID__).
// Non-Android translation unit compiles to a safe stub that performs no
// Vulkan calls and reports unavailable, matching the other private Vulkan
// helper host stubs. The pure placement math
// (ResolveVulkanTimelineLayerPlacement) compiles on every platform.
//
// Every renderTransition() call creates temporary shader modules (from the
// existing AOT passthrough SPIR-V), descriptor set layout / pool / two sets,
// pipeline layout, render pass, framebuffer, one opaque pipeline (plus one
// constant-alpha blend pipeline when a crossfade mix is needed), one command
// buffer from the caller's pool and one fence; records the clear + layer draws
// + image-to-buffer copy; submits once; waits on the fence; and releases every
// temporary object before returning on every path. No new GLSL/SPIR-V exists
// for this helper: crop UVs ride in the push-constant UV transform rows and
// canvas placement rides in dynamic viewport/scissor; crossfade uses
// fixed-function blending with dynamic blend constants.

#include "vulkan_timeline_transition_compositor.h"

#include <algorithm>
#include <cmath>
#include <cstring>

#if defined(__ANDROID__)
#include <android/log.h>

#include "shaders/passthrough_frag_spv.h"
#include "shaders/passthrough_vert_spv.h"
#include "vanguard/render/render_transform.h"
#include "vulkan_shader_module.h"

#define VGLOG_TTC(...) \
    __android_log_print(ANDROID_LOG_DEBUG, "VanguardVkTimelineTransition", __VA_ARGS__)
#endif

namespace {

constexpr double kRectEpsilon = 1e-9;

bool IsFiniteRect(const vanguard::render::VulkanTimelineNormalizedRect& r) {
    return std::isfinite(r.x) && std::isfinite(r.y) &&
           std::isfinite(r.width) && std::isfinite(r.height);
}

[[maybe_unused]] bool HasNonNegativeExtent(const vanguard::render::VulkanTimelineNormalizedRect& r) {
    return r.width >= 0.0 && r.height >= 0.0;
}

[[maybe_unused]] bool IsCropInsideUnit(const vanguard::render::VulkanTimelineNormalizedRect& r) {
    return r.x >= -kRectEpsilon && r.y >= -kRectEpsilon &&
           (r.x + r.width) <= 1.0 + kRectEpsilon &&
           (r.y + r.height) <= 1.0 + kRectEpsilon;
}

[[maybe_unused]] bool IsIdentityRect(const vanguard::render::VulkanTimelineNormalizedRect& r) {
    return std::fabs(r.x) <= kRectEpsilon && std::fabs(r.y) <= kRectEpsilon &&
           std::fabs(r.width - 1.0) <= kRectEpsilon && std::fabs(r.height - 1.0) <= kRectEpsilon;
}

double ClampUnit(double v) {
    return std::min(1.0, std::max(0.0, v));
}
} // namespace

namespace vanguard {
namespace render {

VulkanTimelineTransitionCompositor::VulkanTimelineTransitionCompositor() = default;
VulkanTimelineTransitionCompositor::~VulkanTimelineTransitionCompositor() = default;

// ── Pure placement math (all platforms) ─────────────────────────────────────

VulkanTimelineLayerPlacement ResolveVulkanTimelineLayerPlacement(
    const VulkanTimelineNormalizedRect& viewport,
    const VulkanTimelineNormalizedRect& crop,
    uint32_t extentWidth,
    uint32_t extentHeight) {
    VulkanTimelineLayerPlacement out;
    if (!IsFiniteRect(viewport) || !IsFiniteRect(crop) ||
        extentWidth == 0 || extentHeight == 0) {
        return out;
    }

    // Destination canvas rect of the visible (cropped) part of the layer, in
    // top-left normalized canvas coordinates.
    const double x0 = viewport.x + crop.x * viewport.width;
    const double y0 = viewport.y + crop.y * viewport.height;
    const double x1 = x0 + crop.width * viewport.width;
    const double y1 = y0 + crop.height * viewport.height;
    if (!(x1 > x0) || !(y1 > y0)) {
        return out; // zero or negative extent: nothing visible
    }

    // Clip to the canvas.
    const double cx0 = std::max(x0, 0.0);
    const double cy0 = std::max(y0, 0.0);
    const double cx1 = std::min(x1, 1.0);
    const double cy1 = std::min(y1, 1.0);
    if (!(cx1 > cx0) || !(cy1 > cy0)) {
        return out; // fully off-canvas
    }

    // Pixel rect in top-left origin (Vulkan framebuffer convention).
    const long pxLeft   = std::lround(cx0 * static_cast<double>(extentWidth));
    const long pxRight  = std::lround(cx1 * static_cast<double>(extentWidth));
    const long pxTop    = std::lround(cy0 * static_cast<double>(extentHeight));
    const long pxBottom = std::lround(cy1 * static_cast<double>(extentHeight));
    if (pxRight <= pxLeft || pxBottom <= pxTop) {
        return out; // rounds to zero pixels
    }

    // Advance the sampled crop range by the clipped fractions. No V flip:
    // texel row 0 is the top row and canvas row 0 is the top row.
    const double fx0 = (cx0 - x0) / (x1 - x0);
    const double fx1 = (cx1 - x0) / (x1 - x0);
    const double fy0 = (cy0 - y0) / (y1 - y0);
    const double fy1 = (cy1 - y0) / (y1 - y0);
    const double u0 = crop.x + fx0 * crop.width;
    const double u1 = crop.x + fx1 * crop.width;
    const double v0 = crop.y + fy0 * crop.height;
    const double v1 = crop.y + fy1 * crop.height;

    out.visible  = true;
    out.xPx      = static_cast<int32_t>(pxLeft);
    out.yTopPx   = static_cast<int32_t>(pxTop);
    out.widthPx  = static_cast<uint32_t>(pxRight - pxLeft);
    out.heightPx = static_cast<uint32_t>(pxBottom - pxTop);
    out.u0       = static_cast<float>(ClampUnit(u0));
    out.u1       = static_cast<float>(ClampUnit(u1));
    out.v0       = static_cast<float>(ClampUnit(v0));
    out.v1       = static_cast<float>(ClampUnit(v1));
    return out;
}

#if defined(__ANDROID__)
namespace {

constexpr uint64_t kFenceTimeoutNs = 5000000000ull; // 5 s

constexpr const char* kErrInvalidArgument      = "vulkan_timeline_transition_compositor_invalid_argument";
constexpr const char* kErrInvalidProgress      = "vulkan_timeline_transition_compositor_invalid_progress";
constexpr const char* kErrInvalidWeight        = "vulkan_timeline_transition_compositor_invalid_blend_weight";
constexpr const char* kErrInvalidGeometry      = "vulkan_timeline_transition_compositor_invalid_geometry";
constexpr const char* kErrUnsupportedGeometry  = "vulkan_timeline_transition_compositor_unsupported_geometry";
constexpr const char* kErrShaderModule         = "vulkan_timeline_transition_compositor_shader_module_failed";
constexpr const char* kErrDescriptor           = "vulkan_timeline_transition_compositor_descriptor_failed";
constexpr const char* kErrRenderPass           = "vulkan_timeline_transition_compositor_render_pass_failed";
constexpr const char* kErrPipeline             = "vulkan_timeline_transition_compositor_pipeline_failed";
constexpr const char* kErrCommandBuffer        = "vulkan_timeline_transition_compositor_command_buffer_failed";
constexpr const char* kErrSubmit               = "vulkan_timeline_transition_compositor_submit_failed";
constexpr const char* kErrWait                 = "vulkan_timeline_transition_compositor_wait_failed";

// Every temporary Vulkan object one renderTransition() call creates. Release()
// destroys / frees each non-null handle in reverse dependency order and
// counts releases so the owner can prove created == released.
struct Temporaries {
    VkDevice              device         = VK_NULL_HANDLE;
    VkCommandPool         commandPool    = VK_NULL_HANDLE;
    VulkanShaderModule    vertex;
    VulkanShaderModule    fragment;
    VkDescriptorSetLayout setLayout      = VK_NULL_HANDLE;
    VkDescriptorPool      descriptorPool = VK_NULL_HANDLE;
    VkDescriptorSet       setFrom        = VK_NULL_HANDLE; // freed with the pool
    VkDescriptorSet       setTo          = VK_NULL_HANDLE; // freed with the pool
    VkPipelineLayout      pipelineLayout = VK_NULL_HANDLE;
    VkRenderPass          renderPass     = VK_NULL_HANDLE;
    VkFramebuffer         framebuffer    = VK_NULL_HANDLE;
    VkPipeline            opaquePipeline = VK_NULL_HANDLE;
    VkPipeline            blendPipeline  = VK_NULL_HANDLE;
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
        if (blendPipeline != VK_NULL_HANDLE) {
            vkDestroyPipeline(device, blendPipeline, nullptr);
            blendPipeline = VK_NULL_HANDLE;
            ++released;
        }
        if (opaquePipeline != VK_NULL_HANDLE) {
            vkDestroyPipeline(device, opaquePipeline, nullptr);
            opaquePipeline = VK_NULL_HANDLE;
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
            setFrom = VK_NULL_HANDLE;
            setTo   = VK_NULL_HANDLE;
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

// One recorded fullscreen-triangle draw scoped to a placement.
struct LayerDraw {
    VkPipeline                    pipeline = VK_NULL_HANDLE;
    VkDescriptorSet               set      = VK_NULL_HANDLE;
    VulkanTimelineLayerPlacement  placement;
    bool                          useBlendConstants = false;
    float                         blendConstant     = 0.0f;
};

bool CreateShaderModules(Temporaries& t, std::string* outError) {
    if (!t.vertex.create(t.device, shaders::kPassthroughVertSpv, shaders::kPassthroughVertSpvSize,
                         "timeline_transition_passthrough_vert")) {
        if (outError) *outError = kErrShaderModule;
        return false;
    }
    ++t.created;
    if (!t.fragment.create(t.device, shaders::kPassthroughFragSpv, shaders::kPassthroughFragSpvSize,
                           "timeline_transition_passthrough_frag")) {
        if (outError) *outError = kErrShaderModule;
        return false;
    }
    ++t.created;
    return true;
}

// Descriptor set layout (binding 0 combined image sampler, fragment stage),
// pool with two sets, two sets written with the caller's views/samplers, and
// the pipeline layout carrying the shared 112-byte push-constant range.
bool CreateDescriptorObjects(Temporaries& t,
                             const VulkanTimelineTransitionLayerImage& from,
                             const VulkanTimelineTransitionLayerImage& to,
                             std::string* outError) {
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
    if (vkCreateDescriptorSetLayout(t.device, &layoutCI, nullptr, &t.setLayout) != VK_SUCCESS) {
        t.setLayout = VK_NULL_HANDLE;
        if (outError) *outError = kErrDescriptor;
        return false;
    }
    ++t.created;

    VkDescriptorPoolSize poolSize{};
    poolSize.type            = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
    poolSize.descriptorCount = 2;

    VkDescriptorPoolCreateInfo poolCI{};
    poolCI.sType         = VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO;
    poolCI.maxSets       = 2;
    poolCI.poolSizeCount = 1;
    poolCI.pPoolSizes    = &poolSize;
    if (vkCreateDescriptorPool(t.device, &poolCI, nullptr, &t.descriptorPool) != VK_SUCCESS) {
        t.descriptorPool = VK_NULL_HANDLE;
        if (outError) *outError = kErrDescriptor;
        return false;
    }
    ++t.created;

    VkDescriptorSetLayout layouts[2] = {t.setLayout, t.setLayout};
    VkDescriptorSet sets[2] = {VK_NULL_HANDLE, VK_NULL_HANDLE};
    VkDescriptorSetAllocateInfo allocInfo{};
    allocInfo.sType              = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO;
    allocInfo.descriptorPool     = t.descriptorPool;
    allocInfo.descriptorSetCount = 2;
    allocInfo.pSetLayouts        = layouts;
    if (vkAllocateDescriptorSets(t.device, &allocInfo, sets) != VK_SUCCESS) {
        if (outError) *outError = kErrDescriptor;
        return false;
    }
    t.setFrom = sets[0];
    t.setTo   = sets[1];

    VkDescriptorImageInfo imageInfos[2]{};
    imageInfos[0].sampler     = from.sampler;
    imageInfos[0].imageView   = from.imageView;
    imageInfos[0].imageLayout = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
    imageInfos[1].sampler     = to.sampler;
    imageInfos[1].imageView   = to.imageView;
    imageInfos[1].imageLayout = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;

    VkWriteDescriptorSet writes[2]{};
    for (int i = 0; i < 2; ++i) {
        writes[i].sType           = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
        writes[i].dstSet          = sets[i];
        writes[i].dstBinding      = 0;
        writes[i].dstArrayElement = 0;
        writes[i].descriptorCount = 1;
        writes[i].descriptorType  = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
        writes[i].pImageInfo      = &imageInfos[i];
    }
    vkUpdateDescriptorSets(t.device, 2, writes, 0, nullptr);

    VkPushConstantRange pushRange{};
    pushRange.stageFlags = VK_SHADER_STAGE_VERTEX_BIT | VK_SHADER_STAGE_FRAGMENT_BIT;
    pushRange.offset     = 0;
    pushRange.size       = static_cast<uint32_t>(sizeof(VideoTransformFullPushConstants));

    VkPipelineLayoutCreateInfo plCI{};
    plCI.sType                  = VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO;
    plCI.setLayoutCount         = 1;
    plCI.pSetLayouts            = &t.setLayout;
    plCI.pushConstantRangeCount = 1;
    plCI.pPushConstantRanges    = &pushRange;
    if (vkCreatePipelineLayout(t.device, &plCI, nullptr, &t.pipelineLayout) != VK_SUCCESS) {
        t.pipelineLayout = VK_NULL_HANDLE;
        if (outError) *outError = kErrDescriptor;
        return false;
    }
    ++t.created;
    return true;
}

// Single-attachment render pass (clear -> store, UNDEFINED ->
// TRANSFER_SRC_OPTIMAL) plus the framebuffer over the caller's color view.
bool CreateRenderPassObjects(Temporaries& t,
                             const VulkanTimelineTransitionRenderTarget& target,
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
    deps[0].srcStageMask  = VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT;
    deps[0].dstStageMask  = VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT;
    deps[0].srcAccessMask = 0;
    deps[0].dstAccessMask = VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT;
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
        if (outError) *outError = kErrRenderPass;
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
        if (outError) *outError = kErrRenderPass;
        return false;
    }
    ++t.created;
    return true;
}

// Graphics pipeline mirroring the production passthrough pipeline (fullscreen
// triangle, no vertex input, dynamic viewport/scissor) with an optional
// constant-alpha blend variant (dynamic blend constants).
bool CreatePipeline(Temporaries& t, bool blend, VkPipeline* outPipeline, std::string* outError) {
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

    const VkDynamicState opaqueDynamic[] = {VK_DYNAMIC_STATE_VIEWPORT, VK_DYNAMIC_STATE_SCISSOR};
    const VkDynamicState blendDynamic[]  = {VK_DYNAMIC_STATE_VIEWPORT, VK_DYNAMIC_STATE_SCISSOR,
                                            VK_DYNAMIC_STATE_BLEND_CONSTANTS};
    VkPipelineDynamicStateCreateInfo dynamicState{};
    dynamicState.sType             = VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO;
    dynamicState.dynamicStateCount = blend ? 3u : 2u;
    dynamicState.pDynamicStates    = blend ? blendDynamic : opaqueDynamic;

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
    attachment.blendEnable         = blend ? VK_TRUE : VK_FALSE;
    attachment.srcColorBlendFactor = blend ? VK_BLEND_FACTOR_CONSTANT_ALPHA : VK_BLEND_FACTOR_ONE;
    attachment.dstColorBlendFactor = blend ? VK_BLEND_FACTOR_ONE_MINUS_CONSTANT_ALPHA : VK_BLEND_FACTOR_ZERO;
    attachment.colorBlendOp        = VK_BLEND_OP_ADD;
    attachment.srcAlphaBlendFactor = VK_BLEND_FACTOR_ONE;
    attachment.dstAlphaBlendFactor = VK_BLEND_FACTOR_ZERO;
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
    pipelineCI.layout              = t.pipelineLayout;
    pipelineCI.renderPass          = t.renderPass;
    pipelineCI.subpass             = 0;
    pipelineCI.basePipelineIndex   = -1;

    VkPipeline pipeline = VK_NULL_HANDLE;
    if (vkCreateGraphicsPipelines(t.device, VK_NULL_HANDLE, 1, &pipelineCI, nullptr, &pipeline) != VK_SUCCESS) {
        *outPipeline = VK_NULL_HANDLE;
        if (outError) *outError = kErrPipeline;
        return false;
    }
    *outPipeline = pipeline;
    ++t.created;
    return true;
}

// Push constants: crop UV range in the vertex UV transform rows, identity
// color matrix in the fragment half.
VideoTransformFullPushConstants MakeLayerPushConstants(const VulkanTimelineLayerPlacement& p) {
    VideoTransformFullPushConstants pc{};
    pc.uv.uvTransform0[0] = p.u1 - p.u0;
    pc.uv.uvTransform0[1] = 0.0f;
    pc.uv.uvTransform0[2] = 0.0f;
    pc.uv.uvTransform0[3] = p.u0;
    pc.uv.uvTransform1[0] = 0.0f;
    pc.uv.uvTransform1[1] = p.v1 - p.v0;
    pc.uv.uvTransform1[2] = 0.0f;
    pc.uv.uvTransform1[3] = p.v0;
    pc.color.row0[0] = 1.0f;
    pc.color.row1[1] = 1.0f;
    pc.color.row2[2] = 1.0f;
    pc.color.row3[3] = 1.0f;
    return pc;
}

void RecordLayerDraw(VkCommandBuffer cb, VkPipelineLayout layout, const LayerDraw& draw) {
    VkViewport viewport{};
    viewport.x        = static_cast<float>(draw.placement.xPx);
    viewport.y        = static_cast<float>(draw.placement.yTopPx);
    viewport.width    = static_cast<float>(draw.placement.widthPx);
    viewport.height   = static_cast<float>(draw.placement.heightPx);
    viewport.minDepth = 0.0f;
    viewport.maxDepth = 1.0f;
    vkCmdSetViewport(cb, 0, 1, &viewport);

    VkRect2D scissor{};
    scissor.offset = {draw.placement.xPx, draw.placement.yTopPx};
    scissor.extent = {draw.placement.widthPx, draw.placement.heightPx};
    vkCmdSetScissor(cb, 0, 1, &scissor);

    vkCmdBindPipeline(cb, VK_PIPELINE_BIND_POINT_GRAPHICS, draw.pipeline);
    vkCmdBindDescriptorSets(cb, VK_PIPELINE_BIND_POINT_GRAPHICS, layout, 0, 1, &draw.set, 0, nullptr);
    if (draw.useBlendConstants) {
        const float constants[4] = {draw.blendConstant, draw.blendConstant,
                                    draw.blendConstant, draw.blendConstant};
        vkCmdSetBlendConstants(cb, constants);
    }
    const VideoTransformFullPushConstants pc = MakeLayerPushConstants(draw.placement);
    vkCmdPushConstants(cb, layout, VK_SHADER_STAGE_VERTEX_BIT | VK_SHADER_STAGE_FRAGMENT_BIT,
                       0, static_cast<uint32_t>(sizeof(pc)), &pc);
    vkCmdDraw(cb, 3, 1, 0, 0);
}

// Allocates + records the whole command buffer: clear render pass with the
// layer draws, image-to-buffer copy, host-read barrier.
bool RecordCommands(Temporaries& t,
                    const VulkanTimelineTransitionRenderTarget& target,
                    const LayerDraw* draws,
                    uint32_t drawCount,
                    std::string* outError) {
    VkCommandBufferAllocateInfo cbAI{};
    cbAI.sType              = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO;
    cbAI.commandPool        = t.commandPool;
    cbAI.level              = VK_COMMAND_BUFFER_LEVEL_PRIMARY;
    cbAI.commandBufferCount = 1;
    if (vkAllocateCommandBuffers(t.device, &cbAI, &t.commandBuffer) != VK_SUCCESS) {
        t.commandBuffer = VK_NULL_HANDLE;
        if (outError) *outError = kErrCommandBuffer;
        return false;
    }
    ++t.created;

    VkCommandBufferBeginInfo beginInfo{};
    beginInfo.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
    beginInfo.flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
    if (vkBeginCommandBuffer(t.commandBuffer, &beginInfo) != VK_SUCCESS) {
        if (outError) *outError = kErrCommandBuffer;
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
    for (uint32_t i = 0; i < drawCount; ++i) {
        if (draws[i].placement.visible) {
            RecordLayerDraw(t.commandBuffer, t.pipelineLayout, draws[i]);
        }
    }
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
        if (outError) *outError = kErrCommandBuffer;
        return false;
    }
    return true;
}

// Submits once with a fresh fence and waits. On a wait timeout / failure the
// queue is drained with vkQueueWaitIdle so the caller's Release() never
// destroys objects still in flight.
bool SubmitAndWait(Temporaries& t, VkQueue queue, std::string* outError) {
    VkFenceCreateInfo fenceCI{};
    fenceCI.sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO;
    if (vkCreateFence(t.device, &fenceCI, nullptr, &t.fence) != VK_SUCCESS) {
        t.fence = VK_NULL_HANDLE;
        if (outError) *outError = kErrSubmit;
        return false;
    }
    ++t.created;

    VkSubmitInfo submit{};
    submit.sType              = VK_STRUCTURE_TYPE_SUBMIT_INFO;
    submit.commandBufferCount = 1;
    submit.pCommandBuffers    = &t.commandBuffer;
    if (vkQueueSubmit(queue, 1, &submit, t.fence) != VK_SUCCESS) {
        if (outError) *outError = kErrSubmit;
        return false;
    }

    const VkResult waitResult = vkWaitForFences(t.device, 1, &t.fence, VK_TRUE, kFenceTimeoutNs);
    if (waitResult != VK_SUCCESS) {
        VGLOG_TTC("vkWaitForFences returned %d; draining queue before release", static_cast<int>(waitResult));
        vkQueueWaitIdle(queue);
        if (outError) *outError = kErrWait;
        return false;
    }
    return true;
}

} // namespace
#endif // __ANDROID__

bool VulkanTimelineTransitionCompositor::renderTransition(
    const VulkanTimelineTransitionRenderTarget& target,
    const VulkanTimelineTransitionLayerImage& from,
    const VulkanTimelineTransitionLayerImage& to,
    const VulkanTimelineTransitionGeometry& geometry,
    std::string* outError) {
    if (outError) {
        outError->clear();
    }

#if defined(__ANDROID__)
    // ── Fail-closed validation: no Vulkan call is issued until every check passes.
    const uint64_t requiredReadbackBytes =
        static_cast<uint64_t>(target.extentWidth) * static_cast<uint64_t>(target.extentHeight) * 4ull;
    if (target.device == VK_NULL_HANDLE || target.queue == VK_NULL_HANDLE ||
        target.commandPool == VK_NULL_HANDLE ||
        target.colorImage == VK_NULL_HANDLE || target.colorImageView == VK_NULL_HANDLE ||
        target.readbackBuffer == VK_NULL_HANDLE ||
        target.extentWidth == 0 || target.extentHeight == 0 ||
        static_cast<uint64_t>(target.readbackBufferSizeBytes) < requiredReadbackBytes ||
        from.imageView == VK_NULL_HANDLE || from.sampler == VK_NULL_HANDLE ||
        to.imageView == VK_NULL_HANDLE || to.sampler == VK_NULL_HANDLE) {
        if (outError) *outError = kErrInvalidArgument;
        return false;
    }
    if (!std::isfinite(geometry.progress)) {
        if (outError) *outError = kErrInvalidProgress;
        return false;
    }
    if (!std::isfinite(geometry.blendWeightFrom) || !std::isfinite(geometry.blendWeightTo)) {
        if (outError) *outError = kErrInvalidWeight;
        return false;
    }
    if (!IsFiniteRect(geometry.fromViewport) || !IsFiniteRect(geometry.toViewport) ||
        !IsFiniteRect(geometry.fromCrop) || !IsFiniteRect(geometry.toCrop) ||
        !HasNonNegativeExtent(geometry.fromViewport) || !HasNonNegativeExtent(geometry.toViewport) ||
        !HasNonNegativeExtent(geometry.fromCrop) || !HasNonNegativeExtent(geometry.toCrop) ||
        !IsCropInsideUnit(geometry.fromCrop) || !IsCropInsideUnit(geometry.toCrop)) {
        if (outError) *outError = kErrInvalidGeometry;
        return false;
    }

    const double weightFrom = ClampUnit(geometry.blendWeightFrom);
    const double weightTo   = ClampUnit(geometry.blendWeightTo);

    enum class DrawMode { kFromOnly, kToOnly, kLayeredOpaque, kMix };
    DrawMode mode;
    if (weightTo <= 0.0) {
        mode = DrawMode::kFromOnly;
    } else if (weightFrom <= 0.0) {
        mode = DrawMode::kToOnly;
    } else if (weightFrom >= 1.0 && weightTo >= 1.0) {
        mode = DrawMode::kLayeredOpaque;
    } else {
        mode = DrawMode::kMix;
    }
    if (mode == DrawMode::kMix &&
        (!IsIdentityRect(geometry.fromViewport) || !IsIdentityRect(geometry.toViewport))) {
        if (outError) *outError = kErrUnsupportedGeometry;
        return false;
    }

    // ── Vulkan work. Every temporary object is released on every path below.
    Temporaries t;
    t.device      = target.device;
    t.commandPool = target.commandPool;

    bool ok = CreateShaderModules(t, outError) &&
              CreateDescriptorObjects(t, from, to, outError) &&
              CreateRenderPassObjects(t, target, outError) &&
              CreatePipeline(t, /*blend=*/false, &t.opaquePipeline, outError);
    if (ok && mode == DrawMode::kMix) {
        ok = CreatePipeline(t, /*blend=*/true, &t.blendPipeline, outError);
    }

    if (ok) {
        LayerDraw draws[2];
        uint32_t drawCount = 0;
        switch (mode) {
            case DrawMode::kFromOnly:
                draws[0].pipeline  = t.opaquePipeline;
                draws[0].set       = t.setFrom;
                draws[0].placement = ResolveVulkanTimelineLayerPlacement(
                    geometry.fromViewport, geometry.fromCrop, target.extentWidth, target.extentHeight);
                drawCount = 1;
                break;
            case DrawMode::kToOnly:
                draws[0].pipeline  = t.opaquePipeline;
                draws[0].set       = t.setTo;
                draws[0].placement = ResolveVulkanTimelineLayerPlacement(
                    geometry.toViewport, geometry.toCrop, target.extentWidth, target.extentHeight);
                drawCount = 1;
                break;
            case DrawMode::kLayeredOpaque:
                draws[0].pipeline  = t.opaquePipeline;
                draws[0].set       = t.setFrom;
                draws[0].placement = ResolveVulkanTimelineLayerPlacement(
                    geometry.fromViewport, geometry.fromCrop, target.extentWidth, target.extentHeight);
                draws[1].pipeline  = t.opaquePipeline;
                draws[1].set       = t.setTo;
                draws[1].placement = ResolveVulkanTimelineLayerPlacement(
                    geometry.toViewport, geometry.toCrop, target.extentWidth, target.extentHeight);
                drawCount = 2;
                break;
            case DrawMode::kMix:
                // Identity viewports by contract: both layers cover the full
                // canvas with their own crop as UV range; "to" is blended over
                // "from" with constant alpha == blendWeightTo.
                draws[0].pipeline  = t.opaquePipeline;
                draws[0].set       = t.setFrom;
                draws[0].placement = ResolveVulkanTimelineLayerPlacement(
                    geometry.fromViewport, geometry.fromCrop, target.extentWidth, target.extentHeight);
                draws[1].pipeline          = t.blendPipeline;
                draws[1].set               = t.setTo;
                draws[1].placement         = ResolveVulkanTimelineLayerPlacement(
                    geometry.toViewport, geometry.toCrop, target.extentWidth, target.extentHeight);
                draws[1].useBlendConstants = true;
                draws[1].blendConstant     = static_cast<float>(weightTo);
                drawCount = 2;
                break;
        }
        ok = RecordCommands(t, target, draws, drawCount, outError) &&
             SubmitAndWait(t, target.queue, outError);
    }

    t.Release();
    temporaryObjectsCreated_  += t.created;
    temporaryObjectsReleased_ += t.released;
    if (t.created != t.released) {
        VGLOG_TTC("temporary object count mismatch: created=%llu released=%llu",
                  static_cast<unsigned long long>(t.created),
                  static_cast<unsigned long long>(t.released));
    }
    return ok;
#else
    (void)target;
    (void)from;
    (void)to;
    (void)geometry;
    if (outError) {
        *outError = "vulkan_timeline_transition_compositor_unavailable_on_host";
    }
    return false;
#endif
}

} // namespace render
} // namespace vanguard
