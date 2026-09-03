// vulkan_beauty_frame_renderer.cpp
// P5-BEAUTY-V2-PRODUCTION-EXPORT-ROUTE-A: VulkanBeautyFrameRenderer implementation.
//
// Android-only real implementation is inside #if defined(__ANDROID__).
// Non-Android translation unit compiles to a safe stub that performs no
// Vulkan calls and reports unavailable, matching the other private Vulkan
// helper host stubs (e.g. VulkanBeautyV2Compositor).
//
// Caching model (see the file header of vulkan_beauty_frame_renderer.h):
//   - Shared, extent-independent objects (the intermediate RGBA8 render
//     pass, the blur/composite/placement descriptor set layouts + pipeline
//     layouts + shader modules, the blur/composite pipelines, the two
//     samplers) are created lazily ONCE on the first recordBeauty() call and
//     reused for the life of the device.
//   - The placement pipeline additionally depends on the caller's swapchain
//     render pass, which CAN change (surface resize/reattach); the crop pass
//     pipeline depends on the AHardwareBuffer import's own pipeline layout,
//     which changes on every decoded frame by construction (a fresh import
//     per frame). Both are therefore cached ONE PER frame-in-flight slot
//     (not shared) and rebuilt for a given slot whenever that slot's
//     dependency changes -- never behind a vkDeviceWaitIdle: by the time
//     recordBeauty() is called for a slot, the caller has already waited
//     that slot's own frame fence, so no in-flight command buffer can still
//     reference that slot's previous pipeline. A single shared pipeline
//     instance would instead need a device-wide idle on effectively every
//     frame (the AHB-import layout churns per frame), which the frozen
//     render-loop contract forbids.
//   - Per-(cropWidth,cropHeight) geometry: four RGBA8 images/views/memory,
//     their framebuffers, and the descriptor sets that bind them, duplicated
//     per frame-in-flight slot. Created lazily on first use for that
//     geometry and reused thereafter; never recreated per frame.

#include "vulkan_beauty_frame_renderer.h"

#include <string>
#include <vector>

#if defined(__ANDROID__)

#include "vulkan_beauty_v2_compositor.h"
#include "vulkan_graphics_pipeline.h"
#include "vulkan_hardware_buffer_image.h"
#include "vulkan_shader_module.h"

#include "shaders/beauty_v2_blur_frag_spv.h"
#include "shaders/beauty_v2_composite_frag_spv.h"

#include <android/log.h>

#define VGLOG_BFR(...) \
    __android_log_print(ANDROID_LOG_DEBUG, "VanguardVkBeautyFrameRnd", __VA_ARGS__)

namespace vanguard {
namespace render {

namespace {

constexpr VkFormat kBeautyFormat = VK_FORMAT_R8G8B8A8_UNORM;

constexpr const char* kErrInvalidArguments   = "beauty_v2_invalid_arguments";
constexpr const char* kErrInvalidDimensions  = "beauty_v2_invalid_dimensions";
constexpr const char* kErrInvalidParameters  = "beauty_v2_invalid_parameters";
constexpr const char* kErrCoreShaderMismatch = "beauty_v2_core_shader_mismatch";
constexpr const char* kErrImageFailed        = "beauty_v2_image_failed";
constexpr const char* kErrShaderModuleFailed = "beauty_v2_shader_module_failed";
constexpr const char* kErrDescriptorFailed   = "beauty_v2_descriptor_failed";
constexpr const char* kErrRenderPassFailed   = "beauty_v2_render_pass_failed";
constexpr const char* kErrPipelineFailed     = "beauty_v2_pipeline_failed";

void SetErr(std::string* outError, const char* reason) {
    if (outError) *outError = reason;
}

uint32_t FindMemoryType(const VkPhysicalDeviceMemoryProperties& props,
                        uint32_t typeBits,
                        VkMemoryPropertyFlags required) {
    for (uint32_t i = 0; i < props.memoryTypeCount; ++i) {
        if ((typeBits & (1u << i)) != 0 &&
            (props.memoryTypes[i].propertyFlags & required) == required) {
            return i;
        }
    }
    return UINT32_MAX;
}

// Push-constant layouts shared with VulkanBeautyV2Compositor (blur/composite
// fragment-only ranges start at byte offset 32; vertex range always spans
// bytes [0,32) with identity UV values since these shaders address texels
// via gl_FragCoord, never the vertex UV varying).
struct alignas(16) VertexUvPushConstants {
    float uvTransform0[4];
    float uvTransform1[4];
};
static_assert(sizeof(VertexUvPushConstants) == 32, "VertexUvPushConstants must be 32 bytes");

constexpr uint32_t kVideoTransformFullPushConstantSize = 112u;

struct alignas(16) BlurPushConstants {
    int32_t width;
    int32_t height;
    int32_t radius;
    int32_t axis; // 0 = horizontal, 1 = vertical
    float sigma;
    float rangeSigma;
    float pad0;
    float pad1;
};
static_assert(sizeof(BlurPushConstants) == 32, "BlurPushConstants must be 32 bytes");

struct alignas(16) CompositePushConstants {
    int32_t width;
    int32_t height;
    int32_t pad0;
    int32_t pad1;
    float smoothStrength;
    float sharpenStrength;
    float theta;
    float detailDamping;
    float toneStrength;
    float midtoneLift;
    float pad2;
    float pad3;
};
static_assert(sizeof(CompositePushConstants) == 48, "CompositePushConstants must be 48 bytes");

VertexUvPushConstants IdentityUvPushConstants() {
    VertexUvPushConstants pc{};
    pc.uvTransform0[0] = 1.0f; pc.uvTransform0[1] = 0.0f; pc.uvTransform0[2] = 0.0f; pc.uvTransform0[3] = 0.0f;
    pc.uvTransform1[0] = 0.0f; pc.uvTransform1[1] = 1.0f; pc.uvTransform1[2] = 0.0f; pc.uvTransform1[3] = 0.0f;
    return pc;
}

} // namespace

// ---------------------------------------------------------------------------
// Impl
// ---------------------------------------------------------------------------

struct VulkanBeautyFrameRenderer::Impl {
    // ── Shared (extent-independent), lazily created once. ───────────────────
    bool sharedInitialized = false;
    VkShaderModule cachedVertexModule = VK_NULL_HANDLE;   // borrowed (coreShaders.vertex)
    VkShaderModule cachedFragmentModule = VK_NULL_HANDLE; // borrowed (coreShaders.fragment)

    VkRenderPass intermediateRenderPass = VK_NULL_HANDLE; // RGBA8, final layout SHADER_READ_ONLY_OPTIMAL
    VkSampler intermediateSampler = VK_NULL_HANDLE;        // clamp/nearest: orig/blurH/mean
    VkSampler placementSampler = VK_NULL_HANDLE;           // clamp/linear: beautified

    VulkanShaderModule blurFragment;
    VulkanShaderModule compositeFragment;

    VkDescriptorSetLayout blurSetLayout = VK_NULL_HANDLE;      // 1 binding
    VkDescriptorSetLayout compositeSetLayout = VK_NULL_HANDLE; // 2 bindings
    VkDescriptorSetLayout placementSetLayout = VK_NULL_HANDLE; // 1 binding, FRAGMENT_BIT

    VkPipelineLayout blurPipelineLayout = VK_NULL_HANDLE;
    VkPipelineLayout compositePipelineLayout = VK_NULL_HANDLE;
    VkPipelineLayout placementPipelineLayout = VK_NULL_HANDLE;

