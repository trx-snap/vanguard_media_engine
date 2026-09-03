// vulkan_overlay_compositor.cpp
// P5-OVERLAYS-TRANS (sub-slice VULKAN-RENDER): VulkanOverlayCompositor
// implementation.
//
// Android-only real implementation is inside #if defined(__ANDROID__).
// Non-Android translation unit compiles to a safe stub that performs no
// Vulkan calls and reports unavailable, matching the other private Vulkan
// helper host stubs. The pure validation and inverse-placement math
// (ValidateVulkanOverlayLayerDescriptor / ComputeVulkanOverlayPlacement)
// compiles on every platform.
//
// Every renderOverlays() call: validates the target and every layer (no
// Vulkan call until all pass, and every layer placement is resolved up
// front), then creates temporary shader modules (from the existing AOT
// passthrough SPIR-V), a descriptor set layout, one descriptor pool holding
// one set per layer, a pipeline layout, a render pass (clear or load),
// a framebuffer, one straight-alpha source-over blend pipeline, one command
// buffer from the caller's pool and one fence; records the render pass with
// one full-viewport / bounding-box-scissored fullscreen-triangle draw per
// layer plus the image-to-buffer copy; submits once; waits on the fence; and
// releases every temporary object before returning on every path. No new
// GLSL/SPIR-V exists for this helper: the inverse placement rides in the
// push-constant UV rows and per-layer opacity rides in colour-matrix row 3.

#include "vulkan_overlay_compositor.h"

#include <algorithm>
#include <cmath>
#include <cstring>
#include <vector>

#if defined(__ANDROID__)
#include <android/log.h>

#include "shaders/passthrough_frag_spv.h"
#include "shaders/passthrough_vert_spv.h"
#include "vanguard/render/render_transform.h"
#include "vulkan_shader_module.h"

#define VGLOG_OVC(...) \
    __android_log_print(ANDROID_LOG_DEBUG, "VanguardVkOverlay", __VA_ARGS__)
#endif

namespace {

constexpr const char* kErrInvalidArgument  = "vulkan_overlay_compositor_invalid_argument";
constexpr const char* kErrInvalidImage     = "vulkan_overlay_compositor_invalid_image";
constexpr const char* kErrInvalidTransform = "vulkan_overlay_compositor_invalid_transform";
constexpr const char* kErrInvalidOpacity   = "vulkan_overlay_compositor_invalid_opacity";
[[maybe_unused]] constexpr const char* kErrShaderModule  = "vulkan_overlay_compositor_shader_module_failed";
[[maybe_unused]] constexpr const char* kErrDescriptor    = "vulkan_overlay_compositor_descriptor_failed";
[[maybe_unused]] constexpr const char* kErrRenderPass    = "vulkan_overlay_compositor_render_pass_failed";
[[maybe_unused]] constexpr const char* kErrPipeline      = "vulkan_overlay_compositor_pipeline_failed";
[[maybe_unused]] constexpr const char* kErrCommandBuffer = "vulkan_overlay_compositor_command_buffer_failed";
[[maybe_unused]] constexpr const char* kErrSubmit        = "vulkan_overlay_compositor_submit_failed";
[[maybe_unused]] constexpr const char* kErrWait          = "vulkan_overlay_compositor_wait_failed";

void SetError(std::string* outError, const char* reason) {
    if (outError) *outError = reason;
}

// VkImageView / VkSampler are pointer handles on 64-bit and uint64_t on
// 32-bit Android ABIs; compare against the platform null handle in either
// case (the host stub uses plain pointers).
bool LayerHandlesNull(const vanguard::render::VulkanOverlayLayerDescriptor& layer) {
#if defined(__ANDROID__)
    return layer.imageView == VK_NULL_HANDLE || layer.sampler == VK_NULL_HANDLE;
#else
    return layer.imageView == nullptr || layer.sampler == nullptr;
#endif
}

bool LayerFieldsFinite(const vanguard::render::VulkanOverlayLayerDescriptor& layer) {
    return std::isfinite(layer.x) && std::isfinite(layer.y) &&
           std::isfinite(layer.width) && std::isfinite(layer.height) &&
           std::isfinite(layer.rotation) && std::isfinite(layer.scale);
}

bool LayerExtentsPositive(const vanguard::render::VulkanOverlayLayerDescriptor& layer) {
    return layer.width > 0.0 && layer.height > 0.0 && layer.scale > 0.0;
}

void ResetPlacement(vanguard::render::VulkanOverlayLayerPlacement* p) {
    p->uvRow0[0] = 1.0f; p->uvRow0[1] = 0.0f; p->uvRow0[2] = 0.0f; p->uvRow0[3] = 0.0f;
    p->uvRow1[0] = 0.0f; p->uvRow1[1] = 1.0f; p->uvRow1[2] = 0.0f; p->uvRow1[3] = 0.0f;
    p->visible       = false;
    p->scissorX      = 0;
    p->scissorY      = 0;
    p->scissorWidth  = 0;
    p->scissorHeight = 0;
}
} // namespace

