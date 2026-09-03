// vulkan_beauty_v2_compositor.cpp
// P5-BEAUTY-V2-VULKAN-RENDER: VulkanBeautyV2Compositor implementation.
//
// Android-only real implementation is inside #if defined(__ANDROID__).
// Non-Android translation unit compiles to a safe stub that performs no
// Vulkan calls and reports unavailable, matching the other private Vulkan
// helper host stubs (e.g. VulkanOverlayCompositor). The pure validation and
// ramp math (ValidateVulkanBeautyV2Parameters /
// ComputeVulkanBeautyV2ParametersFromIntensity) compiles on every platform.
//
// Every DrawBeautyV2() call: validates the target/source/params (no Vulkan
// call until all pass), then creates two helper-owned
// VK_FORMAT_R8G8B8A8_UNORM intermediate images (+ views + one shared
// clamp-to-edge/NEAREST sampler), two shader modules per fragment stage
// (beauty_v2_blur, beauty_v2_composite; the vertex stage reuses the existing
// AOT passthrough module), descriptor set layouts/pool/sets, pipeline
// layouts, two render passes, three framebuffers, two pipelines, one command
// buffer from the caller's pool, and one fence; records Pass 1 (blur_h,
// caller source -> texA) -> Pass 2 (blur_v, texA -> texB) -> Pass 3
// (composite, caller source + texB -> caller target) plus the target image
// -> readback buffer copy and a host-read barrier; submits once; waits on
// the fence; and releases every temporary object before returning on every
// path.

#include "vulkan_beauty_v2_compositor.h"

#include <algorithm>
#include <cmath>
#include <cstring>
#include <vector>

#if defined(__ANDROID__)
#include <android/log.h>

#include "shaders/beauty_v2_blur_frag_spv.h"
#include "shaders/beauty_v2_composite_frag_spv.h"
#include "shaders/passthrough_vert_spv.h"
#include "vulkan_shader_module.h"

#define VGLOG_BV2(...) \
    __android_log_print(ANDROID_LOG_DEBUG, "VanguardVkBeautyV2", __VA_ARGS__)
#endif

namespace {

constexpr const char* kErrInvalidDimensions = "vulkan_beauty_v2_invalid_dimensions";
constexpr const char* kErrInvalidImage      = "vulkan_beauty_v2_invalid_image";
constexpr const char* kErrInvalidIntensity  = "vulkan_beauty_v2_invalid_intensity";
constexpr const char* kErrInvalidParameters = "vulkan_beauty_v2_invalid_parameters";
[[maybe_unused]] constexpr const char* kErrUnavailableOnHost = "vulkan_beauty_v2_unavailable_on_host";
[[maybe_unused]] constexpr const char* kErrImageFailed        = "vulkan_beauty_v2_image_failed";
[[maybe_unused]] constexpr const char* kErrShaderModule       = "vulkan_beauty_v2_shader_module_failed";
[[maybe_unused]] constexpr const char* kErrDescriptor         = "vulkan_beauty_v2_descriptor_failed";
[[maybe_unused]] constexpr const char* kErrRenderPass         = "vulkan_beauty_v2_render_pass_failed";
[[maybe_unused]] constexpr const char* kErrPipeline           = "vulkan_beauty_v2_pipeline_failed";
[[maybe_unused]] constexpr const char* kErrCommandBuffer      = "vulkan_beauty_v2_command_buffer_failed";
[[maybe_unused]] constexpr const char* kErrSubmit             = "vulkan_beauty_v2_submit_failed";
[[maybe_unused]] constexpr const char* kErrWait               = "vulkan_beauty_v2_wait_failed";

void SetError(std::string* outError, const char* reason) {
    if (outError) *outError = reason;
}

bool ParamsFinite(const vanguard::render::VulkanBeautyV2Parameters& p) {
    return std::isfinite(p.sigma) && std::isfinite(p.rangeSigma) &&
           std::isfinite(p.smoothStrength) && std::isfinite(p.sharpenStrength) &&
           std::isfinite(p.theta) && std::isfinite(p.detailDamping) &&
           std::isfinite(p.toneStrength) && std::isfinite(p.midtoneLift);
}

bool ParamsInRange(const vanguard::render::VulkanBeautyV2Parameters& p) {
    return p.radius >= 1 && p.sigma >= 1.0f && p.rangeSigma >= 0.01f &&
           p.theta >= 0.001f && p.smoothStrength >= 0.0f && p.sharpenStrength >= 0.0f &&
           p.detailDamping >= 0.0f && p.toneStrength >= 0.0f && p.midtoneLift >= 0.0f;
}

} // namespace

