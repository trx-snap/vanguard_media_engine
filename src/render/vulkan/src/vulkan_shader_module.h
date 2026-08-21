// Phase 2J: VulkanShaderModule - move-only RAII wrapper for VkShaderModule.
//
// Private implementation helper; never included from public headers.
//
// On Android (__ANDROID__) full Vulkan lifecycle is provided.
// On non-Android host builds only stub no-op declarations are compiled so the
// translation unit can be built without the Vulkan SDK installed.

#pragma once

#include <cstddef>
#include <cstdint>
#include <memory>

#if defined(__ANDROID__)
#include <vulkan/vulkan.h>
#include <android/log.h>
#define VGLOG_SM(...) __android_log_print(ANDROID_LOG_DEBUG, "VanguardShaderMod", __VA_ARGS__)
#endif

namespace vanguard {
namespace render {

// ---------------------------------------------------------------------------
// VulkanShaderModule
// Move-only RAII owner of a single VkShaderModule handle.
// ---------------------------------------------------------------------------

class VulkanShaderModule {
public:
    VulkanShaderModule() = default;

    // Non-copyable.
    VulkanShaderModule(const VulkanShaderModule&) = delete;
    VulkanShaderModule& operator=(const VulkanShaderModule&) = delete;

    // Move transfers handle and nulls the source.
    VulkanShaderModule(VulkanShaderModule&& other) noexcept;
    VulkanShaderModule& operator=(VulkanShaderModule&& other) noexcept;

    ~VulkanShaderModule() = default; // caller must invoke destroy() first

    // Create the VkShaderModule from an AOT-embedded SPIR-V blob.
    // Validates: device != VK_NULL_HANDLE, code != nullptr,
    //            codeSizeBytes > 0 and multiple of 4, magic word 0x07230203.
    // On failure logs and returns false. On success owns the handle.
    bool create(
#if defined(__ANDROID__)
        VkDevice device,
#else
        void* device,
#endif
        const uint32_t* code,
        size_t codeSizeBytes,
        const char* debugName);

    // Idempotent: destroys VkShaderModule and nulls the handle.
    void destroy(
#if defined(__ANDROID__)
        VkDevice device
#else
        void* device
#endif
    );

#if defined(__ANDROID__)
    VkShaderModule get() const { return module_; }
#endif

private:
#if defined(__ANDROID__)
    VkShaderModule module_ = VK_NULL_HANDLE;
#endif
};

// ---------------------------------------------------------------------------
// VulkanCoreShaderModules
// Owns the three production core shader modules for device lifetime.
// ---------------------------------------------------------------------------

struct VulkanCoreShaderModules {
    VulkanShaderModule vertex;
    VulkanShaderModule fragment;
    VulkanShaderModule compute;

    // Create all three modules. On partial failure destroys already-created
    // modules and returns false.
    bool initialize(
#if defined(__ANDROID__)
        VkDevice device
#else
        void* device
#endif
    );

    // Destroy all three modules. Idempotent.
    void shutdown(
#if defined(__ANDROID__)
        VkDevice device
#else
        void* device
#endif
    );
};

} // namespace render
} // namespace vanguard