    VulkanGraphicsPipeline blurPipeline;
    VulkanGraphicsPipeline compositePipeline;

    // ── Per-frame-in-flight-slot pipeline caches. ────────────────────────
    // Both the placement pipeline (depends on the caller's swapchain render
    // pass, which can change on resize/reattach) and the crop pipeline
    // (depends on the per-import pipeline layout, which changes on every
    // decoded frame by construction -- a fresh AHardwareBuffer import per
    // frame) are cached ONE PER frame-in-flight slot rather than as a single
    // shared instance. This mirrors the identical per-slot reuse the
    // GeometryResources cache below already relies on: by the time
    // recordBeauty() is invoked for a given frameSlotIndex, the caller
    // (VulkanFrameRenderer::renderFrame) has already waited that exact
    // slot's frame fence, so no other in-flight command buffer can still
    // reference that slot's previous pipeline -- destroying and rebuilding
    // it here needs no vkDeviceWaitIdle. A single shared pipeline rebuilt on
    // every crop-layout change (which the AHB-import churn makes an
    // effectively PER-FRAME event) would instead require a device-wide idle
    // in the frame loop, which the frozen render-loop contract forbids.
    struct CropPipelineSlot {
        VulkanGraphicsPipeline pipeline;
        VkPipelineLayout layout = VK_NULL_HANDLE; // borrowed; last layout this slot's pipeline was built against
    };
    struct PlacementPipelineSlot {
        VulkanGraphicsPipeline pipeline;
        VkRenderPass renderPass = VK_NULL_HANDLE; // borrowed; last render pass this slot's pipeline was built against
    };
    std::vector<CropPipelineSlot> cropPipelineSlots;
    std::vector<PlacementPipelineSlot> placementPipelineSlots;

    // ── Per-(cropWidth,cropHeight) geometry cache. ───────────────────────────
    struct RgbaImage {
        VkImage        image  = VK_NULL_HANDLE;
        VkDeviceMemory memory = VK_NULL_HANDLE;
        VkImageView    view   = VK_NULL_HANDLE;
    };

    struct SlotResources {
        RgbaImage orig;
        RgbaImage blurH;
        RgbaImage mean;
        RgbaImage beautified;

        VkFramebuffer fboOrig = VK_NULL_HANDLE;
        VkFramebuffer fboBlurH = VK_NULL_HANDLE;
        VkFramebuffer fboMean = VK_NULL_HANDLE;
        VkFramebuffer fboBeautified = VK_NULL_HANDLE;

        VkDescriptorSet blurSetH = VK_NULL_HANDLE;
        VkDescriptorSet blurSetV = VK_NULL_HANDLE;
        VkDescriptorSet compositeSet = VK_NULL_HANDLE;
        VkDescriptorSet placementSet = VK_NULL_HANDLE;
    };

    struct GeometryResources {
        uint32_t cropWidth = 0;
        uint32_t cropHeight = 0;
        VkDescriptorPool pool = VK_NULL_HANDLE; // owns every set across every slot for this geometry
        std::vector<SlotResources> slots;
    };

    std::vector<GeometryResources> geometries;

    uint64_t created = 0;
    uint64_t released = 0;