namespace vanguard {
namespace render {

VulkanOverlayCompositor::VulkanOverlayCompositor() = default;
VulkanOverlayCompositor::~VulkanOverlayCompositor() = default;

// ── Pure validation + inverse placement math (all platforms) ────────────────

bool ComputeVulkanOverlayPlacement(const VulkanOverlayLayerDescriptor& layer,
                                   uint32_t extentWidth,
                                   uint32_t extentHeight,
                                   VulkanOverlayLayerPlacement* outPlacement) {
    if (outPlacement == nullptr) return false;
    ResetPlacement(outPlacement);
    if (extentWidth == 0 || extentHeight == 0 ||
        !LayerFieldsFinite(layer) || !LayerExtentsPositive(layer)) {
        return false;
    }

    // Canvas (top-left origin, Y down) geometry of the placed layer.
    const double canvasW = static_cast<double>(extentWidth);
    const double canvasH = static_cast<double>(extentHeight);
    const double cx = layer.x + layer.width * 0.5;
    const double cy = layer.y + layer.height * 0.5;
    const double ws = layer.width * layer.scale;   // scaled width
    const double hs = layer.height * layer.scale;  // scaled height
    const double c  = std::cos(layer.rotation);
    const double s  = std::sin(layer.rotation);

    // Forward placement of overlay-local (u, v) in [0,1]^2:
    //   pixel = centre + R(rotation) * ((u - 0.5) * ws, (v - 0.5) * hs),
    //   R = [c -s; s c] (clockwise on a Y-down canvas).
    // Inverse for a canvas pixel p = (bx * W, by * H):
    //   d = p - centre, local = R^T * d = (c*dx + s*dy, -s*dx + c*dy),
    //   u = local.x / ws + 0.5, v = local.y / hs + 0.5.
    const double u0 = c * canvasW / ws;
    const double u1 = s * canvasH / ws;
    const double u3 = 0.5 - (c * cx + s * cy) / ws;
    const double v0 = -s * canvasW / hs;
    const double v1 = c * canvasH / hs;
    const double v3 = 0.5 + (s * cx - c * cy) / hs;

    // Conservative scissor: rotated bounding box of the scaled quad, clipped
    // to the canvas.
    const double halfW = ws * 0.5;
    const double halfH = hs * 0.5;
    const double extX  = std::fabs(c) * halfW + std::fabs(s) * halfH;
    const double extY  = std::fabs(s) * halfW + std::fabs(c) * halfH;
    const double minX  = cx - extX;
    const double maxX  = cx + extX;
    const double minY  = cy - extY;
    const double maxY  = cy + extY;

    if (!std::isfinite(u0) || !std::isfinite(u1) || !std::isfinite(u3) ||
        !std::isfinite(v0) || !std::isfinite(v1) || !std::isfinite(v3) ||
        !std::isfinite(minX) || !std::isfinite(maxX) ||
        !std::isfinite(minY) || !std::isfinite(maxY)) {
        return false;
    }

    outPlacement->uvRow0[0] = static_cast<float>(u0);
    outPlacement->uvRow0[1] = static_cast<float>(u1);
    outPlacement->uvRow0[2] = 0.0f;
    outPlacement->uvRow0[3] = static_cast<float>(u3);
    outPlacement->uvRow1[0] = static_cast<float>(v0);
    outPlacement->uvRow1[1] = static_cast<float>(v1);
    outPlacement->uvRow1[2] = 0.0f;
    outPlacement->uvRow1[3] = static_cast<float>(v3);

    // Clip in double first (inputs may be astronomically off-canvas), then
    // widen to whole pixels.
    const double cx0 = std::max(0.0, std::min(canvasW, minX));
    const double cx1 = std::max(0.0, std::min(canvasW, maxX));
    const double cy0 = std::max(0.0, std::min(canvasH, minY));
    const double cy1 = std::max(0.0, std::min(canvasH, maxY));
    const double px0 = std::floor(cx0);
    const double px1 = std::ceil(cx1);
    const double py0 = std::floor(cy0);
    const double py1 = std::ceil(cy1);
    if (!(px1 > px0) || !(py1 > py0)) {
        return true; // fully off-canvas or rounds to zero pixels: valid, invisible
    }
    outPlacement->visible       = true;
    outPlacement->scissorX      = static_cast<int32_t>(px0);
    outPlacement->scissorY      = static_cast<int32_t>(py0);
    outPlacement->scissorWidth  = static_cast<uint32_t>(px1 - px0);
    outPlacement->scissorHeight = static_cast<uint32_t>(py1 - py0);
    return true;
}

bool ValidateVulkanOverlayLayerDescriptor(const VulkanOverlayLayerDescriptor& layer,
                                          uint32_t extentWidth,
                                          uint32_t extentHeight,
                                          std::string* outError) {
    if (extentWidth == 0 || extentHeight == 0) {
        SetError(outError, kErrInvalidArgument);
        return false;
    }
    if (LayerHandlesNull(layer)) {
        SetError(outError, kErrInvalidImage);
        return false;
    }
    if (!LayerFieldsFinite(layer) || !LayerExtentsPositive(layer)) {
        SetError(outError, kErrInvalidTransform);
        return false;
    }
    VulkanOverlayLayerPlacement placement;
    if (!ComputeVulkanOverlayPlacement(layer, extentWidth, extentHeight, &placement)) {
        SetError(outError, kErrInvalidTransform); // derived coefficients overflowed
        return false;
    }
    if (!std::isfinite(layer.opacity) || layer.opacity < 0.0 || layer.opacity > 1.0) {
        SetError(outError, kErrInvalidOpacity);
        return false;
    }
    if (outError) outError->clear();
    return true;
}

#if defined(__ANDROID__)
namespace {

constexpr uint64_t kFenceTimeoutNs = 5000000000ull; // 5 s

// Every temporary Vulkan object one renderOverlays() call creates. Release()
// destroys / frees each non-null handle in reverse dependency order and
// counts releases so the owner can prove created == released. Descriptor
// sets are freed implicitly with their pool (the pool is the counted object).
struct Temporaries {
    VkDevice                     device         = VK_NULL_HANDLE;
    VkCommandPool                commandPool    = VK_NULL_HANDLE;
    VulkanShaderModule           vertex;
    VulkanShaderModule           fragment;
    VkDescriptorSetLayout        setLayout      = VK_NULL_HANDLE;
    VkDescriptorPool             descriptorPool = VK_NULL_HANDLE;
    std::vector<VkDescriptorSet> sets;          // freed with the pool
    VkPipelineLayout             pipelineLayout = VK_NULL_HANDLE;
    VkRenderPass                 renderPass     = VK_NULL_HANDLE;
    VkFramebuffer                framebuffer    = VK_NULL_HANDLE;
    VkPipeline                   pipeline       = VK_NULL_HANDLE;
    VkCommandBuffer              commandBuffer  = VK_NULL_HANDLE;
    VkFence                      fence          = VK_NULL_HANDLE;
    uint64_t                     created        = 0;
    uint64_t                     released       = 0;

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
            sets.clear();
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
                         "overlay_passthrough_vert")) {
        SetError(outError, kErrShaderModule);
        return false;
    }
    ++t.created;
    if (!t.fragment.create(t.device, shaders::kPassthroughFragSpv, shaders::kPassthroughFragSpvSize,
                           "overlay_passthrough_frag")) {
        SetError(outError, kErrShaderModule);
        return false;
    }
    ++t.created;
    return true;
}

// Descriptor set layout (binding 0 combined image sampler, fragment stage),
// one pool with one set per layer written with the caller's view/sampler
// pairs, and the pipeline layout carrying the shared 112-byte push-constant
// range.
bool CreateDescriptorObjects(Temporaries& t,
                             const VulkanOverlayLayerDescriptor* layers,
                             uint32_t layerCount,
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
        SetError(outError, kErrDescriptor);
        return false;
    }
    ++t.created;

