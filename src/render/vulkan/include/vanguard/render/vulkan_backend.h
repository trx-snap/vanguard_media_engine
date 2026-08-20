#pragma once
#include "vanguard/render/render_backend.h"

namespace vanguard {
namespace render {

class VulkanBackend : public RenderBackend {
public:
    VulkanBackend() = default;
    ~VulkanBackend() override = default;

    bool initialize() override;
    void shutdown() override;
    RenderBackendType type() const override;
};

} // namespace render
} // namespace vanguard