    // ── Shared-resource setup ────────────────────────────────────────────
    bool ensureSharedResources(VkDevice device,
                               VkShaderModule vertexModule,
                               VkShaderModule fragmentModule,
                               std::string* outError) {
        if (sharedInitialized) {
            if (vertexModule != cachedVertexModule || fragmentModule != cachedFragmentModule) {
                SetErr(outError, kErrCoreShaderMismatch);
                return false;
            }
            return true;
        }

        cachedVertexModule = vertexModule;
        cachedFragmentModule = fragmentModule;

        // Intermediate render pass: single RGBA8 color attachment, DONT_CARE
        // load (every pixel is unconditionally overwritten by a fullscreen
        // triangle), final layout SHADER_READ_ONLY_OPTIMAL so the next pass
        // (or the placement pass, for "beautified") can sample the result.
        // Reused, unmodified, for every frame this geometry's images serve --
        // safe because VK_IMAGE_LAYOUT_UNDEFINED as initialLayout means "the
        // driver need not preserve prior contents", which holds regardless of
        // the image's actual previous layout when the whole attachment is
        // about to be overwritten, as it always is here.
        {
            VkAttachmentDescription color{};
            color.format         = kBeautyFormat;
            color.samples        = VK_SAMPLE_COUNT_1_BIT;
            color.loadOp         = VK_ATTACHMENT_LOAD_OP_DONT_CARE;
            color.storeOp        = VK_ATTACHMENT_STORE_OP_STORE;
            color.stencilLoadOp  = VK_ATTACHMENT_LOAD_OP_DONT_CARE;
            color.stencilStoreOp = VK_ATTACHMENT_STORE_OP_DONT_CARE;
            color.initialLayout  = VK_IMAGE_LAYOUT_UNDEFINED;
            color.finalLayout    = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;

            VkAttachmentReference colorRef{};
            colorRef.attachment = 0;
            colorRef.layout     = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL;

            VkSubpassDescription subpass{};
            subpass.pipelineBindPoint    = VK_PIPELINE_BIND_POINT_GRAPHICS;
            subpass.colorAttachmentCount = 1;
            subpass.pColorAttachments    = &colorRef;

            // dep[0]: any prior read (by a later pass in an earlier frame
            // occupying this same slot, or an earlier pass within this same
            // frame) must complete before this pass writes (WAR hazard).
            // dep[1]: this pass's write must complete before any later
            // fragment-shader sample (RAW hazard), matching the diagnostic
            // VulkanBeautyV2Compositor's identical dependency pair.
            VkSubpassDependency deps[2]{};
            deps[0].srcSubpass    = VK_SUBPASS_EXTERNAL;
            deps[0].dstSubpass    = 0;
            deps[0].srcStageMask  = VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT;
            deps[0].dstStageMask  = VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT;
            deps[0].srcAccessMask = VK_ACCESS_SHADER_READ_BIT;
            deps[0].dstAccessMask = VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT;
            deps[1].srcSubpass    = 0;
            deps[1].dstSubpass    = VK_SUBPASS_EXTERNAL;
            deps[1].srcStageMask  = VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT;
            deps[1].dstStageMask  = VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT;
            deps[1].srcAccessMask = VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT;
            deps[1].dstAccessMask = VK_ACCESS_SHADER_READ_BIT;

            VkRenderPassCreateInfo rpCI{};
            rpCI.sType           = VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO;
            rpCI.attachmentCount = 1;
            rpCI.pAttachments    = &color;
            rpCI.subpassCount    = 1;
            rpCI.pSubpasses      = &subpass;
            rpCI.dependencyCount = 2;
            rpCI.pDependencies   = deps;
            if (vkCreateRenderPass(device, &rpCI, nullptr, &intermediateRenderPass) != VK_SUCCESS) {
                intermediateRenderPass = VK_NULL_HANDLE;
                SetErr(outError, kErrRenderPassFailed);
                return false;
            }
            ++created;
        }

        // Samplers: clamp-to-edge on both. NEAREST for the beauty
        // intermediates (blur/composite shaders address texels exclusively
        // via texelFetch, matching VulkanBeautyV2Compositor); LINEAR for
        // "beautified" so the placement pass's aspect-fit destination-rect
        // scaling interpolates smoothly, matching the caller's normal
        // (non-beauty) sampling quality.
        {
            VkSamplerCreateInfo samplerCI{};
            samplerCI.sType        = VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO;
            samplerCI.magFilter    = VK_FILTER_NEAREST;
            samplerCI.minFilter    = VK_FILTER_NEAREST;
            samplerCI.mipmapMode   = VK_SAMPLER_MIPMAP_MODE_NEAREST;
            samplerCI.addressModeU = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE;
            samplerCI.addressModeV = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE;
            samplerCI.addressModeW = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE;
            samplerCI.maxAnisotropy = 1.0f;
            if (vkCreateSampler(device, &samplerCI, nullptr, &intermediateSampler) != VK_SUCCESS) {
                intermediateSampler = VK_NULL_HANDLE;
                SetErr(outError, kErrImageFailed);
                return false;
            }
            ++created;

            samplerCI.magFilter = VK_FILTER_LINEAR;
            samplerCI.minFilter = VK_FILTER_LINEAR;
            if (vkCreateSampler(device, &samplerCI, nullptr, &placementSampler) != VK_SUCCESS) {
                placementSampler = VK_NULL_HANDLE;
                SetErr(outError, kErrImageFailed);
                return false;
            }
            ++created;
        }

        // Fragment shader modules (blur shared by axis 0/1; composite).
        // The vertex stage reuses the caller's existing AOT passthrough
        // module (cachedVertexModule) -- no separate vertex module is loaded.
        if (!blurFragment.create(device, shaders::kBeautyV2BlurFragSpv, shaders::kBeautyV2BlurFragSpvSize,
                                 "beauty_v2_prod_blur_frag")) {
            SetErr(outError, kErrShaderModuleFailed);
            return false;
        }
        ++created;
        if (!compositeFragment.create(device, shaders::kBeautyV2CompositeFragSpv,
                                      shaders::kBeautyV2CompositeFragSpvSize, "beauty_v2_prod_composite_frag")) {
            SetErr(outError, kErrShaderModuleFailed);
            return false;
        }
        ++created;

        // Descriptor set layouts.
        {
            VkDescriptorSetLayoutBinding blurBinding{};
            blurBinding.binding         = 0;
            blurBinding.descriptorType  = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
            blurBinding.descriptorCount = 1;
            blurBinding.stageFlags      = VK_SHADER_STAGE_FRAGMENT_BIT;
            VkDescriptorSetLayoutCreateInfo blurLayoutCI{};
            blurLayoutCI.sType        = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO;
            blurLayoutCI.bindingCount = 1;
            blurLayoutCI.pBindings    = &blurBinding;
            if (vkCreateDescriptorSetLayout(device, &blurLayoutCI, nullptr, &blurSetLayout) != VK_SUCCESS) {
                blurSetLayout = VK_NULL_HANDLE;
                SetErr(outError, kErrDescriptorFailed);
                return false;
            }
            ++created;

            VkDescriptorSetLayoutBinding compositeBindings[2]{};
            compositeBindings[0].binding         = 0;
            compositeBindings[0].descriptorType  = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
            compositeBindings[0].descriptorCount = 1;
            compositeBindings[0].stageFlags      = VK_SHADER_STAGE_FRAGMENT_BIT;
            compositeBindings[1].binding         = 1;
            compositeBindings[1].descriptorType  = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
            compositeBindings[1].descriptorCount = 1;
            compositeBindings[1].stageFlags      = VK_SHADER_STAGE_FRAGMENT_BIT;
            VkDescriptorSetLayoutCreateInfo compositeLayoutCI{};
            compositeLayoutCI.sType        = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO;
            compositeLayoutCI.bindingCount = 2;
            compositeLayoutCI.pBindings    = compositeBindings;
            if (vkCreateDescriptorSetLayout(device, &compositeLayoutCI, nullptr, &compositeSetLayout) != VK_SUCCESS) {
                compositeSetLayout = VK_NULL_HANDLE;
                SetErr(outError, kErrDescriptorFailed);
                return false;
            }
            ++created;

            VkDescriptorSetLayoutBinding placementBinding{};
            placementBinding.binding         = 0;
            placementBinding.descriptorType  = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
            placementBinding.descriptorCount = 1;
            placementBinding.stageFlags      = VK_SHADER_STAGE_FRAGMENT_BIT;
            VkDescriptorSetLayoutCreateInfo placementLayoutCI{};
            placementLayoutCI.sType        = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO;
            placementLayoutCI.bindingCount = 1;
            placementLayoutCI.pBindings    = &placementBinding;
            if (vkCreateDescriptorSetLayout(device, &placementLayoutCI, nullptr, &placementSetLayout) != VK_SUCCESS) {
                placementSetLayout = VK_NULL_HANDLE;
                SetErr(outError, kErrDescriptorFailed);
                return false;
            }
            ++created;
        }

        // Pipeline layouts. Blur/composite: vertex range [0,32) + fragment
        // range starting at byte offset 32, matching the .frag sources'
        // `layout(offset = 32)` blocks and VulkanBeautyV2Compositor's
        // identical convention. Placement: single VERTEX|FRAGMENT range
        // covering the full VideoTransformFullPushConstants block, matching
        // VulkanDescriptorResources's (and thus the non-beauty solo path's)
        // convention exactly, so coreShaders' existing shader modules need no
        // beauty-specific variant.
        {
            VkPushConstantRange vertexRange{};
            vertexRange.stageFlags = VK_SHADER_STAGE_VERTEX_BIT;
            vertexRange.offset     = 0;
            vertexRange.size       = kVideoTransformFullPushConstantSize;

            VkPushConstantRange blurFragRange{};
            blurFragRange.stageFlags = VK_SHADER_STAGE_FRAGMENT_BIT;
            blurFragRange.offset     = static_cast<uint32_t>(sizeof(VertexUvPushConstants));
            blurFragRange.size       = static_cast<uint32_t>(sizeof(BlurPushConstants));

            const VkPushConstantRange blurRanges[2] = {vertexRange, blurFragRange};
            VkPipelineLayoutCreateInfo blurPlCI{};
            blurPlCI.sType                  = VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO;
            blurPlCI.setLayoutCount         = 1;
            blurPlCI.pSetLayouts            = &blurSetLayout;
            blurPlCI.pushConstantRangeCount = 2;
            blurPlCI.pPushConstantRanges    = blurRanges;
            if (vkCreatePipelineLayout(device, &blurPlCI, nullptr, &blurPipelineLayout) != VK_SUCCESS) {
                blurPipelineLayout = VK_NULL_HANDLE;
                SetErr(outError, kErrDescriptorFailed);
                return false;
            }
            ++created;

            VkPushConstantRange compositeFragRange{};
            compositeFragRange.stageFlags = VK_SHADER_STAGE_FRAGMENT_BIT;
            compositeFragRange.offset     = static_cast<uint32_t>(sizeof(VertexUvPushConstants));
            compositeFragRange.size       = static_cast<uint32_t>(sizeof(CompositePushConstants));

            const VkPushConstantRange compositeRanges[2] = {vertexRange, compositeFragRange};
            VkPipelineLayoutCreateInfo compositePlCI{};
            compositePlCI.sType                  = VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO;
            compositePlCI.setLayoutCount         = 1;
            compositePlCI.pSetLayouts            = &compositeSetLayout;
            compositePlCI.pushConstantRangeCount = 2;
            compositePlCI.pPushConstantRanges    = compositeRanges;
            if (vkCreatePipelineLayout(device, &compositePlCI, nullptr, &compositePipelineLayout) != VK_SUCCESS) {
                compositePipelineLayout = VK_NULL_HANDLE;
                SetErr(outError, kErrDescriptorFailed);
                return false;
            }
            ++created;

            VkPushConstantRange fullRange{};
            fullRange.stageFlags = VK_SHADER_STAGE_VERTEX_BIT | VK_SHADER_STAGE_FRAGMENT_BIT;
            fullRange.offset     = 0;
            fullRange.size       = kVideoTransformFullPushConstantSize;

            VkPipelineLayoutCreateInfo placementPlCI{};
            placementPlCI.sType                  = VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO;
            placementPlCI.setLayoutCount         = 1;
            placementPlCI.pSetLayouts            = &placementSetLayout;
            placementPlCI.pushConstantRangeCount = 1;
            placementPlCI.pPushConstantRanges    = &fullRange;
            if (vkCreatePipelineLayout(device, &placementPlCI, nullptr, &placementPipelineLayout) != VK_SUCCESS) {
                placementPipelineLayout = VK_NULL_HANDLE;
                SetErr(outError, kErrDescriptorFailed);
                return false;
            }
            ++created;
        }

        // Blur/composite pipelines: extent-independent (dynamic
        // viewport/scissor), so built once against intermediateRenderPass.
        if (!blurPipeline.create(device, blurPipelineLayout, intermediateRenderPass,
                                 cachedVertexModule, blurFragment.get())) {
            SetErr(outError, kErrPipelineFailed);
            return false;
        }
        ++created;
        if (!compositePipeline.create(device, compositePipelineLayout, intermediateRenderPass,
                                      cachedVertexModule, compositeFragment.get())) {
            SetErr(outError, kErrPipelineFailed);
            return false;
        }
        ++created;

        sharedInitialized = true;
        return true;
    }

