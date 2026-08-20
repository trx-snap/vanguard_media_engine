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
};

} // namespace render
} // namespace vanguard
