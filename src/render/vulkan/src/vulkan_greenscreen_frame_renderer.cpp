// vulkan_greenscreen_frame_renderer.cpp
// ANDROID-DUET-VULKAN-GREENSCREEN-VISUAL: VulkanGreenScreenFrameRenderer
// implementation (alpha-masked camera layer over an already-drawn source
// layer; see the header for the draw model and caching contract).
//
// Android-only real implementation is inside #if defined(__ANDROID__).
// Non-Android translation unit compiles to a safe stub that performs no
// Vulkan calls and returns false with a clear failure token.

#include "vulkan_greenscreen_frame_renderer.h"

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

#include "shaders/greenscreen_blend_frag_spv.h"
#include "shaders/greenscreen_camera_mask_vert_spv.h"

#define VGLOG_GSFR(...) \
    __android_log_print(ANDROID_LOG_DEBUG, "VanguardVkGreenScreenFrameRnd", __VA_ARGS__)

namespace vanguard {
namespace render {

namespace {

constexpr const char* kErrInvalidArgument     = "vulkan_greenscreen_frame_renderer_invalid_argument";
constexpr const char* kErrInvalidImage         = "vulkan_greenscreen_frame_renderer_invalid_image";
constexpr const char* kErrInvalidMaskSize      = "vulkan_greenscreen_frame_renderer_invalid_mask_size";
constexpr const char* kErrInvalidPlacement     = "vulkan_greenscreen_frame_renderer_invalid_placement";
constexpr const char* kErrPipelineKeyMismatch  = "vulkan_greenscreen_frame_renderer_pipeline_key_mismatch";
constexpr const char* kErrShaderModuleFailed   = "vulkan_greenscreen_frame_renderer_shader_module_failed";
constexpr const char* kErrDescriptorFailed     = "vulkan_greenscreen_frame_renderer_descriptor_failed";
constexpr const char* kErrSamplerFailed        = "vulkan_greenscreen_frame_renderer_sampler_failed";
constexpr const char* kErrPipelineFailed       = "vulkan_greenscreen_frame_renderer_pipeline_failed";

void SetErr(std::string* outError, const char* reason) {
    if (outError) *outError = reason;
}

// Private 160-byte push-constant block pushed for the camera-mask draw: the
// original 128-byte block -- the shared 112-byte VideoTransformFullPushConstants
// (vertex UV transform + fragment colour matrix) plus a trailing fragment-only
// vec4 maskDebug (debugMode, 1/maskWidth, 1/maskHeight, useRotatedQuad) -- is
// byte-for-byte unchanged from the pre-rotation layout, with 32 trailing
// vertex-only bytes (rotatedQuad0/rotatedQuad1: the 4 rotated NDC corners,
// meaningful only when maskDebug[3] != 0) appended after it. Matches the GLSL
// `Transform` block in glsl/greenscreen_camera_mask.vert exactly (the
// fragment shader, glsl/greenscreen_blend.frag, only declares/reads the
// original 128-byte block and is otherwise untouched).
struct alignas(16) VulkanGreenScreenCameraMaskPushConstants {
    VideoTransformFullPushConstants transform;
    float maskDebug[4];
    float rotatedQuad0[4];
    float rotatedQuad1[4];
};

static_assert(sizeof(VulkanGreenScreenCameraMaskPushConstants) == 160,
              "VulkanGreenScreenCameraMaskPushConstants must be exactly 160 bytes");
static_assert(alignof(VulkanGreenScreenCameraMaskPushConstants) == 16,
              "VulkanGreenScreenCameraMaskPushConstants must be 16-byte aligned");

// ANDROID-DUET-VULKAN-GREENSCREEN-FREE-TRANSFORM: below this magnitude, a
// foreground rotation is treated as identity so the unrotated fast path
// (original fullscreen-triangle draw, byte-for-byte unchanged output) is
// used instead of the rotated-quad path. Mirrors the GLES compositor's
// ROTATION_EPSILON_DEGREES (AndroidDuetPreviewCompositor.kt).
constexpr float kForegroundRotationEpsilonDegrees = 1e-4f;

// Non-dispatchable Vulkan handles are exactly 8 bytes on every ABI Vulkan
// supports (a pointer on LP64/64-bit targets, a plain uint64_t otherwise),
// so a byte-for-byte memcpy round-trips through uint64_t on either ABI.
static_assert(sizeof(VkImageView) == sizeof(uint64_t),
              "VkImageView must be 8 bytes to round-trip through uint64_t");
static_assert(sizeof(VkRenderPass) == sizeof(uint64_t),
              "VkRenderPass must be 8 bytes to round-trip through uint64_t");
static_assert(sizeof(VkDescriptorSetLayout) == sizeof(uint64_t),
              "VkDescriptorSetLayout must be 8 bytes to round-trip through uint64_t");
static_assert(sizeof(VkDescriptorSet) == sizeof(uint64_t),
              "VkDescriptorSet must be 8 bytes to round-trip through uint64_t");

template <typename VkHandle>
VkHandle ToHandle(uint64_t value) {
    VkHandle handle = VK_NULL_HANDLE;
    std::memcpy(&handle, &value, sizeof(handle));
    return handle;
}

} // namespace

struct VulkanGreenScreenFrameRenderer::Impl {
    static constexpr uint32_t kPoolCapacity = 16;