    // ── Crop-pass pipeline: rebuilt per-slot whenever that slot's AHB
    // import layout differs from what it was last built against. See the
    // per-slot cache doc above for why this needs no vkDeviceWaitIdle.
    bool ensureCropPipeline(VkDevice device, uint32_t frameSlotIndex, uint32_t frameCount,
                            VkPipelineLayout wantedLayout, std::string* outError) {
        if (!cropPipelineSlots.empty() && cropPipelineSlots.size() != frameCount) {
            SetErr(outError, kErrInvalidDimensions);
            return false;
        }
        if (cropPipelineSlots.empty()) {
            cropPipelineSlots.resize(frameCount);
        }
        CropPipelineSlot& slot = cropPipelineSlots[frameSlotIndex];
        if (slot.pipeline.isValid() && slot.layout == wantedLayout) {
            return true;
        }
        slot.pipeline.destroy(device);
        if (!slot.pipeline.create(device, wantedLayout, intermediateRenderPass,
                                  cachedVertexModule, cachedFragmentModule)) {
            slot.layout = VK_NULL_HANDLE;
            SetErr(outError, kErrPipelineFailed);
            return false;
        }
        slot.layout = wantedLayout;
        ++created;
        return true;
    }

    // ── Placement pipeline: rebuilt per-slot whenever that slot's swapchain
    // render pass differs from what it was last built against. See the
    // per-slot cache doc above for why this needs no vkDeviceWaitIdle.
    bool ensurePlacementPipeline(VkDevice device, uint32_t frameSlotIndex, uint32_t frameCount,
                                 VkRenderPass wantedRenderPass, std::string* outError) {
        if (!placementPipelineSlots.empty() && placementPipelineSlots.size() != frameCount) {
            SetErr(outError, kErrInvalidDimensions);
            return false;
        }
        if (placementPipelineSlots.empty()) {
            placementPipelineSlots.resize(frameCount);
        }
        PlacementPipelineSlot& slot = placementPipelineSlots[frameSlotIndex];
        if (slot.pipeline.isValid() && slot.renderPass == wantedRenderPass) {
            return true;
        }
        slot.pipeline.destroy(device);
        if (!slot.pipeline.create(device, placementPipelineLayout, wantedRenderPass,
                                  cachedVertexModule, cachedFragmentModule)) {
            slot.renderPass = VK_NULL_HANDLE;
            SetErr(outError, kErrPipelineFailed);
            return false;
        }
        slot.renderPass = wantedRenderPass;
        ++created;
        return true;
    }

    // ── Per-geometry resource cache. ─────────────────────────────────────
    bool createRgbaImage(VkDevice device, VkPhysicalDevice physicalDevice,
                         uint32_t width, uint32_t height, RgbaImage* out, std::string* outError) {
        VkImageCreateInfo imgCI{};
        imgCI.sType         = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO;
        imgCI.imageType     = VK_IMAGE_TYPE_2D;
        imgCI.format        = kBeautyFormat;
        imgCI.extent        = {width, height, 1};
        imgCI.mipLevels     = 1;
        imgCI.arrayLayers   = 1;
        imgCI.samples       = VK_SAMPLE_COUNT_1_BIT;
        imgCI.tiling        = VK_IMAGE_TILING_OPTIMAL;
        imgCI.usage         = VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | VK_IMAGE_USAGE_SAMPLED_BIT;
        imgCI.sharingMode   = VK_SHARING_MODE_EXCLUSIVE;
        imgCI.initialLayout = VK_IMAGE_LAYOUT_UNDEFINED;
        if (vkCreateImage(device, &imgCI, nullptr, &out->image) != VK_SUCCESS) {
            out->image = VK_NULL_HANDLE;
            SetErr(outError, kErrImageFailed);
            return false;
        }
        ++created;

        VkMemoryRequirements req{};
        vkGetImageMemoryRequirements(device, out->image, &req);
        VkPhysicalDeviceMemoryProperties memProps{};
        vkGetPhysicalDeviceMemoryProperties(physicalDevice, &memProps);
        uint32_t typeIndex = FindMemoryType(memProps, req.memoryTypeBits, VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT);
        if (typeIndex == UINT32_MAX) typeIndex = FindMemoryType(memProps, req.memoryTypeBits, 0);
        if (typeIndex == UINT32_MAX) {
            SetErr(outError, kErrImageFailed);
            return false;
        }
        VkMemoryAllocateInfo alloc{};
        alloc.sType           = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
        alloc.allocationSize  = req.size;
        alloc.memoryTypeIndex = typeIndex;
        if (vkAllocateMemory(device, &alloc, nullptr, &out->memory) != VK_SUCCESS) {
            out->memory = VK_NULL_HANDLE;
            SetErr(outError, kErrImageFailed);
            return false;
        }
        ++created;
        if (vkBindImageMemory(device, out->image, out->memory, 0) != VK_SUCCESS) {
            SetErr(outError, kErrImageFailed);
            return false;
        }

        VkImageViewCreateInfo viewCI{};
        viewCI.sType                       = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO;
        viewCI.image                       = out->image;
        viewCI.viewType                    = VK_IMAGE_VIEW_TYPE_2D;
        viewCI.format                      = kBeautyFormat;
        viewCI.subresourceRange.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
        viewCI.subresourceRange.levelCount = 1;
        viewCI.subresourceRange.layerCount = 1;
        if (vkCreateImageView(device, &viewCI, nullptr, &out->view) != VK_SUCCESS) {
            out->view = VK_NULL_HANDLE;
            SetErr(outError, kErrImageFailed);
            return false;
        }
        ++created;
        return true;
    }