    VkDescriptorPoolSize poolSize{};
    poolSize.type            = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
    poolSize.descriptorCount = layerCount;

    VkDescriptorPoolCreateInfo poolCI{};
    poolCI.sType         = VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO;
    poolCI.maxSets       = layerCount;
    poolCI.poolSizeCount = 1;
    poolCI.pPoolSizes    = &poolSize;
    if (vkCreateDescriptorPool(t.device, &poolCI, nullptr, &t.descriptorPool) != VK_SUCCESS) {
        t.descriptorPool = VK_NULL_HANDLE;
        SetError(outError, kErrDescriptor);
        return false;
    }
    ++t.created;

    std::vector<VkDescriptorSetLayout> layouts(layerCount, t.setLayout);
    t.sets.assign(layerCount, VK_NULL_HANDLE);
    VkDescriptorSetAllocateInfo allocInfo{};
    allocInfo.sType              = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO;
    allocInfo.descriptorPool     = t.descriptorPool;
    allocInfo.descriptorSetCount = layerCount;
    allocInfo.pSetLayouts        = layouts.data();
    if (vkAllocateDescriptorSets(t.device, &allocInfo, t.sets.data()) != VK_SUCCESS) {
        t.sets.clear();
        SetError(outError, kErrDescriptor);
        return false;
    }