namespace vanguard {
namespace render {

VulkanBeautyV2Compositor::VulkanBeautyV2Compositor() = default;
VulkanBeautyV2Compositor::~VulkanBeautyV2Compositor() = default;

// ── Pure validation + ramp math (all platforms) ─────────────────────────────
// Mirrors ValidateBeautyV2Parameters / ComputeBeautyV2ParametersFromIntensity
// in gles_beauty_v2_compositor.cpp line-for-line (same formulas, same
// evaluation order); only the error-string prefix differs.

bool ValidateVulkanBeautyV2Parameters(const VulkanBeautyV2Parameters& params,
                                      uint32_t width,
                                      uint32_t height,
                                      std::string* outError) {
    if (outError == nullptr) {
        return false;
    }
    if (width == 0 || height == 0) {
        SetError(outError, kErrInvalidDimensions);
        return false;
    }
    if (!ParamsFinite(params) || !ParamsInRange(params)) {
        SetError(outError, kErrInvalidParameters);
        return false;
    }
    outError->clear();
    return true;
}

bool ComputeVulkanBeautyV2ParametersFromIntensity(float intensity,
                                                   uint32_t width,
                                                   uint32_t height,
                                                   VulkanBeautyV2Parameters* outParams,
                                                   std::string* outError) {
    if (outError == nullptr || outParams == nullptr) {
        return false;
    }
    if (width == 0 || height == 0) {
        SetError(outError, kErrInvalidDimensions);
        return false;
    }
    if (!std::isfinite(intensity) || intensity < 0.0f || intensity > 1.0f) {
        SetError(outError, kErrInvalidIntensity);
        return false;
    }

    const float t = intensity;
    const float scale = std::fmax(
        1.0f, static_cast<float>(std::min(width, height)) / 1080.0f);

    const float baseRadius = 1.0f + t * 11.0f;
    int32_t radius = static_cast<int32_t>(std::lround(baseRadius * scale));
    radius = std::max(1, std::min(radius, 64));

    float sigma = std::fmax((1.0f + t * 7.5f) * scale, 1.0f);
    float smoothStrength = std::min(std::max(t * 1.40f, 0.0f), 1.40f);
    float theta = std::fmax(0.02f + t * 0.03f, 0.001f);
    float sharpenStrength = std::min(std::max(0.35f - t * 0.20f, 0.0f), 0.50f);
    float rangeSigma = std::fmax(0.20f - t * 0.12f, 0.01f);
    float detailDamping = std::min(std::max(1.0f - t * 0.50f, 0.0f), 1.0f);
    float toneStrength = std::min(std::max(t * 0.30f, 0.0f), 1.0f);
    float midtoneLift = std::min(std::max(t * 0.06f, 0.0f), 0.15f);

    outParams->radius = radius;
    outParams->sigma = sigma;
    outParams->rangeSigma = rangeSigma;
    outParams->smoothStrength = smoothStrength;
    outParams->sharpenStrength = sharpenStrength;
    outParams->theta = theta;
    outParams->detailDamping = detailDamping;
    outParams->toneStrength = toneStrength;
    outParams->midtoneLift = midtoneLift;

    outError->clear();
    return true;
}

#if defined(__ANDROID__)
namespace {

constexpr uint64_t kFenceTimeoutNs = 5000000000ull; // 5 s
constexpr VkFormat kBeautyFormat = VK_FORMAT_R8G8B8A8_UNORM;

// Push-constant layouts. VertexUvPushConstants models only the first two
// vec4 rows (bytes [0,32)) of the existing AOT passthrough vertex module's
// declared 112-byte block (VideoTransformFullPushConstants); this helper
// only ever needs identity values there since its fragment shaders address
// texels via gl_FragCoord, never the vertex UV varying. The pipeline layout's
// VK_SHADER_STAGE_VERTEX_BIT range must still span the whole 112-byte block
// the vertex shader module declares (see kVideoTransformFullPushConstantSize
// below), even though only bytes [0,32) are ever written. Each fragment
// range starts at byte offset 32, matching the `layout(offset = 32) ...`
// qualifier in the .frag sources, and is unaffected by the vertex range size.
struct alignas(16) VertexUvPushConstants {
    float uvTransform0[4];
    float uvTransform1[4];
};
static_assert(sizeof(VertexUvPushConstants) == 32, "VertexUvPushConstants must be 32 bytes");

// The reused passthrough_vert_spv.h vertex module declares the full 112-byte
// VideoTransformFullPushConstants block (see
// vanguard/render/render_transform.h). Vulkan requires the pipeline layout's
// vertex-stage push-constant range to cover a shader module's entire
// declared push-constant block, not just the bytes this helper populates.
constexpr uint32_t kVideoTransformFullPushConstantSize = 112u;
static_assert(kVideoTransformFullPushConstantSize >= sizeof(VertexUvPushConstants),
              "kVideoTransformFullPushConstantSize must cover VertexUvPushConstants");

struct alignas(16) BlurPushConstants {
    int32_t width;
    int32_t height;
    int32_t radius;
    int32_t axis; // 0 = horizontal (Pass 1), 1 = vertical (Pass 2)
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

// One helper-owned intermediate image (Pass 1 or Pass 2 target), destroyed
// by Temporaries::Release().
struct IntermediateImage {
    VkImage        image  = VK_NULL_HANDLE;
    VkDeviceMemory memory = VK_NULL_HANDLE;
    VkImageView    view   = VK_NULL_HANDLE;
};

// Every temporary Vulkan object one DrawBeautyV2() call creates. Release()
// destroys/frees each non-null handle in reverse dependency order and counts
// releases so the owner can prove created == released. Descriptor sets are
// freed implicitly with their pool (the pool is the counted object).
struct Temporaries {
    VkDevice                     device         = VK_NULL_HANDLE;
    VkCommandPool                commandPool    = VK_NULL_HANDLE;

    IntermediateImage             texA;
    IntermediateImage             texB;
    VkSampler                     intermediateSampler = VK_NULL_HANDLE;

    VulkanShaderModule            vertex;
    VulkanShaderModule            blurFragment;
    VulkanShaderModule            compositeFragment;