    bool createFramebuffer(VkDevice device, VkImageView view, uint32_t width, uint32_t height,
                           VkFramebuffer* outFbo, std::string* outError) {
        VkFramebufferCreateInfo fbCI{};
        fbCI.sType           = VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO;
        fbCI.renderPass      = intermediateRenderPass;
        fbCI.attachmentCount = 1;
        fbCI.pAttachments    = &view;
        fbCI.width           = width;
        fbCI.height          = height;
        fbCI.layers          = 1;
        if (vkCreateFramebuffer(device, &fbCI, nullptr, outFbo) != VK_SUCCESS) {
            *outFbo = VK_NULL_HANDLE;
            SetErr(outError, kErrRenderPassFailed);
            return false;
        }
        ++created;
        return true;
    }

    bool buildSlot(VkDevice device, VkPhysicalDevice physicalDevice, GeometryResources& g,
                  SlotResources* slot, std::string* outError) {
        if (!createRgbaImage(device, physicalDevice, g.cropWidth, g.cropHeight, &slot->orig, outError) ||
            !createRgbaImage(device, physicalDevice, g.cropWidth, g.cropHeight, &slot->blurH, outError) ||
            !createRgbaImage(device, physicalDevice, g.cropWidth, g.cropHeight, &slot->mean, outError) ||
            !createRgbaImage(device, physicalDevice, g.cropWidth, g.cropHeight, &slot->beautified, outError)) {
            return false;
        }
        if (!createFramebuffer(device, slot->orig.view, g.cropWidth, g.cropHeight, &slot->fboOrig, outError) ||
            !createFramebuffer(device, slot->blurH.view, g.cropWidth, g.cropHeight, &slot->fboBlurH, outError) ||
            !createFramebuffer(device, slot->mean.view, g.cropWidth, g.cropHeight, &slot->fboMean, outError) ||
            !createFramebuffer(device, slot->beautified.view, g.cropWidth, g.cropHeight, &slot->fboBeautified, outError)) {
            return false;
        }

        const VkDescriptorSetLayout layouts[4] = {
            blurSetLayout, blurSetLayout, compositeSetLayout, placementSetLayout,
        };
        VkDescriptorSet sets[4] = {VK_NULL_HANDLE, VK_NULL_HANDLE, VK_NULL_HANDLE, VK_NULL_HANDLE};
        VkDescriptorSetAllocateInfo allocInfo{};
        allocInfo.sType              = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO;
        allocInfo.descriptorPool     = g.pool;
        allocInfo.descriptorSetCount = 4;
        allocInfo.pSetLayouts        = layouts;
        if (vkAllocateDescriptorSets(device, &allocInfo, sets) != VK_SUCCESS) {
            SetErr(outError, kErrDescriptorFailed);
            return false;
        }
        slot->blurSetH = sets[0];
        slot->blurSetV = sets[1];
        slot->compositeSet = sets[2];
        slot->placementSet = sets[3];

        VkDescriptorImageInfo origInfo{};
        origInfo.sampler     = intermediateSampler;
        origInfo.imageView   = slot->orig.view;
        origInfo.imageLayout = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;

        VkDescriptorImageInfo blurHInfo{};
        blurHInfo.sampler     = intermediateSampler;
        blurHInfo.imageView   = slot->blurH.view;
        blurHInfo.imageLayout = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;

        VkDescriptorImageInfo meanInfo{};
        meanInfo.sampler     = intermediateSampler;
        meanInfo.imageView   = slot->mean.view;
        meanInfo.imageLayout = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;

        VkDescriptorImageInfo beautifiedInfo{};
        beautifiedInfo.sampler     = placementSampler;
        beautifiedInfo.imageView   = slot->beautified.view;
        beautifiedInfo.imageLayout = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;

        VkWriteDescriptorSet writes[5]{};
        writes[0].sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
        writes[0].dstSet = slot->blurSetH;
        writes[0].dstBinding = 0;
        writes[0].descriptorCount = 1;
        writes[0].descriptorType = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
        writes[0].pImageInfo = &origInfo;

        writes[1].sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
        writes[1].dstSet = slot->blurSetV;
        writes[1].dstBinding = 0;
        writes[1].descriptorCount = 1;
        writes[1].descriptorType = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
        writes[1].pImageInfo = &blurHInfo;

        writes[2].sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
        writes[2].dstSet = slot->compositeSet;
        writes[2].dstBinding = 0;
        writes[2].descriptorCount = 1;
        writes[2].descriptorType = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
        writes[2].pImageInfo = &origInfo;

        writes[3].sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
        writes[3].dstSet = slot->compositeSet;
        writes[3].dstBinding = 1;
        writes[3].descriptorCount = 1;
        writes[3].descriptorType = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
        writes[3].pImageInfo = &meanInfo;

        writes[4].sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
        writes[4].dstSet = slot->placementSet;
        writes[4].dstBinding = 0;
        writes[4].descriptorCount = 1;
        writes[4].descriptorType = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
        writes[4].pImageInfo = &beautifiedInfo;

        vkUpdateDescriptorSets(device, 5, writes, 0, nullptr);
        return true;
    }

    void destroySlot(VkDevice device, SlotResources& slot) {
        auto destroyImage = [&](RgbaImage& img) {
            if (img.view != VK_NULL_HANDLE) { vkDestroyImageView(device, img.view, nullptr); img.view = VK_NULL_HANDLE; ++released; }
            if (img.image != VK_NULL_HANDLE) { vkDestroyImage(device, img.image, nullptr); img.image = VK_NULL_HANDLE; ++released; }
            if (img.memory != VK_NULL_HANDLE) { vkFreeMemory(device, img.memory, nullptr); img.memory = VK_NULL_HANDLE; ++released; }
        };
        if (slot.fboBeautified != VK_NULL_HANDLE) { vkDestroyFramebuffer(device, slot.fboBeautified, nullptr); slot.fboBeautified = VK_NULL_HANDLE; ++released; }
        if (slot.fboMean != VK_NULL_HANDLE) { vkDestroyFramebuffer(device, slot.fboMean, nullptr); slot.fboMean = VK_NULL_HANDLE; ++released; }
        if (slot.fboBlurH != VK_NULL_HANDLE) { vkDestroyFramebuffer(device, slot.fboBlurH, nullptr); slot.fboBlurH = VK_NULL_HANDLE; ++released; }
        if (slot.fboOrig != VK_NULL_HANDLE) { vkDestroyFramebuffer(device, slot.fboOrig, nullptr); slot.fboOrig = VK_NULL_HANDLE; ++released; }
        destroyImage(slot.beautified);
        destroyImage(slot.mean);
        destroyImage(slot.blurH);
        destroyImage(slot.orig);
        // Descriptor sets are freed implicitly when the owning geometry's pool is destroyed.
    }

    void destroyGeometry(VkDevice device, GeometryResources& g) {
        for (auto& slot : g.slots) {
            destroySlot(device, slot);
        }
        g.slots.clear();
        if (g.pool != VK_NULL_HANDLE) {
            vkDestroyDescriptorPool(device, g.pool, nullptr);
            g.pool = VK_NULL_HANDLE;
            ++released;
        }
    }