    // Cached until shutdown().
    VkShaderModule vertexShaderModule   = VK_NULL_HANDLE;
    VkShaderModule fragmentShaderModule = VK_NULL_HANDLE;
    VkDescriptorSetLayout maskSetLayout = VK_NULL_HANDLE;
    VkSampler maskSampler               = VK_NULL_HANDLE;
    VkDescriptorPool pool               = VK_NULL_HANDLE;
    std::vector<VkDescriptorSet> descriptorSets;
    uint32_t nextSetIndex               = 0;

    // Cached against (cachedCameraSetLayout, cachedRenderPass) until
    // invalidate() / shutdown().
    VkPipelineLayout pipelineLayout          = VK_NULL_HANDLE;
    VkDescriptorSetLayout cachedCameraSetLayout = VK_NULL_HANDLE;
    VkPipeline pipeline                      = VK_NULL_HANDLE;
    VkRenderPass cachedRenderPass            = VK_NULL_HANDLE;

    bool ensureShaderModules(VkDevice device, std::string* outFailureReason) {
        if (vertexShaderModule == VK_NULL_HANDLE) {
            VkShaderModuleCreateInfo ci{};
            ci.sType    = VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO;
            ci.codeSize = shaders::kGreenScreenCameraMaskVertSpvSize;
            ci.pCode    = shaders::kGreenScreenCameraMaskVertSpv;
            if (vkCreateShaderModule(device, &ci, nullptr, &vertexShaderModule) != VK_SUCCESS) {
                vertexShaderModule = VK_NULL_HANDLE;
                SetErr(outFailureReason, kErrShaderModuleFailed);
                return false;
            }
        }
        if (fragmentShaderModule == VK_NULL_HANDLE) {
            VkShaderModuleCreateInfo ci{};
            ci.sType    = VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO;
            ci.codeSize = shaders::kGreenScreenCameraMaskFragSpvSize;
            ci.pCode    = shaders::kGreenScreenCameraMaskFragSpv;
            if (vkCreateShaderModule(device, &ci, nullptr, &fragmentShaderModule) != VK_SUCCESS) {
                fragmentShaderModule = VK_NULL_HANDLE;
                SetErr(outFailureReason, kErrShaderModuleFailed);
                return false;
            }
        }
        return true;
    }

