#pragma once
#include "vanguard/render/render_backend.h"
#include <cstdint>

namespace vanguard {
namespace render {

class GlesBackend : public RenderBackend {
public:
    GlesBackend() = default;
    ~GlesBackend() override = default;

    bool initialize() override;
    void shutdown() override;
    RenderBackendType type() const override;

    // Surface lifecycle stubs (GLES surface management deferred).
    bool attachSurface(void* nativeWindow,
                       uint32_t width,
                       uint32_t height) override;
    bool resizeSurface(uint32_t width, uint32_t height) override;
    void detachSurface() override;
    bool hasSurface() const override;

    // Phase 2C: AHardwareBuffer import - not supported on GLES backend.
    HardwareBufferImportResult importHardwareBuffer(
        void* hardwareBuffer,
        int acquireFenceFd,
        HardwareBufferHandle* outHandle,
        HardwareBufferDescriptor* outDescriptor) override;

    HardwareBufferImportResult releaseHardwareBuffer(
        HardwareBufferHandle handle,
        int* outReleaseFenceFd) override;

    bool hasHardwareBuffer(HardwareBufferHandle handle) const override;

    // Phase 2O1: Frame rendering seam stub - GLES backend does not support this.
    RenderFrameResult renderFrame(HardwareBufferHandle handle) override;
};

} // namespace render
} // namespace vanguard