    VkDescriptorSetLayout         blurSetLayout      = VK_NULL_HANDLE;
    VkDescriptorSetLayout         compositeSetLayout = VK_NULL_HANDLE;
    VkDescriptorPool              descriptorPool     = VK_NULL_HANDLE;
    VkDescriptorSet                blurSetH      = VK_NULL_HANDLE;
    VkDescriptorSet                blurSetV      = VK_NULL_HANDLE;
    VkDescriptorSet                compositeSet  = VK_NULL_HANDLE;

    VkPipelineLayout               blurPipelineLayout      = VK_NULL_HANDLE;
    VkPipelineLayout               compositePipelineLayout = VK_NULL_HANDLE;

    VkRenderPass                   intermediateRenderPass = VK_NULL_HANDLE;
    VkRenderPass                   targetRenderPass       = VK_NULL_HANDLE;
    VkFramebuffer                  fboA      = VK_NULL_HANDLE;
    VkFramebuffer                  fboB      = VK_NULL_HANDLE;
    VkFramebuffer                  fboTarget = VK_NULL_HANDLE;

    VkPipeline                     blurPipeline      = VK_NULL_HANDLE;
    VkPipeline                     compositePipeline = VK_NULL_HANDLE;

    VkCommandBuffer                commandBuffer = VK_NULL_HANDLE;
    VkFence                        fence         = VK_NULL_HANDLE;