    // Mask set layout (set 1, binding 0, mutable sampler), the LINEAR /
    // CLAMP_TO_EDGE mask sampler, and the descriptor pool + set ring.
    bool ensureMaskResources(VkDevice device, std::string* outFailureReason) {
        if (maskSetLayout == VK_NULL_HANDLE) {
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
            if (vkCreateDescriptorSetLayout(device, &layoutCI, nullptr, &maskSetLayout) != VK_SUCCESS) {
                maskSetLayout = VK_NULL_HANDLE;
                SetErr(outFailureReason, kErrDescriptorFailed);
                return false;
            }
        }

        if (maskSampler == VK_NULL_HANDLE) {
            VkSamplerCreateInfo samplerCI{};
            samplerCI.sType                   = VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO;
            samplerCI.magFilter               = VK_FILTER_LINEAR;
            samplerCI.minFilter               = VK_FILTER_LINEAR;
            samplerCI.mipmapMode              = VK_SAMPLER_MIPMAP_MODE_NEAREST;
            samplerCI.addressModeU            = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE;
            samplerCI.addressModeV            = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE;
            samplerCI.addressModeW            = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE;
            samplerCI.mipLodBias              = 0.0f;
            samplerCI.anisotropyEnable        = VK_FALSE;
            samplerCI.maxAnisotropy           = 1.0f;
            samplerCI.compareEnable           = VK_FALSE;
            samplerCI.compareOp               = VK_COMPARE_OP_ALWAYS;
            samplerCI.minLod                  = 0.0f;
            samplerCI.maxLod                  = 0.0f;
            samplerCI.borderColor             = VK_BORDER_COLOR_FLOAT_TRANSPARENT_BLACK;
            samplerCI.unnormalizedCoordinates = VK_FALSE;
            if (vkCreateSampler(device, &samplerCI, nullptr, &maskSampler) != VK_SUCCESS) {
                maskSampler = VK_NULL_HANDLE;
                SetErr(outFailureReason, kErrSamplerFailed);
                return false;
            }
        }

        if (pool == VK_NULL_HANDLE) {
            VkDescriptorPoolSize poolSize{};
            poolSize.type            = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
            poolSize.descriptorCount = kPoolCapacity;

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

            std::vector<VkDescriptorSetLayout> layouts(kPoolCapacity, maskSetLayout);
            descriptorSets.assign(kPoolCapacity, VK_NULL_HANDLE);
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
        }
        return true;
    }

    // Pipeline layout keyed by the camera import's descriptor set layout:
    // set 0 = camera (borrowed handle), set 1 = mask, one VERTEX|FRAGMENT
    // push-constant range identical to the shared import pipeline layouts.
    bool ensurePipelineLayout(VkDevice device,
                              VkDescriptorSetLayout cameraSetLayout,
                              std::string* outFailureReason) {
        if (pipelineLayout != VK_NULL_HANDLE) {
            if (cachedCameraSetLayout != cameraSetLayout) {
                SetErr(outFailureReason, kErrPipelineKeyMismatch);
                return false;
            }
            return true;
        }

        const VkDescriptorSetLayout setLayouts[2] = {cameraSetLayout, maskSetLayout};

        // Range size covers the full 160-byte block (including the trailing
        // vertex-only rotatedQuad0/1 bytes) even though the identity draw
        // only pushes/uses the first 128 -- vkCmdPushConstants always pushes
        // the whole struct below, and the vertex shader's push_constant
        // block declares all 160 bytes, so the pipeline layout's range must
        // cover them for both stages.
        VkPushConstantRange pushRange{};
        pushRange.stageFlags = VK_SHADER_STAGE_VERTEX_BIT | VK_SHADER_STAGE_FRAGMENT_BIT;
        pushRange.offset     = 0;
        pushRange.size       = static_cast<uint32_t>(sizeof(VulkanGreenScreenCameraMaskPushConstants));

        VkPipelineLayoutCreateInfo plCI{};
        plCI.sType                  = VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO;
        plCI.setLayoutCount         = 2;
        plCI.pSetLayouts            = setLayouts;
        plCI.pushConstantRangeCount = 1;
        plCI.pPushConstantRanges    = &pushRange;
        if (vkCreatePipelineLayout(device, &plCI, nullptr, &pipelineLayout) != VK_SUCCESS) {
            pipelineLayout = VK_NULL_HANDLE;
            SetErr(outFailureReason, kErrDescriptorFailed);
            return false;
        }
        cachedCameraSetLayout = cameraSetLayout;
        return true;
    }