    std::vector<VkDescriptorImageInfo> imageInfos(layerCount);
    std::vector<VkWriteDescriptorSet>  writes(layerCount);
    for (uint32_t i = 0; i < layerCount; ++i) {
        imageInfos[i] = VkDescriptorImageInfo{};
        imageInfos[i].sampler     = layers[i].sampler;
        imageInfos[i].imageView   = layers[i].imageView;
        imageInfos[i].imageLayout = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
        writes[i] = VkWriteDescriptorSet{};
        writes[i].sType           = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
        writes[i].dstSet          = t.sets[i];
        writes[i].dstBinding      = 0;
        writes[i].dstArrayElement = 0;
        writes[i].descriptorCount = 1;
        writes[i].descriptorType  = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
        writes[i].pImageInfo      = &imageInfos[i];
    }
    vkUpdateDescriptorSets(t.device, layerCount, writes.data(), 0, nullptr);

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
        SetError(outError, kErrDescriptor);
        return false;
    }
    ++t.created;
    return true;
}

// Single-attachment render pass (clear or load -> store, initial layout per
// target -> TRANSFER_SRC_OPTIMAL) plus the framebuffer over the caller's
// color view.
bool CreateRenderPassObjects(Temporaries& t,
                             const VulkanOverlayRenderTarget& target,
                             std::string* outError) {
    const bool load = target.loadExistingContents;

    VkAttachmentDescription color{};
    color.format         = target.colorFormat;
    color.samples        = VK_SAMPLE_COUNT_1_BIT;
    color.loadOp         = load ? VK_ATTACHMENT_LOAD_OP_LOAD : VK_ATTACHMENT_LOAD_OP_CLEAR;
    color.storeOp        = VK_ATTACHMENT_STORE_OP_STORE;
    color.stencilLoadOp  = VK_ATTACHMENT_LOAD_OP_DONT_CARE;
    color.stencilStoreOp = VK_ATTACHMENT_STORE_OP_DONT_CARE;
    color.initialLayout  = load ? target.colorInitialLayout : VK_IMAGE_LAYOUT_UNDEFINED;
    color.finalLayout    = VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL;

    VkAttachmentReference colorRef{};
    colorRef.attachment = 0;
    colorRef.layout     = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL;

    VkSubpassDescription subpass{};
    subpass.pipelineBindPoint    = VK_PIPELINE_BIND_POINT_GRAPHICS;
    subpass.colorAttachmentCount = 1;
    subpass.pColorAttachments    = &colorRef;

    // External -> subpass: when loading, prior colour writes and transfer
    // reads/writes of the attachment (a previous render + readback copy or a
    // caller clear) must be complete and visible before the load; when
    // clearing only the write-after-write ordering matters.
    VkSubpassDependency deps[2]{};
    deps[0].srcSubpass    = VK_SUBPASS_EXTERNAL;
    deps[0].dstSubpass    = 0;
    deps[0].srcStageMask  = VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT |
                            (load ? VK_PIPELINE_STAGE_TRANSFER_BIT : 0u);
    deps[0].dstStageMask  = VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT;
    deps[0].srcAccessMask = load ? (VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT |
                                    VK_ACCESS_TRANSFER_READ_BIT | VK_ACCESS_TRANSFER_WRITE_BIT)
                                 : 0u;
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

// Graphics pipeline mirroring the production passthrough pipeline (fullscreen
// triangle, no vertex input, dynamic viewport/scissor) with fixed-function
// straight-alpha Porter-Duff source-over blending.
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

// Push constants: inverse placement in the vertex UV rows; identity colour
// rows 0..2 and (0, 0, 0, opacity) in row 3 so only the sampled alpha is
// scaled and RGB stays straight.
VideoTransformFullPushConstants MakeLayerPushConstants(const VulkanOverlayLayerPlacement& p,
                                                       double opacity) {
    VideoTransformFullPushConstants pc{};
    std::memcpy(pc.uv.uvTransform0, p.uvRow0, sizeof(pc.uv.uvTransform0));
    std::memcpy(pc.uv.uvTransform1, p.uvRow1, sizeof(pc.uv.uvTransform1));
    pc.color.row0[0] = 1.0f;
    pc.color.row1[1] = 1.0f;
    pc.color.row2[2] = 1.0f;
    pc.color.row3[3] = static_cast<float>(opacity);
    return pc;
}

// Allocates + records the whole command buffer: render pass (clear or load)
// with one scissored fullscreen-triangle draw per visible layer, then the
// image-to-buffer copy and host-read barrier.
bool RecordCommands(Temporaries& t,
                    const VulkanOverlayRenderTarget& target,
                    const VulkanOverlayLayerDescriptor* layers,
                    const std::vector<VulkanOverlayLayerPlacement>& placements,
                    uint32_t layerCount,
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
    rpBegin.clearValueCount   = 1; // ignored by the driver when loadOp is LOAD
    rpBegin.pClearValues      = &clearValue;
    vkCmdBeginRenderPass(t.commandBuffer, &rpBegin, VK_SUBPASS_CONTENTS_INLINE);

    // Full-canvas viewport so the vertex shader's base (x, y) spans the whole
    // canvas; per-layer scissor limits the fill to the rotated bounding box.
    VkViewport viewport{};
    viewport.x        = 0.0f;
    viewport.y        = 0.0f;
    viewport.width    = static_cast<float>(target.extentWidth);
    viewport.height   = static_cast<float>(target.extentHeight);
    viewport.minDepth = 0.0f;
    viewport.maxDepth = 1.0f;
    vkCmdSetViewport(t.commandBuffer, 0, 1, &viewport);
    vkCmdBindPipeline(t.commandBuffer, VK_PIPELINE_BIND_POINT_GRAPHICS, t.pipeline);

    for (uint32_t i = 0; i < layerCount; ++i) {
        const VulkanOverlayLayerPlacement& p = placements[i];
        if (!p.visible) continue;
        VkRect2D scissor{};
        scissor.offset = {p.scissorX, p.scissorY};
        scissor.extent = {p.scissorWidth, p.scissorHeight};
        vkCmdSetScissor(t.commandBuffer, 0, 1, &scissor);
        vkCmdBindDescriptorSets(t.commandBuffer, VK_PIPELINE_BIND_POINT_GRAPHICS, t.pipelineLayout,
                                0, 1, &t.sets[i], 0, nullptr);
        const VideoTransformFullPushConstants pc = MakeLayerPushConstants(p, layers[i].opacity);
        vkCmdPushConstants(t.commandBuffer, t.pipelineLayout,
                           VK_SHADER_STAGE_VERTEX_BIT | VK_SHADER_STAGE_FRAGMENT_BIT,
                           0, static_cast<uint32_t>(sizeof(pc)), &pc);
        vkCmdDraw(t.commandBuffer, 3, 1, 0, 0);
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
        SetError(outError, kErrCommandBuffer);
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
        VGLOG_OVC("vkWaitForFences returned %d; draining queue before release", static_cast<int>(waitResult));
        vkQueueWaitIdle(queue);
        SetError(outError, kErrWait);
        return false;
    }
    return true;
}

} // namespace
#endif // __ANDROID__

