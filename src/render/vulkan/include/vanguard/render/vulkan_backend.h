#pragma once
// Phase 2B2: VulkanBackend - public header.
// Phase 2C: Added AHardwareBuffer import methods.
// Phase 2O1: Added renderFrame seam.
// Must NOT include Vulkan or Android headers.
// All Vulkan types live exclusively in vulkan_backend.cpp.

#include "vanguard/render/render_backend.h"

#include <cstdint>
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

    // Surface / swapchain lifecycle (delegates to VulkanSurfaceSwapchain).
    bool attachSurface(void* nativeWindow,
                       uint32_t width,
                       uint32_t height) override;
    bool resizeSurface(uint32_t width, uint32_t height) override;
    void detachSurface() override;
    bool hasSurface() const override;

    // Phase 2C: AHardwareBuffer import foundation.
    HardwareBufferImportResult importHardwareBuffer(
        void* hardwareBuffer,
        int acquireFenceFd,
        HardwareBufferHandle* outHandle,
        HardwareBufferDescriptor* outDescriptor) override;

    HardwareBufferImportResult releaseHardwareBuffer(
        HardwareBufferHandle handle,
        int* outReleaseFenceFd) override;

    bool hasHardwareBuffer(HardwareBufferHandle handle) const override;

    // Phase 2O1: Frame rendering seam stub.
    RenderFrameResult renderFrame(HardwareBufferHandle handle) override;

private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};

} // namespace render
} // namespace vanguard