    bool ensurePipeline(VkDevice device, VkRenderPass renderPass, std::string* outFailureReason) {
        if (pipeline != VK_NULL_HANDLE) {
            if (renderPass != cachedRenderPass) {
                SetErr(outFailureReason, kErrPipelineKeyMismatch);
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
        inputAssembly.primitiveRestartEnable = VK_FALSE;

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

        // Straight-alpha "over" blend: the fragment shader writes the camera
        // colour with alpha = camera.a * matte, composited over the already
        // drawn opaque source layer.
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
        pipelineCI.basePipelineHandle  = VK_NULL_HANDLE;
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

    void destroyPipelineObjects(VkDevice device) {
        if (pipeline != VK_NULL_HANDLE) {
            vkDestroyPipeline(device, pipeline, nullptr);
            pipeline = VK_NULL_HANDLE;
        }
        cachedRenderPass = VK_NULL_HANDLE;
        if (pipelineLayout != VK_NULL_HANDLE) {
            vkDestroyPipelineLayout(device, pipelineLayout, nullptr);
            pipelineLayout = VK_NULL_HANDLE;
        }
        cachedCameraSetLayout = VK_NULL_HANDLE;
    }

    void destroyAll(VkDevice device) {
        destroyPipelineObjects(device);
        if (pool != VK_NULL_HANDLE) {
            vkDestroyDescriptorPool(device, pool, nullptr);
            pool = VK_NULL_HANDLE;
            descriptorSets.clear();
            nextSetIndex = 0;
        }
        if (maskSampler != VK_NULL_HANDLE) {
            vkDestroySampler(device, maskSampler, nullptr);
            maskSampler = VK_NULL_HANDLE;
        }
        if (maskSetLayout != VK_NULL_HANDLE) {
            vkDestroyDescriptorSetLayout(device, maskSetLayout, nullptr);
            maskSetLayout = VK_NULL_HANDLE;
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

bool VulkanGreenScreenFrameRenderer::needsPipelineRebuild(uint64_t cameraDescriptorSetLayout,
                                                          uint64_t renderPass) const {
    if (!impl_) return false;
    const VkDescriptorSetLayout cameraSetLayout =
        ToHandle<VkDescriptorSetLayout>(cameraDescriptorSetLayout);
    const VkRenderPass pass = ToHandle<VkRenderPass>(renderPass);
    if (impl_->pipelineLayout != VK_NULL_HANDLE && impl_->cachedCameraSetLayout != cameraSetLayout) {
        return true;
    }
    if (impl_->pipeline != VK_NULL_HANDLE && impl_->cachedRenderPass != pass) {
        return true;
    }
    return false;
}

bool VulkanGreenScreenFrameRenderer::recordCameraDraw(
    void* devicePtr,
    void* commandBufferPtr,
    uint64_t renderPassHandle,
    uint32_t canvasWidth,
    uint32_t canvasHeight,
    const VulkanGreenScreenCameraDraw& draw,
    std::string* outFailureReason) {
    if (outFailureReason) outFailureReason->clear();

    if (devicePtr == nullptr || commandBufferPtr == nullptr ||
        renderPassHandle == 0 || canvasWidth == 0 || canvasHeight == 0) {
        SetErr(outFailureReason, kErrInvalidArgument);
        return false;
    }
    if (draw.cameraDescriptorSetLayout == 0 || draw.cameraDescriptorSet == 0 ||
        draw.maskImageView == 0) {
        SetErr(outFailureReason, kErrInvalidImage);
        return false;
    }
    if (draw.maskWidth == 0 || draw.maskHeight == 0) {
        SetErr(outFailureReason, kErrInvalidMaskSize);
        return false;
    }
    // Same placement rules VulkanGraphicsCommandRecorder enforces for a
    // transition layer draw: the viewport may extend beyond the canvas, the
    // scissor must be a non-empty sub-rect of it.
    if (draw.viewportWidth == 0 || draw.viewportHeight == 0 ||
        draw.scissorWidth == 0 || draw.scissorHeight == 0 ||
        draw.scissorX < 0 || draw.scissorY < 0) {
        SetErr(outFailureReason, kErrInvalidPlacement);
        return false;
    }
    const uint64_t scissorRight =
        static_cast<uint64_t>(draw.scissorX) + static_cast<uint64_t>(draw.scissorWidth);
    const uint64_t scissorBottom =
        static_cast<uint64_t>(draw.scissorY) + static_cast<uint64_t>(draw.scissorHeight);
    if (scissorRight > canvasWidth || scissorBottom > canvasHeight) {
        SetErr(outFailureReason, kErrInvalidPlacement);
        return false;
    }

    VkDevice device               = reinterpret_cast<VkDevice>(devicePtr);
    VkCommandBuffer commandBuffer = reinterpret_cast<VkCommandBuffer>(commandBufferPtr);
    VkRenderPass renderPass       = ToHandle<VkRenderPass>(renderPassHandle);
    const VkDescriptorSetLayout cameraSetLayout =
        ToHandle<VkDescriptorSetLayout>(draw.cameraDescriptorSetLayout);
    const VkDescriptorSet cameraSet = ToHandle<VkDescriptorSet>(draw.cameraDescriptorSet);

    // Vulkan work below. Every check above ran with zero Vulkan calls.
    if (!impl_->ensureShaderModules(device, outFailureReason)) return false;
    if (!impl_->ensureMaskResources(device, outFailureReason)) return false;
    if (!impl_->ensurePipelineLayout(device, cameraSetLayout, outFailureReason)) return false;
    if (!impl_->ensurePipeline(device, renderPass, outFailureReason)) return false;

    VkDescriptorSet maskSet = impl_->descriptorSets[impl_->nextSetIndex];
    impl_->nextSetIndex = (impl_->nextSetIndex + 1) % Impl::kPoolCapacity;

    VkDescriptorImageInfo maskInfo{};
    maskInfo.sampler     = impl_->maskSampler;
    maskInfo.imageView   = ToHandle<VkImageView>(draw.maskImageView);
    maskInfo.imageLayout = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;

    VkWriteDescriptorSet write{};
    write.sType           = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
    write.dstSet          = maskSet;
    write.dstBinding      = 0;
    write.dstArrayElement = 0;
    write.descriptorCount = 1;
    write.descriptorType  = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
    write.pImageInfo      = &maskInfo;
    vkUpdateDescriptorSets(device, 1, &write, 0, nullptr);

    vkCmdBindPipeline(commandBuffer, VK_PIPELINE_BIND_POINT_GRAPHICS, impl_->pipeline);

    // ANDROID-DUET-VULKAN-GREENSCREEN-FREE-TRANSFORM: identity/near-zero
    // foreground rotation (including non-finite, treated as identity rather
    // than failing closed) keeps the exact pre-rotation viewport / scissor /
    // draw below, byte-for-byte. A non-identity rotation switches to a
    // rotated 2-triangle quad: the viewport/scissor become the full canvas
    // (the rotated quad's own geometry bounds what is rasterized instead),
    // and the 4 camera-rect corners are rotated around the anchor pivot in
    // canvas-pixel space, then converted to NDC. Vulkan clip space is
    // already Y-down / top-left, matching the canvas convention used
    // throughout this codebase, so -- unlike the GLES compositor's parity
    // implementation -- no Y-flip is needed in this conversion.
    const bool foregroundRotationFinite = std::isfinite(draw.foregroundRotationDegrees);
    const bool useRotatedQuad = foregroundRotationFinite &&
        std::fabs(draw.foregroundRotationDegrees) >= kForegroundRotationEpsilonDegrees;

    float rotatedQuad0[4] = {0.0f, 0.0f, 0.0f, 0.0f};
    float rotatedQuad1[4] = {0.0f, 0.0f, 0.0f, 0.0f};

    if (useRotatedQuad) {
        const float rawAnchorX = draw.foregroundAnchorX;
        const float rawAnchorY = draw.foregroundAnchorY;
        const float anchorX = std::isfinite(rawAnchorX) ? rawAnchorX : 0.5f;
        const float anchorY = std::isfinite(rawAnchorY) ? rawAnchorY : 0.5f;
        const float clampedAnchorX = anchorX < 0.0f ? 0.0f : (anchorX > 1.0f ? 1.0f : anchorX);
        const float clampedAnchorY = anchorY < 0.0f ? 0.0f : (anchorY > 1.0f ? 1.0f : anchorY);

        const float rectLeft = static_cast<float>(draw.viewportX);
        const float rectTop = static_cast<float>(draw.viewportY);
        const float rectWidth = static_cast<float>(draw.viewportWidth);
        const float rectHeight = static_cast<float>(draw.viewportHeight);
        const float rectRight = rectLeft + rectWidth;
        const float rectBottom = rectTop + rectHeight;

        const float pivotX = rectLeft + clampedAnchorX * rectWidth;
        const float pivotY = rectTop + clampedAnchorY * rectHeight;

        constexpr double kPi = 3.14159265358979323846;
        const double radians = static_cast<double>(draw.foregroundRotationDegrees) * (kPi / 180.0);
        const float cosT = static_cast<float>(std::cos(radians));
        const float sinT = static_cast<float>(std::sin(radians));

        // Corner order matches the shader's kQuadUvBase and the identity
        // path's fullscreen-triangle-implied logical quad corners exactly:
        // 0 = top-left (NDC(-1,-1)), 1 = top-right (NDC(1,-1)), 2 =
        // bottom-left (NDC(-1,1)), 3 = bottom-right (NDC(1,1)).
        const float cornersX[4] = {rectLeft, rectRight, rectLeft, rectRight};
        const float cornersY[4] = {rectTop, rectTop, rectBottom, rectBottom};

        float ndcX[4];
        float ndcY[4];
        for (int i = 0; i < 4; ++i) {
            const float dx = cornersX[i] - pivotX;
            const float dy = cornersY[i] - pivotY;
            const float rx = pivotX + dx * cosT - dy * sinT;
            const float ry = pivotY + dx * sinT + dy * cosT;
            ndcX[i] = (rx / static_cast<float>(canvasWidth)) * 2.0f - 1.0f;
            ndcY[i] = (ry / static_cast<float>(canvasHeight)) * 2.0f - 1.0f;
        }
        rotatedQuad0[0] = ndcX[0];
        rotatedQuad0[1] = ndcY[0];
        rotatedQuad0[2] = ndcX[1];
        rotatedQuad0[3] = ndcY[1];
        rotatedQuad1[0] = ndcX[2];
        rotatedQuad1[1] = ndcY[2];
        rotatedQuad1[2] = ndcX[3];
        rotatedQuad1[3] = ndcY[3];
    }

    VkViewport viewport{};
    if (useRotatedQuad) {
        viewport.x      = 0.0f;
        viewport.y      = 0.0f;
        viewport.width  = static_cast<float>(canvasWidth);
        viewport.height = static_cast<float>(canvasHeight);
    } else {
        viewport.x      = static_cast<float>(draw.viewportX);
        viewport.y      = static_cast<float>(draw.viewportY);
        viewport.width  = static_cast<float>(draw.viewportWidth);
        viewport.height = static_cast<float>(draw.viewportHeight);
    }
    viewport.minDepth = 0.0f;
    viewport.maxDepth = 1.0f;
    vkCmdSetViewport(commandBuffer, 0, 1, &viewport);

    VkRect2D scissor{};
    if (useRotatedQuad) {
        scissor.offset = {0, 0};
        scissor.extent = {canvasWidth, canvasHeight};
    } else {
        scissor.offset = {draw.scissorX, draw.scissorY};
        scissor.extent = {draw.scissorWidth, draw.scissorHeight};
    }
    vkCmdSetScissor(commandBuffer, 0, 1, &scissor);

    const VkDescriptorSet sets[2] = {cameraSet, maskSet};
    vkCmdBindDescriptorSets(commandBuffer, VK_PIPELINE_BIND_POINT_GRAPHICS, impl_->pipelineLayout,
                            0, 2, sets, 0, nullptr);

    VulkanGreenScreenCameraMaskPushConstants pushConstants{};
    pushConstants.transform    = draw.pushConstants;
    pushConstants.maskDebug[0] = static_cast<float>(draw.debugMode);
    pushConstants.maskDebug[1] = 1.0f / static_cast<float>(draw.maskWidth);
    pushConstants.maskDebug[2] = 1.0f / static_cast<float>(draw.maskHeight);
    pushConstants.maskDebug[3] = useRotatedQuad ? 1.0f : 0.0f;
    std::memcpy(pushConstants.rotatedQuad0, rotatedQuad0, sizeof(rotatedQuad0));
    std::memcpy(pushConstants.rotatedQuad1, rotatedQuad1, sizeof(rotatedQuad1));

    vkCmdPushConstants(commandBuffer, impl_->pipelineLayout,
                       VK_SHADER_STAGE_VERTEX_BIT | VK_SHADER_STAGE_FRAGMENT_BIT,
                       0, static_cast<uint32_t>(sizeof(pushConstants)), &pushConstants);

    vkCmdDraw(commandBuffer, useRotatedQuad ? 6 : 3, 1, 0, 0);

    return true;
}

void VulkanGreenScreenFrameRenderer::invalidate(void* devicePtr) {
    VkDevice device = reinterpret_cast<VkDevice>(devicePtr);
    if (device == VK_NULL_HANDLE || !impl_) return;
    impl_->destroyPipelineObjects(device);
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

bool VulkanGreenScreenFrameRenderer::needsPipelineRebuild(uint64_t /*cameraDescriptorSetLayout*/,
                                                          uint64_t /*renderPass*/) const {
    return false;
}

bool VulkanGreenScreenFrameRenderer::recordCameraDraw(
    void* /*device*/,
    void* /*commandBuffer*/,
    uint64_t /*renderPass*/,
    uint32_t /*canvasWidth*/,
    uint32_t /*canvasHeight*/,
    const VulkanGreenScreenCameraDraw& /*draw*/,
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
