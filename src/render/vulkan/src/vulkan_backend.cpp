#include "vanguard/render/vulkan_backend.h"

namespace vanguard {
namespace render {

bool VulkanBackend::initialize() {
    return true; // Scaffold
}

void VulkanBackend::shutdown() {
    // Scaffold
}

RenderBackendType VulkanBackend::type() const {
    return RenderBackendType::kVulkan;
}

} // namespace render
} // namespace vanguard