    GeometryResources* findOrCreateGeometry(VkDevice device, VkPhysicalDevice physicalDevice,
                                            uint32_t cropWidth, uint32_t cropHeight, uint32_t frameCount,
                                            std::string* outError) {
        for (auto& g : geometries) {
            if (g.cropWidth == cropWidth && g.cropHeight == cropHeight) {
                if (g.slots.size() != frameCount) {
                    SetErr(outError, kErrInvalidDimensions);
                    return nullptr;
                }
                return &g;
            }
        }

        geometries.emplace_back();
        GeometryResources& g = geometries.back();
        g.cropWidth = cropWidth;
        g.cropHeight = cropHeight;

        // One descriptor pool per geometry: frameCount slots x (1 + 1 + 2 + 1)
        // combined-image-sampler descriptors across 4 sets each.
        VkDescriptorPoolSize poolSize{};
        poolSize.type            = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
        poolSize.descriptorCount = frameCount * 5;
        VkDescriptorPoolCreateInfo poolCI{};
        poolCI.sType         = VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO;
        poolCI.maxSets       = frameCount * 4;
        poolCI.poolSizeCount = 1;
        poolCI.pPoolSizes    = &poolSize;
        if (vkCreateDescriptorPool(device, &poolCI, nullptr, &g.pool) != VK_SUCCESS) {
            g.pool = VK_NULL_HANDLE;
            SetErr(outError, kErrDescriptorFailed);
            geometries.pop_back();
            return nullptr;
        }
        ++created;

        g.slots.resize(frameCount);
        for (uint32_t i = 0; i < frameCount; ++i) {
            if (!buildSlot(device, physicalDevice, g, &g.slots[i], outError)) {
                destroyGeometry(device, g);
                geometries.pop_back();
                return nullptr;
            }
        }
        return &geometries.back();
    }