bool VulkanOverlayCompositor::renderOverlays(const VulkanOverlayRenderTarget& target,
                                             const VulkanOverlayLayerDescriptor* layers,
                                             size_t layerCount,
                                             std::string* outError) {
    if (outError) {
        outError->clear();
    }

#if defined(__ANDROID__)
    // ── Fail-closed validation: no Vulkan call is issued until every check
    // passes and every layer placement has been resolved.
    const uint64_t requiredReadbackBytes =
        static_cast<uint64_t>(target.extentWidth) * static_cast<uint64_t>(target.extentHeight) * 4ull;
    if (target.device == VK_NULL_HANDLE || target.queue == VK_NULL_HANDLE ||
        target.commandPool == VK_NULL_HANDLE ||
        target.colorImage == VK_NULL_HANDLE || target.colorImageView == VK_NULL_HANDLE ||
        target.readbackBuffer == VK_NULL_HANDLE ||
        target.colorFormat == VK_FORMAT_UNDEFINED ||
        target.extentWidth == 0 || target.extentHeight == 0 ||
        static_cast<uint64_t>(target.readbackBufferSizeBytes) < requiredReadbackBytes ||
        (layers == nullptr && layerCount != 0) ||
        layerCount > static_cast<size_t>(UINT32_MAX) ||
        (target.loadExistingContents &&
         (target.colorInitialLayout == VK_IMAGE_LAYOUT_UNDEFINED ||
          target.colorInitialLayout == VK_IMAGE_LAYOUT_PREINITIALIZED))) {
        SetError(outError, kErrInvalidArgument);
        return false;
    }
    std::vector<VulkanOverlayLayerPlacement> placements(layerCount);
    for (size_t i = 0; i < layerCount; ++i) {
        if (!ValidateVulkanOverlayLayerDescriptor(layers[i], target.extentWidth, target.extentHeight,
                                                  outError)) {
            return false;
        }
        ComputeVulkanOverlayPlacement(layers[i], target.extentWidth, target.extentHeight, &placements[i]);
    }
    if (layerCount == 0) {
        return true; // nothing to draw; no Vulkan call, target untouched
    }
    const uint32_t count = static_cast<uint32_t>(layerCount);

    // ── Vulkan work. Every temporary object is released on every path below.
    Temporaries t;
    t.device      = target.device;
    t.commandPool = target.commandPool;

    const bool ok = CreateShaderModules(t, outError) &&
                    CreateDescriptorObjects(t, layers, count, outError) &&
                    CreateRenderPassObjects(t, target, outError) &&
                    CreateBlendPipeline(t, outError) &&
                    RecordCommands(t, target, layers, placements, count, outError) &&
                    SubmitAndWait(t, target.queue, outError);

    t.Release();
    temporaryObjectsCreated_  += t.created;
    temporaryObjectsReleased_ += t.released;
    if (t.created != t.released) {
        VGLOG_OVC("temporary object count mismatch: created=%llu released=%llu",
                  static_cast<unsigned long long>(t.created),
                  static_cast<unsigned long long>(t.released));
    }
    return ok;
#else
    (void)target;
    (void)layers;
    (void)layerCount;
    SetError(outError, "vulkan_overlay_compositor_unavailable_on_host");
    return false;
#endif
}

} // namespace render
} // namespace vanguard
