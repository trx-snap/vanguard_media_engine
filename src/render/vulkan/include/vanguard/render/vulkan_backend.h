#pragma once
// Phase 2B1: VulkanBackend - PImpl isolation.
// This header must NOT include Vulkan or Android headers.
// All Vulkan types live exclusively in vulkan_backend.cpp.

#include "vanguard/render/render_backend.h"

#include <memory>

namespace vanguard {
namespace render {

class VulkanBackend : public RenderBackend {
public:
    VulkanBackend();
    ~VulkanBackend() override;

    // Non-copyable, non-movable (owns Vulkan state).
    VulkanBackend(const VulkanBackend&) = delete;
    VulkanBackend& operator=(const VulkanBackend&) = delete;

    bool initialize() override;
    void shutdown() override;
    RenderBackendType type() const override;

private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};

} // namespace render
} // namespace vanguard