    void shutdownAll(VkDevice device) {
        if (device == VK_NULL_HANDLE) {
            geometries.clear();
            sharedInitialized = false;
            return;
        }
        for (auto& slot : cropPipelineSlots) {
            slot.pipeline.destroy(device);
        }
        cropPipelineSlots.clear();
        for (auto& slot : placementPipelineSlots) {
            slot.pipeline.destroy(device);
        }
        placementPipelineSlots.clear();
        blurPipeline.destroy(device);
        compositePipeline.destroy(device);

        for (auto& g : geometries) {
            destroyGeometry(device, g);
        }
        geometries.clear();

        if (placementPipelineLayout != VK_NULL_HANDLE) {
            vkDestroyPipelineLayout(device, placementPipelineLayout, nullptr);
            placementPipelineLayout = VK_NULL_HANDLE;
            ++released;
        }
        if (compositePipelineLayout != VK_NULL_HANDLE) {
            vkDestroyPipelineLayout(device, compositePipelineLayout, nullptr);
            compositePipelineLayout = VK_NULL_HANDLE;
            ++released;
        }
        if (blurPipelineLayout != VK_NULL_HANDLE) {
            vkDestroyPipelineLayout(device, blurPipelineLayout, nullptr);
            blurPipelineLayout = VK_NULL_HANDLE;
            ++released;
        }
        if (placementSetLayout != VK_NULL_HANDLE) {
            vkDestroyDescriptorSetLayout(device, placementSetLayout, nullptr);
            placementSetLayout = VK_NULL_HANDLE;
            ++released;
        }
        if (compositeSetLayout != VK_NULL_HANDLE) {
            vkDestroyDescriptorSetLayout(device, compositeSetLayout, nullptr);
            compositeSetLayout = VK_NULL_HANDLE;
            ++released;
        }
        if (blurSetLayout != VK_NULL_HANDLE) {
            vkDestroyDescriptorSetLayout(device, blurSetLayout, nullptr);
            blurSetLayout = VK_NULL_HANDLE;
            ++released;
        }
        if (compositeFragment.get() != VK_NULL_HANDLE) {
            compositeFragment.destroy(device);
            ++released;
        }
        if (blurFragment.get() != VK_NULL_HANDLE) {
            blurFragment.destroy(device);
            ++released;
        }
        if (placementSampler != VK_NULL_HANDLE) {
            vkDestroySampler(device, placementSampler, nullptr);
            placementSampler = VK_NULL_HANDLE;
            ++released;
        }
        if (intermediateSampler != VK_NULL_HANDLE) {
            vkDestroySampler(device, intermediateSampler, nullptr);
            intermediateSampler = VK_NULL_HANDLE;
            ++released;
        }
        if (intermediateRenderPass != VK_NULL_HANDLE) {
            vkDestroyRenderPass(device, intermediateRenderPass, nullptr);
            intermediateRenderPass = VK_NULL_HANDLE;
            ++released;
        }
        cachedVertexModule = VK_NULL_HANDLE;
        cachedFragmentModule = VK_NULL_HANDLE;
        sharedInitialized = false;
    }
};

// ---------------------------------------------------------------------------
// Public API (Android)
// ---------------------------------------------------------------------------

VulkanBeautyFrameRenderer::VulkanBeautyFrameRenderer() : impl_(std::make_unique<Impl>()) {}
VulkanBeautyFrameRenderer::~VulkanBeautyFrameRenderer() {
    // Callers are required to call shutdown(device) before destruction, but
    // guard defensively: with a null device, shutdownAll only clears CPU-side
    // bookkeeping (see the device==VK_NULL_HANDLE branch above).
    if (impl_) {
        impl_->shutdownAll(VK_NULL_HANDLE);
    }
}

namespace {

// One render pass: begins, binds pipeline/descriptor set/push constants,
// draws the fullscreen triangle, ends. Viewport/scissor cover the full
// framebuffer extent (no destination-rect concept for the four beauty
// passes; only the placement pass below scopes a sub-rect).
void RecordFullExtentPass(VkCommandBuffer cb, VkRenderPass renderPass, VkFramebuffer fbo,
                          uint32_t width, uint32_t height, VkPipeline pipeline,
                          VkPipelineLayout layout, VkDescriptorSet set,
                          const void* vertexPc, uint32_t vertexPcSize,
                          const void* fragPc, uint32_t fragPcOffset, uint32_t fragPcSize) {
    VkClearValue clearValue{};
    clearValue.color = {{0.0f, 0.0f, 0.0f, 1.0f}};

    VkRenderPassBeginInfo rpBegin{};
    rpBegin.sType             = VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO;
    rpBegin.renderPass        = renderPass;
    rpBegin.framebuffer       = fbo;
    rpBegin.renderArea.offset = {0, 0};
    rpBegin.renderArea.extent = {width, height};
    rpBegin.clearValueCount   = 1;
    rpBegin.pClearValues      = &clearValue;
    vkCmdBeginRenderPass(cb, &rpBegin, VK_SUBPASS_CONTENTS_INLINE);

    VkViewport viewport{};
    viewport.width = static_cast<float>(width);
    viewport.height = static_cast<float>(height);
    viewport.minDepth = 0.0f;
    viewport.maxDepth = 1.0f;
    vkCmdSetViewport(cb, 0, 1, &viewport);
    VkRect2D scissor{};
    scissor.extent = {width, height};
    vkCmdSetScissor(cb, 0, 1, &scissor);

    vkCmdBindPipeline(cb, VK_PIPELINE_BIND_POINT_GRAPHICS, pipeline);
    vkCmdBindDescriptorSets(cb, VK_PIPELINE_BIND_POINT_GRAPHICS, layout, 0, 1, &set, 0, nullptr);
    if (vertexPc != nullptr && vertexPcSize > 0) {
        vkCmdPushConstants(cb, layout, VK_SHADER_STAGE_VERTEX_BIT, 0, vertexPcSize, vertexPc);
    }
    if (fragPc != nullptr && fragPcSize > 0) {
        vkCmdPushConstants(cb, layout, VK_SHADER_STAGE_FRAGMENT_BIT, fragPcOffset, fragPcSize, fragPc);
    }
    vkCmdDraw(cb, 3, 1, 0, 0);
    vkCmdEndRenderPass(cb);
}

} // namespace

bool VulkanBeautyFrameRenderer::recordBeauty(
    VkDevice device,
    VkPhysicalDevice physicalDevice,
    VkCommandBuffer commandBuffer,
    uint32_t frameSlotIndex,
    uint32_t frameCount,
    const VulkanHardwareBufferImage& srcImage,
    VkImageLayout srcCurrentLayout,
    VkShaderModule vertexModule,
    VkShaderModule fragmentModule,
    const VideoFrameTransform& placementTransform,
    const VideoBeautyV2RenderParams& beauty,
    VkRenderPass finalRenderPass,
    VkFramebuffer finalFramebuffer,
    uint32_t finalExtentWidth,
    uint32_t finalExtentHeight,
    std::string* outFailureReason) {
    if (outFailureReason) outFailureReason->clear();

    if (device == VK_NULL_HANDLE || physicalDevice == VK_NULL_HANDLE ||
        commandBuffer == VK_NULL_HANDLE || vertexModule == VK_NULL_HANDLE ||
        fragmentModule == VK_NULL_HANDLE || finalRenderPass == VK_NULL_HANDLE ||
        finalFramebuffer == VK_NULL_HANDLE || finalExtentWidth == 0 || finalExtentHeight == 0 ||
        srcImage.image == VK_NULL_HANDLE ||
        srcImage.descriptorResources.pipelineLayout == VK_NULL_HANDLE ||
        srcImage.descriptorResources.descriptorSet == VK_NULL_HANDLE) {
        SetErr(outFailureReason, kErrInvalidArguments);
        return false;
    }
    if (!beauty.enabled || beauty.cropWidth == 0 || beauty.cropHeight == 0 ||
        frameCount == 0 || frameSlotIndex >= frameCount) {
        SetErr(outFailureReason, kErrInvalidDimensions);
        return false;
    }

    VulkanBeautyV2Parameters params{};
    params.radius = beauty.radius;
    params.sigma = beauty.sigma;
    params.rangeSigma = beauty.rangeSigma;
    params.smoothStrength = beauty.smoothStrength;
    params.sharpenStrength = beauty.sharpenStrength;
    params.theta = beauty.theta;
    params.detailDamping = beauty.detailDamping;
    params.toneStrength = beauty.toneStrength;
    params.midtoneLift = beauty.midtoneLift;
    {
        std::string ignored;
        if (!ValidateVulkanBeautyV2Parameters(params, beauty.cropWidth, beauty.cropHeight, &ignored)) {
            SetErr(outFailureReason, kErrInvalidParameters);
            return false;
        }
    }

    if (!impl_->ensureSharedResources(device, vertexModule, fragmentModule, outFailureReason)) {
        return false;
    }
    Impl::GeometryResources* geom = impl_->findOrCreateGeometry(
        device, physicalDevice, beauty.cropWidth, beauty.cropHeight, frameCount, outFailureReason);
    if (geom == nullptr) {
        return false;
    }
    Impl::SlotResources& slot = geom->slots[frameSlotIndex];

    if (!impl_->ensureCropPipeline(device, frameSlotIndex, frameCount,
                                   srcImage.descriptorResources.pipelineLayout, outFailureReason)) {
        return false;
    }
    if (!impl_->ensurePlacementPipeline(device, frameSlotIndex, frameCount,
                                        finalRenderPass, outFailureReason)) {
        return false;
    }

    // ── Pass 1: crop — srcImage -> slot.orig (identity rotation, caller's crop scale/bias). ──
    if (srcCurrentLayout == VK_IMAGE_LAYOUT_UNDEFINED) {
        srcImage.recordLayoutTransition(
            commandBuffer,
            VK_IMAGE_LAYOUT_UNDEFINED,
            VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
            VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT,
            VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT,
            0,
            VK_ACCESS_SHADER_READ_BIT);
    }
    {
        VideoFrameTransform cropOnly{};
        cropOnly.rotationDegrees = 0;
        cropOnly.mirrorHorizontal = false;
        cropOnly.cropScaleU = placementTransform.cropScaleU;
        cropOnly.cropScaleV = placementTransform.cropScaleV;
        cropOnly.cropBiasU = placementTransform.cropBiasU;
        cropOnly.cropBiasV = placementTransform.cropBiasV;
        const VideoTransformFullPushConstants pc = makeVideoTransformFullPushConstants(cropOnly);

        VkClearValue clearValue{};
        clearValue.color = {{0.0f, 0.0f, 0.0f, 1.0f}};
        VkRenderPassBeginInfo rpBegin{};
        rpBegin.sType             = VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO;
        rpBegin.renderPass        = impl_->intermediateRenderPass;
        rpBegin.framebuffer       = slot.fboOrig;
        rpBegin.renderArea.offset = {0, 0};
        rpBegin.renderArea.extent = {beauty.cropWidth, beauty.cropHeight};
        rpBegin.clearValueCount   = 1;
        rpBegin.pClearValues      = &clearValue;
        vkCmdBeginRenderPass(commandBuffer, &rpBegin, VK_SUBPASS_CONTENTS_INLINE);

        VkViewport viewport{};
        viewport.width = static_cast<float>(beauty.cropWidth);
        viewport.height = static_cast<float>(beauty.cropHeight);
        viewport.minDepth = 0.0f;
        viewport.maxDepth = 1.0f;
        vkCmdSetViewport(commandBuffer, 0, 1, &viewport);
        VkRect2D scissor{};
        scissor.extent = {beauty.cropWidth, beauty.cropHeight};
        vkCmdSetScissor(commandBuffer, 0, 1, &scissor);

        vkCmdBindPipeline(commandBuffer, VK_PIPELINE_BIND_POINT_GRAPHICS,
                          impl_->cropPipelineSlots[frameSlotIndex].pipeline.get());
        vkCmdBindDescriptorSets(commandBuffer, VK_PIPELINE_BIND_POINT_GRAPHICS,
                                srcImage.descriptorResources.pipelineLayout, 0, 1,
                                &srcImage.descriptorResources.descriptorSet, 0, nullptr);
        // Crop pipeline layout uses ONE combined VERTEX|FRAGMENT push range at
        // offset 0 (matching VulkanDescriptorResources / the non-beauty solo
        // path), unlike the split vertex/fragment ranges used by the
        // blur/composite passes below.
        vkCmdPushConstants(commandBuffer, srcImage.descriptorResources.pipelineLayout,
                           VK_SHADER_STAGE_VERTEX_BIT | VK_SHADER_STAGE_FRAGMENT_BIT,
                           0, sizeof(pc), &pc);
        vkCmdDraw(commandBuffer, 3, 1, 0, 0);
        vkCmdEndRenderPass(commandBuffer);
    }

    // ── Pass 2: blur H — slot.orig -> slot.blurH. ──
    {
        const VertexUvPushConstants identityUv = IdentityUvPushConstants();
        BlurPushConstants pc{};
        pc.width = static_cast<int32_t>(beauty.cropWidth);
        pc.height = static_cast<int32_t>(beauty.cropHeight);
        pc.radius = params.radius;
        pc.axis = 0;
        pc.sigma = params.sigma;
        pc.rangeSigma = params.rangeSigma;
        RecordFullExtentPass(commandBuffer, impl_->intermediateRenderPass, slot.fboBlurH,
                             beauty.cropWidth, beauty.cropHeight, impl_->blurPipeline.get(),
                             impl_->blurPipelineLayout, slot.blurSetH,
                             &identityUv, sizeof(identityUv),
                             &pc, static_cast<uint32_t>(sizeof(VertexUvPushConstants)), sizeof(pc));
    }

    // ── Pass 3: blur V — slot.blurH -> slot.mean. ──
    {
        const VertexUvPushConstants identityUv = IdentityUvPushConstants();
        BlurPushConstants pc{};
        pc.width = static_cast<int32_t>(beauty.cropWidth);
        pc.height = static_cast<int32_t>(beauty.cropHeight);
        pc.radius = params.radius;
        pc.axis = 1;
        pc.sigma = params.sigma;
        pc.rangeSigma = params.rangeSigma;
        RecordFullExtentPass(commandBuffer, impl_->intermediateRenderPass, slot.fboMean,
                             beauty.cropWidth, beauty.cropHeight, impl_->blurPipeline.get(),
                             impl_->blurPipelineLayout, slot.blurSetV,
                             &identityUv, sizeof(identityUv),
                             &pc, static_cast<uint32_t>(sizeof(VertexUvPushConstants)), sizeof(pc));
    }

    // ── Pass 4: composite — slot.orig + slot.mean -> slot.beautified. ──
    {
        const VertexUvPushConstants identityUv = IdentityUvPushConstants();
        CompositePushConstants pc{};
        pc.width = static_cast<int32_t>(beauty.cropWidth);
        pc.height = static_cast<int32_t>(beauty.cropHeight);
        pc.smoothStrength = params.smoothStrength;
        pc.sharpenStrength = params.sharpenStrength;
        pc.theta = params.theta;
        pc.detailDamping = params.detailDamping;
        pc.toneStrength = params.toneStrength;
        pc.midtoneLift = params.midtoneLift;
        RecordFullExtentPass(commandBuffer, impl_->intermediateRenderPass, slot.fboBeautified,
                             beauty.cropWidth, beauty.cropHeight, impl_->compositePipeline.get(),
                             impl_->compositePipelineLayout, slot.compositeSet,
                             &identityUv, sizeof(identityUv),
                             &pc, static_cast<uint32_t>(sizeof(VertexUvPushConstants)), sizeof(pc));
    }

    // ── Pass 5: placement — slot.beautified -> caller's swapchain framebuffer. ──
    {
        VideoFrameTransform placementOnly = placementTransform;
        placementOnly.cropScaleU = 1.0f;
        placementOnly.cropScaleV = 1.0f;
        placementOnly.cropBiasU = 0.0f;
        placementOnly.cropBiasV = 0.0f;
        const VideoTransformFullPushConstants pc = makeVideoTransformFullPushConstants(placementOnly);

        const bool hasDestinationRect = !placementTransform.destinationRect.isDefault();
        const int32_t destX = hasDestinationRect ? placementTransform.destinationRect.x : 0;
        const int32_t destY = hasDestinationRect ? placementTransform.destinationRect.y : 0;
        const uint32_t destWidth = hasDestinationRect
            ? static_cast<uint32_t>(placementTransform.destinationRect.width)
            : finalExtentWidth;
        const uint32_t destHeight = hasDestinationRect
            ? static_cast<uint32_t>(placementTransform.destinationRect.height)
            : finalExtentHeight;
        if (destWidth == 0 || destHeight == 0 ||
            static_cast<uint64_t>(destX) + destWidth > finalExtentWidth ||
            static_cast<uint64_t>(destY) + destHeight > finalExtentHeight) {
            SetErr(outFailureReason, kErrInvalidDimensions);
            return false;
        }

        VkClearValue clearValue{};
        clearValue.color = {{0.0f, 0.0f, 0.0f, 1.0f}};
        VkRenderPassBeginInfo rpBegin{};
        rpBegin.sType             = VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO;
        rpBegin.renderPass        = finalRenderPass;
        rpBegin.framebuffer       = finalFramebuffer;
        rpBegin.renderArea.offset = {0, 0};
        rpBegin.renderArea.extent = {finalExtentWidth, finalExtentHeight};
        rpBegin.clearValueCount   = 1;
        rpBegin.pClearValues      = &clearValue;
        vkCmdBeginRenderPass(commandBuffer, &rpBegin, VK_SUBPASS_CONTENTS_INLINE);

        VkViewport viewport{};
        viewport.x = static_cast<float>(destX);
        viewport.y = static_cast<float>(destY);
        viewport.width = static_cast<float>(destWidth);
        viewport.height = static_cast<float>(destHeight);
        viewport.minDepth = 0.0f;
        viewport.maxDepth = 1.0f;
        vkCmdSetViewport(commandBuffer, 0, 1, &viewport);
        VkRect2D scissor{};
        scissor.offset = {destX, destY};
        scissor.extent = {destWidth, destHeight};
        vkCmdSetScissor(commandBuffer, 0, 1, &scissor);

        vkCmdBindPipeline(commandBuffer, VK_PIPELINE_BIND_POINT_GRAPHICS,
                          impl_->placementPipelineSlots[frameSlotIndex].pipeline.get());
        vkCmdBindDescriptorSets(commandBuffer, VK_PIPELINE_BIND_POINT_GRAPHICS, impl_->placementPipelineLayout,
                                0, 1, &slot.placementSet, 0, nullptr);
        vkCmdPushConstants(commandBuffer, impl_->placementPipelineLayout,
                           VK_SHADER_STAGE_VERTEX_BIT | VK_SHADER_STAGE_FRAGMENT_BIT,
                           0, sizeof(pc), &pc);
        vkCmdDraw(commandBuffer, 3, 1, 0, 0);
        vkCmdEndRenderPass(commandBuffer);
    }

    return true;
}

void VulkanBeautyFrameRenderer::shutdown(VkDevice device) {
    if (impl_) {
        impl_->shutdownAll(device);
    }
}

uint64_t VulkanBeautyFrameRenderer::resourcesCreated() const {
    return impl_ ? impl_->created : 0;
}

uint64_t VulkanBeautyFrameRenderer::resourcesReleased() const {
    return impl_ ? impl_->released : 0;
}

} // namespace render
} // namespace vanguard

