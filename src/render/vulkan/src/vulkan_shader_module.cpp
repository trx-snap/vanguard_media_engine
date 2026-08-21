// Phase 2J: VulkanShaderModule implementation.
//
// On Android: full Vulkan VkShaderModule lifecycle with AOT-embedded SPIR-V.
// On non-Android host builds: stub no-ops compile without Vulkan headers.

#include "vulkan_shader_module.h"

#if defined(__ANDROID__)

#include "shaders/passthrough_vert_spv.h"
#include "shaders/passthrough_frag_spv.h"
#include "shaders/sample_comp_spv.h"

#include <cstring>

namespace vanguard {
namespace render {

// ---------------------------------------------------------------------------
// VulkanShaderModule - move semantics
// ---------------------------------------------------------------------------

VulkanShaderModule::VulkanShaderModule(VulkanShaderModule&& other) noexcept
    : module_(other.module_) {
    other.module_ = VK_NULL_HANDLE;
}

VulkanShaderModule& VulkanShaderModule::operator=(VulkanShaderModule&& other) noexcept {
    if (this != &other) {
        // Note: caller must ensure destroy() was called before move-assigning
        // over a live module (see VulkanCoreShaderModules::shutdown).
        module_ = other.module_;
        other.module_ = VK_NULL_HANDLE;
    }
    return *this;
}

// ---------------------------------------------------------------------------
// VulkanShaderModule::create
// ---------------------------------------------------------------------------

bool VulkanShaderModule::create(VkDevice device,
                                const uint32_t* code,
                                size_t codeSizeBytes,
                                const char* debugName) {
    // Validation.
    if (device == VK_NULL_HANDLE) {
        VGLOG_SM("create(%s): device is VK_NULL_HANDLE", debugName ? debugName : "?");
        return false;
    }
    if (!code) {
        VGLOG_SM("create(%s): code is null", debugName ? debugName : "?");
        return false;
    }
    if (codeSizeBytes == 0) {
        VGLOG_SM("create(%s): codeSizeBytes is 0", debugName ? debugName : "?");
        return false;
    }
    if (codeSizeBytes % 4 != 0) {
        VGLOG_SM("create(%s): codeSizeBytes %zu not multiple of 4",
                 debugName ? debugName : "?", codeSizeBytes);
        return false;
    }
    if (code[0] != 0x07230203u) {
        VGLOG_SM("create(%s): bad SPIR-V magic 0x%08x",
                 debugName ? debugName : "?", code[0]);
        return false;
    }

    VkShaderModuleCreateInfo ci{};
    ci.sType    = VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO;
    ci.codeSize = codeSizeBytes;
    ci.pCode    = code;

    VkResult result = vkCreateShaderModule(device, &ci, nullptr, &module_);
    if (result != VK_SUCCESS) {
        VGLOG_SM("vkCreateShaderModule(%s) failed: %d",
                 debugName ? debugName : "?", static_cast<int>(result));
        module_ = VK_NULL_HANDLE;
        return false;
    }

    VGLOG_SM("VkShaderModule created: %s (%zu bytes)", debugName ? debugName : "?", codeSizeBytes);
    return true;
}

// ---------------------------------------------------------------------------
// VulkanShaderModule::destroy
// ---------------------------------------------------------------------------

void VulkanShaderModule::destroy(VkDevice device) {
    if (module_ != VK_NULL_HANDLE && device != VK_NULL_HANDLE) {
        vkDestroyShaderModule(device, module_, nullptr);
        module_ = VK_NULL_HANDLE;
    }
}

// ---------------------------------------------------------------------------
// VulkanCoreShaderModules::initialize
// ---------------------------------------------------------------------------

bool VulkanCoreShaderModules::initialize(VkDevice device) {
    using namespace vanguard::render::shaders;

    if (!vertex.create(device,
                       kPassthroughVertSpv,
                       kPassthroughVertSpvSize,
                       "passthrough_vert")) {
        VGLOG_SM("VulkanCoreShaderModules: failed to create vertex module");
        return false;
    }

    if (!fragment.create(device,
                         kPassthroughFragSpv,
                         kPassthroughFragSpvSize,
                         "passthrough_frag")) {
        VGLOG_SM("VulkanCoreShaderModules: failed to create fragment module; destroying vertex");
        vertex.destroy(device);
        return false;
    }

    if (!compute.create(device,
                        kSampleCompSpv,
                        kSampleCompSpvSize,
                        "sample_comp")) {
        VGLOG_SM("VulkanCoreShaderModules: failed to create compute module; destroying prior modules");
        fragment.destroy(device);
        vertex.destroy(device);
        return false;
    }

    VGLOG_SM("VulkanCoreShaderModules: all three shader modules created successfully");
    return true;
}

// ---------------------------------------------------------------------------
// VulkanCoreShaderModules::shutdown
// ---------------------------------------------------------------------------

void VulkanCoreShaderModules::shutdown(VkDevice device) {
    compute.destroy(device);
    fragment.destroy(device);
    vertex.destroy(device);
    VGLOG_SM("VulkanCoreShaderModules: shut down");
}

} // namespace render
} // namespace vanguard

#else // !__ANDROID__

// ---------------------------------------------------------------------------
// Non-Android host stubs - compile cleanly without Vulkan headers.
// ---------------------------------------------------------------------------

namespace vanguard {
namespace render {

VulkanShaderModule::VulkanShaderModule(VulkanShaderModule&& /*other*/) noexcept {}
VulkanShaderModule& VulkanShaderModule::operator=(VulkanShaderModule&& /*other*/) noexcept {
    return *this;
}

bool VulkanShaderModule::create(void* /*device*/,
                                const uint32_t* /*code*/,
                                size_t /*codeSizeBytes*/,
                                const char* /*debugName*/) {
    return false;
}

void VulkanShaderModule::destroy(void* /*device*/) {}

bool VulkanCoreShaderModules::initialize(void* /*device*/) {
    return false;
}

void VulkanCoreShaderModules::shutdown(void* /*device*/) {}

} // namespace render
} // namespace vanguard

#endif // __ANDROID__