    uint64_t created  = 0;
    uint64_t released = 0;

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
        if (compositePipeline != VK_NULL_HANDLE) {
            vkDestroyPipeline(device, compositePipeline, nullptr);
            compositePipeline = VK_NULL_HANDLE;
            ++released;
        }
        if (blurPipeline != VK_NULL_HANDLE) {
            vkDestroyPipeline(device, blurPipeline, nullptr);
            blurPipeline = VK_NULL_HANDLE;
            ++released;
        }
        if (fboTarget != VK_NULL_HANDLE) {
            vkDestroyFramebuffer(device, fboTarget, nullptr);
            fboTarget = VK_NULL_HANDLE;
            ++released;
        }
        if (fboB != VK_NULL_HANDLE) {
            vkDestroyFramebuffer(device, fboB, nullptr);
            fboB = VK_NULL_HANDLE;
            ++released;
        }
        if (fboA != VK_NULL_HANDLE) {
            vkDestroyFramebuffer(device, fboA, nullptr);
            fboA = VK_NULL_HANDLE;
            ++released;
        }
        if (targetRenderPass != VK_NULL_HANDLE) {
            vkDestroyRenderPass(device, targetRenderPass, nullptr);
            targetRenderPass = VK_NULL_HANDLE;
            ++released;
        }
        if (intermediateRenderPass != VK_NULL_HANDLE) {
            vkDestroyRenderPass(device, intermediateRenderPass, nullptr);
            intermediateRenderPass = VK_NULL_HANDLE;
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
        if (descriptorPool != VK_NULL_HANDLE) {
            vkDestroyDescriptorPool(device, descriptorPool, nullptr);
            descriptorPool = VK_NULL_HANDLE;
            blurSetH = blurSetV = compositeSet = VK_NULL_HANDLE;
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
        if (vertex.get() != VK_NULL_HANDLE) {
            vertex.destroy(device);
            ++released;
        }
        if (intermediateSampler != VK_NULL_HANDLE) {
            vkDestroySampler(device, intermediateSampler, nullptr);
            intermediateSampler = VK_NULL_HANDLE;
            ++released;
        }
        if (texB.view != VK_NULL_HANDLE) { vkDestroyImageView(device, texB.view, nullptr); texB.view = VK_NULL_HANDLE; ++released; }
        if (texB.image != VK_NULL_HANDLE) { vkDestroyImage(device, texB.image, nullptr); texB.image = VK_NULL_HANDLE; ++released; }
        if (texB.memory != VK_NULL_HANDLE) { vkFreeMemory(device, texB.memory, nullptr); texB.memory = VK_NULL_HANDLE; ++released; }
        if (texA.view != VK_NULL_HANDLE) { vkDestroyImageView(device, texA.view, nullptr); texA.view = VK_NULL_HANDLE; ++released; }
        if (texA.image != VK_NULL_HANDLE) { vkDestroyImage(device, texA.image, nullptr); texA.image = VK_NULL_HANDLE; ++released; }
        if (texA.memory != VK_NULL_HANDLE) { vkFreeMemory(device, texA.memory, nullptr); texA.memory = VK_NULL_HANDLE; ++released; }
    }
};

// Counts each sub-object (image, memory, view) in `t.created` immediately
// upon successful creation -- not just once the whole image is complete --
// so a mid-function failure (e.g. image + memory succeed but the view fails)
// still leaves t.created exactly matching the real objects Release() will
// destroy.
bool CreateIntermediateImage(Temporaries& t,
                             const VulkanBeautyV2RenderTarget& target,
                             uint32_t width,
                             uint32_t height,
                             IntermediateImage& out,
                             std::string* outError) {
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
    if (vkCreateImage(target.device, &imgCI, nullptr, &out.image) != VK_SUCCESS) {
        out.image = VK_NULL_HANDLE;
        SetError(outError, kErrImageFailed);
        return false;
    }
    ++t.created;
    VkMemoryRequirements req{};
    vkGetImageMemoryRequirements(target.device, out.image, &req);
    VkPhysicalDeviceMemoryProperties memProps{};
    vkGetPhysicalDeviceMemoryProperties(target.physicalDevice, &memProps);
    uint32_t typeIndex = FindMemoryType(memProps, req.memoryTypeBits, VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT);
    if (typeIndex == UINT32_MAX) typeIndex = FindMemoryType(memProps, req.memoryTypeBits, 0);
    if (typeIndex == UINT32_MAX) {
        SetError(outError, kErrImageFailed);
        return false;
    }
    VkMemoryAllocateInfo alloc{};
    alloc.sType           = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
    alloc.allocationSize  = req.size;
    alloc.memoryTypeIndex = typeIndex;
    if (vkAllocateMemory(target.device, &alloc, nullptr, &out.memory) != VK_SUCCESS) {
        out.memory = VK_NULL_HANDLE;
        SetError(outError, kErrImageFailed);
        return false;
    }
    ++t.created;
    if (vkBindImageMemory(target.device, out.image, out.memory, 0) != VK_SUCCESS) {
        SetError(outError, kErrImageFailed);
        return false;
    }
    VkImageViewCreateInfo viewCI{};
    viewCI.sType                       = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO;
    viewCI.image                       = out.image;
    viewCI.viewType                    = VK_IMAGE_VIEW_TYPE_2D;
    viewCI.format                      = kBeautyFormat;
    viewCI.subresourceRange.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
    viewCI.subresourceRange.levelCount = 1;
    viewCI.subresourceRange.layerCount = 1;
    if (vkCreateImageView(target.device, &viewCI, nullptr, &out.view) != VK_SUCCESS) {
        out.view = VK_NULL_HANDLE;
        SetError(outError, kErrImageFailed);
        return false;
    }
    ++t.created;
    return true;
}

bool CreateIntermediateObjects(Temporaries& t,
                               const VulkanBeautyV2RenderTarget& target,
                               std::string* outError) {
    if (!CreateIntermediateImage(t, target, target.extentWidth, target.extentHeight, t.texA, outError)) {
        return false;
    }
    if (!CreateIntermediateImage(t, target, target.extentWidth, target.extentHeight, t.texB, outError)) {
        return false;
    }

    // Frozen contract: clamp-to-edge samplers. NEAREST filtering matches the
    // GLES intermediates (GL_NEAREST/GL_CLAMP_TO_EDGE); both fragment shaders
    // address texels via texelFetch (already clamped in-shader), so filtering
    // never actually samples between texels.
    VkSamplerCreateInfo samplerCI{};
    samplerCI.sType         = VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO;
    samplerCI.magFilter     = VK_FILTER_NEAREST;
    samplerCI.minFilter     = VK_FILTER_NEAREST;
    samplerCI.mipmapMode    = VK_SAMPLER_MIPMAP_MODE_NEAREST;
    samplerCI.addressModeU  = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE;
    samplerCI.addressModeV  = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE;
    samplerCI.addressModeW  = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE;
    samplerCI.maxAnisotropy = 1.0f;
    if (vkCreateSampler(target.device, &samplerCI, nullptr, &t.intermediateSampler) != VK_SUCCESS) {
        t.intermediateSampler = VK_NULL_HANDLE;
        SetError(outError, kErrImageFailed);
        return false;
    }
    ++t.created;
    return true;
}

bool CreateShaderModules(Temporaries& t, std::string* outError) {
    if (!t.vertex.create(t.device, shaders::kPassthroughVertSpv, shaders::kPassthroughVertSpvSize,
                         "beauty_v2_passthrough_vert")) {
        SetError(outError, kErrShaderModule);
        return false;
    }
    ++t.created;
    if (!t.blurFragment.create(t.device, shaders::kBeautyV2BlurFragSpv, shaders::kBeautyV2BlurFragSpvSize,
                               "beauty_v2_blur_frag")) {
        SetError(outError, kErrShaderModule);
        return false;
    }
    ++t.created;
    if (!t.compositeFragment.create(t.device, shaders::kBeautyV2CompositeFragSpv,
                                    shaders::kBeautyV2CompositeFragSpvSize, "beauty_v2_composite_frag")) {
        SetError(outError, kErrShaderModule);
        return false;
    }
    ++t.created;
    return true;
}

// Descriptor set layouts (blur: 1 binding; composite: 2 bindings, both
// fragment-stage combined image samplers), one pool holding all three sets
// (blur-H, blur-V, composite), and the two pipeline layouts (vertex UV range
// [0,32) shared by both; fragment ranges start at byte offset 32, matching
// the .frag sources' `layout(offset = 32)` push-constant blocks).
bool CreateDescriptorObjects(Temporaries& t,
                             const VulkanBeautyV2SourceImage& source,
                             std::string* outError) {
    VkDescriptorSetLayoutBinding blurBinding{};
    blurBinding.binding            = 0;
    blurBinding.descriptorType     = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
    blurBinding.descriptorCount    = 1;
    blurBinding.stageFlags         = VK_SHADER_STAGE_FRAGMENT_BIT;

    VkDescriptorSetLayoutCreateInfo blurLayoutCI{};
    blurLayoutCI.sType        = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO;
    blurLayoutCI.bindingCount = 1;
    blurLayoutCI.pBindings    = &blurBinding;
    if (vkCreateDescriptorSetLayout(t.device, &blurLayoutCI, nullptr, &t.blurSetLayout) != VK_SUCCESS) {
        t.blurSetLayout = VK_NULL_HANDLE;
        SetError(outError, kErrDescriptor);
        return false;
    }
    ++t.created;

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
    if (vkCreateDescriptorSetLayout(t.device, &compositeLayoutCI, nullptr, &t.compositeSetLayout) != VK_SUCCESS) {
        t.compositeSetLayout = VK_NULL_HANDLE;
        SetError(outError, kErrDescriptor);
        return false;
    }
    ++t.created;

    VkDescriptorPoolSize poolSize{};
    poolSize.type            = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
    poolSize.descriptorCount = 4; // blurSetH(1) + blurSetV(1) + compositeSet(2)

    VkDescriptorPoolCreateInfo poolCI{};
    poolCI.sType         = VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO;
    poolCI.maxSets       = 3;
    poolCI.poolSizeCount = 1;
    poolCI.pPoolSizes    = &poolSize;
    if (vkCreateDescriptorPool(t.device, &poolCI, nullptr, &t.descriptorPool) != VK_SUCCESS) {
        t.descriptorPool = VK_NULL_HANDLE;
        SetError(outError, kErrDescriptor);
        return false;
    }
    ++t.created;

    const VkDescriptorSetLayout layouts[3] = {t.blurSetLayout, t.blurSetLayout, t.compositeSetLayout};
    VkDescriptorSet sets[3] = {VK_NULL_HANDLE, VK_NULL_HANDLE, VK_NULL_HANDLE};
    VkDescriptorSetAllocateInfo allocInfo{};
    allocInfo.sType              = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO;
    allocInfo.descriptorPool     = t.descriptorPool;
    allocInfo.descriptorSetCount = 3;
    allocInfo.pSetLayouts        = layouts;
    if (vkAllocateDescriptorSets(t.device, &allocInfo, sets) != VK_SUCCESS) {
        SetError(outError, kErrDescriptor);
        return false;
    }
    t.blurSetH = sets[0];
    t.blurSetV = sets[1];
    t.compositeSet = sets[2];

    VkDescriptorImageInfo sourceInfo{};
    sourceInfo.sampler     = source.sampler;
    sourceInfo.imageView   = source.imageView;
    sourceInfo.imageLayout = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;

    VkDescriptorImageInfo texAInfo{};
    texAInfo.sampler     = t.intermediateSampler;
    texAInfo.imageView   = t.texA.view;
    texAInfo.imageLayout = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;

    VkDescriptorImageInfo texBInfo{};
    texBInfo.sampler     = t.intermediateSampler;
    texBInfo.imageView   = t.texB.view;
    texBInfo.imageLayout = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;

    VkWriteDescriptorSet writes[4]{};
    writes[0].sType           = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
    writes[0].dstSet          = t.blurSetH;
    writes[0].dstBinding      = 0;
    writes[0].descriptorCount = 1;
    writes[0].descriptorType  = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
    writes[0].pImageInfo      = &sourceInfo;

    writes[1].sType           = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
    writes[1].dstSet          = t.blurSetV;
    writes[1].dstBinding      = 0;
    writes[1].descriptorCount = 1;
    writes[1].descriptorType  = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
    writes[1].pImageInfo      = &texAInfo;

    writes[2].sType           = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
    writes[2].dstSet          = t.compositeSet;
    writes[2].dstBinding      = 0;
    writes[2].descriptorCount = 1;
    writes[2].descriptorType  = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
    writes[2].pImageInfo      = &sourceInfo;

    writes[3].sType           = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
    writes[3].dstSet          = t.compositeSet;
    writes[3].dstBinding      = 1;
    writes[3].descriptorCount = 1;
    writes[3].descriptorType  = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
    writes[3].pImageInfo      = &texBInfo;

    vkUpdateDescriptorSets(t.device, 4, writes, 0, nullptr);

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
    blurPlCI.pSetLayouts            = &t.blurSetLayout;
    blurPlCI.pushConstantRangeCount = 2;
    blurPlCI.pPushConstantRanges    = blurRanges;
    if (vkCreatePipelineLayout(t.device, &blurPlCI, nullptr, &t.blurPipelineLayout) != VK_SUCCESS) {
        t.blurPipelineLayout = VK_NULL_HANDLE;
        SetError(outError, kErrDescriptor);
        return false;
    }
    ++t.created;

    VkPushConstantRange compositeFragRange{};
    compositeFragRange.stageFlags = VK_SHADER_STAGE_FRAGMENT_BIT;
    compositeFragRange.offset     = static_cast<uint32_t>(sizeof(VertexUvPushConstants));
    compositeFragRange.size       = static_cast<uint32_t>(sizeof(CompositePushConstants));

    const VkPushConstantRange compositeRanges[2] = {vertexRange, compositeFragRange};
    VkPipelineLayoutCreateInfo compositePlCI{};
    compositePlCI.sType                  = VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO;
    compositePlCI.setLayoutCount         = 1;
    compositePlCI.pSetLayouts            = &t.compositeSetLayout;
    compositePlCI.pushConstantRangeCount = 2;
    compositePlCI.pPushConstantRanges    = compositeRanges;
    if (vkCreatePipelineLayout(t.device, &compositePlCI, nullptr, &t.compositePipelineLayout) != VK_SUCCESS) {
        t.compositePipelineLayout = VK_NULL_HANDLE;
        SetError(outError, kErrDescriptor);
        return false;
    }
    ++t.created;
    return true;
}

// Single-attachment render pass helper shared by CreateRenderPassObjects.
bool CreateSingleAttachmentRenderPass(VkDevice device,
                                      VkFormat format,
                                      VkImageLayout finalLayout,
                                      VkRenderPass* outRenderPass,
                                      std::string* outError) {
    VkAttachmentDescription color{};
    color.format         = format;
    color.samples        = VK_SAMPLE_COUNT_1_BIT;
    color.loadOp         = VK_ATTACHMENT_LOAD_OP_DONT_CARE; // every pixel is unconditionally overwritten
    color.storeOp        = VK_ATTACHMENT_STORE_OP_STORE;
    color.stencilLoadOp  = VK_ATTACHMENT_LOAD_OP_DONT_CARE;
    color.stencilStoreOp = VK_ATTACHMENT_STORE_OP_DONT_CARE;
    color.initialLayout  = VK_IMAGE_LAYOUT_UNDEFINED;
    color.finalLayout    = finalLayout;

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
    deps[0].srcStageMask  = VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT | VK_PIPELINE_STAGE_TRANSFER_BIT;
    deps[0].dstStageMask  = VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT;
    deps[0].srcAccessMask = VK_ACCESS_SHADER_READ_BIT | VK_ACCESS_TRANSFER_READ_BIT;
    deps[0].dstAccessMask = VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT;
    deps[1].srcSubpass    = 0;
    deps[1].dstSubpass    = VK_SUBPASS_EXTERNAL;
    deps[1].srcStageMask  = VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT;
    deps[1].dstStageMask  = VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT | VK_PIPELINE_STAGE_TRANSFER_BIT;
    deps[1].srcAccessMask = VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT;
    deps[1].dstAccessMask = VK_ACCESS_SHADER_READ_BIT | VK_ACCESS_TRANSFER_READ_BIT;

    VkRenderPassCreateInfo rpCI{};
    rpCI.sType           = VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO;
    rpCI.attachmentCount = 1;
    rpCI.pAttachments    = &color;
    rpCI.subpassCount    = 1;
    rpCI.pSubpasses      = &subpass;
    rpCI.dependencyCount = 2;
    rpCI.pDependencies   = deps;
    if (vkCreateRenderPass(device, &rpCI, nullptr, outRenderPass) != VK_SUCCESS) {
        *outRenderPass = VK_NULL_HANDLE;
        SetError(outError, kErrRenderPass);
        return false;
    }
    return true;
}

bool CreateFramebuffer(VkDevice device, VkRenderPass renderPass, VkImageView view,
                       uint32_t width, uint32_t height, VkFramebuffer* outFbo,
                       std::string* outError) {
    VkFramebufferCreateInfo fbCI{};
    fbCI.sType           = VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO;
    fbCI.renderPass      = renderPass;
    fbCI.attachmentCount = 1;
    fbCI.pAttachments    = &view;
    fbCI.width           = width;
    fbCI.height          = height;
    fbCI.layers          = 1;
    if (vkCreateFramebuffer(device, &fbCI, nullptr, outFbo) != VK_SUCCESS) {
        *outFbo = VK_NULL_HANDLE;
        SetError(outError, kErrRenderPass);
        return false;
    }
    return true;
}

// Two render passes: `intermediateRenderPass` (used by fboA and fboB, final
// layout SHADER_READ_ONLY_OPTIMAL so the next pass can sample the result)
// and `targetRenderPass` (used by fboTarget, final layout
// TRANSFER_SRC_OPTIMAL so the result can be copied to the readback buffer).
bool CreateRenderPassObjects(Temporaries& t,
                             const VulkanBeautyV2RenderTarget& target,
                             std::string* outError) {
    if (!CreateSingleAttachmentRenderPass(t.device, kBeautyFormat,
                                          VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
                                          &t.intermediateRenderPass, outError)) {
        return false;
    }
    ++t.created;
    if (!CreateSingleAttachmentRenderPass(t.device, kBeautyFormat,
                                          VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
                                          &t.targetRenderPass, outError)) {
        return false;
    }
    ++t.created;

    if (!CreateFramebuffer(t.device, t.intermediateRenderPass, t.texA.view,
                           target.extentWidth, target.extentHeight, &t.fboA, outError)) {
        return false;
    }
    ++t.created;
    if (!CreateFramebuffer(t.device, t.intermediateRenderPass, t.texB.view,
                           target.extentWidth, target.extentHeight, &t.fboB, outError)) {
        return false;
    }
    ++t.created;
    if (!CreateFramebuffer(t.device, t.targetRenderPass, target.colorImageView,
                           target.extentWidth, target.extentHeight, &t.fboTarget, outError)) {
        return false;
    }
    ++t.created;
    return true;
}

// One fullscreen-triangle graphics pipeline (no vertex input, dynamic
// viewport/scissor, no blending -- every pass writes an opaque full-frame
// result) per fragment stage/render pass/pipeline layout combination.
bool CreateOnePipeline(VkDevice device,
                       VkShaderModule vertexModule,
                       VkShaderModule fragmentModule,
                       VkPipelineLayout layout,
                       VkRenderPass renderPass,
                       VkPipeline* outPipeline,
                       std::string* outError) {
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

    VkPipelineColorBlendAttachmentState attachment{};
    attachment.blendEnable    = VK_FALSE;
    attachment.colorWriteMask = VK_COLOR_COMPONENT_R_BIT | VK_COLOR_COMPONENT_G_BIT |
                                VK_COLOR_COMPONENT_B_BIT | VK_COLOR_COMPONENT_A_BIT;

    VkPipelineColorBlendStateCreateInfo colorBlend{};
    colorBlend.sType           = VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO;
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
    pipelineCI.layout              = layout;
    pipelineCI.renderPass          = renderPass;
    pipelineCI.subpass             = 0;
    pipelineCI.basePipelineIndex   = -1;

    if (vkCreateGraphicsPipelines(device, VK_NULL_HANDLE, 1, &pipelineCI, nullptr, outPipeline) != VK_SUCCESS) {
        *outPipeline = VK_NULL_HANDLE;
        SetError(outError, kErrPipeline);
        return false;
    }
    return true;
}

bool CreatePipelines(Temporaries& t, std::string* outError) {
    if (!CreateOnePipeline(t.device, t.vertex.get(), t.blurFragment.get(), t.blurPipelineLayout,
                           t.intermediateRenderPass, &t.blurPipeline, outError)) {
        return false;
    }
    ++t.created;
    if (!CreateOnePipeline(t.device, t.vertex.get(), t.compositeFragment.get(), t.compositePipelineLayout,
                           t.targetRenderPass, &t.compositePipeline, outError)) {
        return false;
    }
    ++t.created;
    return true;
}

// Records the whole command buffer: Pass 1 (blur_h) -> Pass 2 (blur_v) ->
// Pass 3 (composite) -> image-to-buffer copy -> host-read barrier.
bool RecordCommands(Temporaries& t,
                    const VulkanBeautyV2RenderTarget& target,
                    const VulkanBeautyV2Parameters& params,
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

    const VertexUvPushConstants identityUv = IdentityUvPushConstants();

    VkViewport viewport{};
    viewport.x        = 0.0f;
    viewport.y        = 0.0f;
    viewport.width    = static_cast<float>(target.extentWidth);
    viewport.height   = static_cast<float>(target.extentHeight);
    viewport.minDepth = 0.0f;
    viewport.maxDepth = 1.0f;
    VkRect2D scissor{};
    scissor.offset = {0, 0};
    scissor.extent = {target.extentWidth, target.extentHeight};

    auto beginPass = [&](VkRenderPass renderPass, VkFramebuffer fbo) {
        VkRenderPassBeginInfo rpBegin{};
        rpBegin.sType             = VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO;
        rpBegin.renderPass        = renderPass;
        rpBegin.framebuffer       = fbo;
        rpBegin.renderArea.offset = {0, 0};
        rpBegin.renderArea.extent = {target.extentWidth, target.extentHeight};
        vkCmdBeginRenderPass(t.commandBuffer, &rpBegin, VK_SUBPASS_CONTENTS_INLINE);
        vkCmdSetViewport(t.commandBuffer, 0, 1, &viewport);
        vkCmdSetScissor(t.commandBuffer, 0, 1, &scissor);
    };

    // ── Pass 1: blur_h — source -> fboA (texA). ─────────────────────────────
    beginPass(t.intermediateRenderPass, t.fboA);
    vkCmdBindPipeline(t.commandBuffer, VK_PIPELINE_BIND_POINT_GRAPHICS, t.blurPipeline);
    vkCmdBindDescriptorSets(t.commandBuffer, VK_PIPELINE_BIND_POINT_GRAPHICS, t.blurPipelineLayout,
                            0, 1, &t.blurSetH, 0, nullptr);
    vkCmdPushConstants(t.commandBuffer, t.blurPipelineLayout, VK_SHADER_STAGE_VERTEX_BIT,
                       0, sizeof(identityUv), &identityUv);
    {
        BlurPushConstants pc{};
        pc.width = static_cast<int32_t>(target.extentWidth);
        pc.height = static_cast<int32_t>(target.extentHeight);
        pc.radius = params.radius;
        pc.axis = 0;
        pc.sigma = params.sigma;
        pc.rangeSigma = params.rangeSigma;
        vkCmdPushConstants(t.commandBuffer, t.blurPipelineLayout, VK_SHADER_STAGE_FRAGMENT_BIT,
                           sizeof(VertexUvPushConstants), sizeof(pc), &pc);
    }
    vkCmdDraw(t.commandBuffer, 3, 1, 0, 0);
    vkCmdEndRenderPass(t.commandBuffer);

    // ── Pass 2: blur_v — texA -> fboB (texB). ───────────────────────────────
    beginPass(t.intermediateRenderPass, t.fboB);
    vkCmdBindPipeline(t.commandBuffer, VK_PIPELINE_BIND_POINT_GRAPHICS, t.blurPipeline);
    vkCmdBindDescriptorSets(t.commandBuffer, VK_PIPELINE_BIND_POINT_GRAPHICS, t.blurPipelineLayout,
                            0, 1, &t.blurSetV, 0, nullptr);
    vkCmdPushConstants(t.commandBuffer, t.blurPipelineLayout, VK_SHADER_STAGE_VERTEX_BIT,
                       0, sizeof(identityUv), &identityUv);
    {
        BlurPushConstants pc{};
        pc.width = static_cast<int32_t>(target.extentWidth);
        pc.height = static_cast<int32_t>(target.extentHeight);
        pc.radius = params.radius;
        pc.axis = 1;
        pc.sigma = params.sigma;
        pc.rangeSigma = params.rangeSigma;
        vkCmdPushConstants(t.commandBuffer, t.blurPipelineLayout, VK_SHADER_STAGE_FRAGMENT_BIT,
                           sizeof(VertexUvPushConstants), sizeof(pc), &pc);
    }
    vkCmdDraw(t.commandBuffer, 3, 1, 0, 0);
    vkCmdEndRenderPass(t.commandBuffer);

    // ── Pass 3: composite — source + texB -> fboTarget. ─────────────────────
    beginPass(t.targetRenderPass, t.fboTarget);
    vkCmdBindPipeline(t.commandBuffer, VK_PIPELINE_BIND_POINT_GRAPHICS, t.compositePipeline);
    vkCmdBindDescriptorSets(t.commandBuffer, VK_PIPELINE_BIND_POINT_GRAPHICS, t.compositePipelineLayout,
                            0, 1, &t.compositeSet, 0, nullptr);
    vkCmdPushConstants(t.commandBuffer, t.compositePipelineLayout, VK_SHADER_STAGE_VERTEX_BIT,
                       0, sizeof(identityUv), &identityUv);
    {
        CompositePushConstants pc{};
        pc.width = static_cast<int32_t>(target.extentWidth);
        pc.height = static_cast<int32_t>(target.extentHeight);
        pc.smoothStrength = params.smoothStrength;
        pc.sharpenStrength = params.sharpenStrength;
        pc.theta = params.theta;
        pc.detailDamping = params.detailDamping;
        pc.toneStrength = params.toneStrength;
        pc.midtoneLift = params.midtoneLift;
        vkCmdPushConstants(t.commandBuffer, t.compositePipelineLayout, VK_SHADER_STAGE_FRAGMENT_BIT,
                           sizeof(VertexUvPushConstants), sizeof(pc), &pc);
    }
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

// Submits once with a fresh fence and waits. On a wait timeout/failure the
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
        VGLOG_BV2("vkWaitForFences returned %d; draining queue before release", static_cast<int>(waitResult));
        vkQueueWaitIdle(queue);
        SetError(outError, kErrWait);
        return false;
    }
    return true;
}

} // namespace
#endif // __ANDROID__

bool VulkanBeautyV2Compositor::DrawBeautyV2(const VulkanBeautyV2RenderTarget& target,
                                            const VulkanBeautyV2SourceImage& source,
                                            const VulkanBeautyV2Parameters& params,
                                            std::string* outError) {
    if (outError) {
        outError->clear();
    }

#if defined(__ANDROID__)
    // ── Fail-closed validation: no Vulkan call is issued until every check
    // passes. Bundles every target-handle/dimension/format/readback-size
    // check into one "invalid dimensions" bucket (matching
    // VulkanOverlayCompositor's precedent of one bucket for whole-target
    // argument validity), keeps the source image view/sampler pair as its
    // own "invalid image" bucket, and reuses ValidateVulkanBeautyV2Parameters
    // for the parameter bucket.
    const uint64_t requiredReadbackBytes =
        static_cast<uint64_t>(target.extentWidth) * static_cast<uint64_t>(target.extentHeight) * 4ull;
    if (target.physicalDevice == VK_NULL_HANDLE || target.device == VK_NULL_HANDLE ||
        target.queue == VK_NULL_HANDLE || target.commandPool == VK_NULL_HANDLE ||
        target.colorImage == VK_NULL_HANDLE || target.colorImageView == VK_NULL_HANDLE ||
        target.colorFormat != kBeautyFormat ||
        target.readbackBuffer == VK_NULL_HANDLE ||
        target.extentWidth == 0 || target.extentHeight == 0 ||
        static_cast<uint64_t>(target.readbackBufferSizeBytes) < requiredReadbackBytes) {
        SetError(outError, kErrInvalidDimensions);
        return false;
    }
    if (source.imageView == VK_NULL_HANDLE || source.sampler == VK_NULL_HANDLE) {
        SetError(outError, kErrInvalidImage);
        return false;
    }
    if (!ValidateVulkanBeautyV2Parameters(params, target.extentWidth, target.extentHeight, outError)) {
        return false; // outError already set to invalid_dimensions/invalid_parameters
    }

    // ── Vulkan work. Every temporary object is released on every path below.
    Temporaries t;
    t.device      = target.device;
    t.commandPool = target.commandPool;

    const bool ok = CreateIntermediateObjects(t, target, outError) &&
                    CreateShaderModules(t, outError) &&
                    CreateDescriptorObjects(t, source, outError) &&
                    CreateRenderPassObjects(t, target, outError) &&
                    CreatePipelines(t, outError) &&
                    RecordCommands(t, target, params, outError) &&
                    SubmitAndWait(t, target.queue, outError);

    t.Release();
    temporaryObjectsCreated_  += t.created;
    temporaryObjectsReleased_ += t.released;
    if (t.created != t.released) {
        VGLOG_BV2("temporary object count mismatch: created=%llu released=%llu",
                  static_cast<unsigned long long>(t.created),
                  static_cast<unsigned long long>(t.released));
    }
    return ok;
#else
    (void)target;
    (void)source;
    (void)params;
    SetError(outError, kErrUnavailableOnHost);
    return false;
#endif
}

} // namespace render
} // namespace vanguard