#else // !defined(__ANDROID__) - host build

namespace vanguard {
namespace render {

struct VulkanBeautyFrameRenderer::Impl {};

VulkanBeautyFrameRenderer::VulkanBeautyFrameRenderer() : impl_(std::make_unique<Impl>()) {}
VulkanBeautyFrameRenderer::~VulkanBeautyFrameRenderer() = default;

bool VulkanBeautyFrameRenderer::recordBeauty(
    void* /*device*/,
    void* /*physicalDevice*/,
    void* /*commandBuffer*/,
    uint32_t /*frameSlotIndex*/,
    uint32_t /*frameCount*/,
    const VulkanHardwareBufferImage& /*srcImage*/,
    uint32_t /*srcCurrentLayout*/,
    void* /*vertexModule*/,
    void* /*fragmentModule*/,
    const VideoFrameTransform& /*placementTransform*/,
    const VideoBeautyV2RenderParams& /*beauty*/,
    void* /*finalRenderPass*/,
    void* /*finalFramebuffer*/,
    uint32_t /*finalExtentWidth*/,
    uint32_t /*finalExtentHeight*/,
    std::string* outFailureReason) {
    if (outFailureReason) *outFailureReason = "beauty_v2_unavailable_on_host";
    return false;
}

void VulkanBeautyFrameRenderer::shutdown(void* /*device*/) {
    // no-op on host
}

uint64_t VulkanBeautyFrameRenderer::resourcesCreated() const { return 0; }
uint64_t VulkanBeautyFrameRenderer::resourcesReleased() const { return 0; }

} // namespace render
} // namespace vanguard

#endif // __ANDROID__
