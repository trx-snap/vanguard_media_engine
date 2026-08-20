#pragma once
#include "vanguard/render/render_backend.h"

namespace vanguard {
namespace render {

class GlesBackend : public RenderBackend {
public:
    GlesBackend() = default;
    ~GlesBackend() override = default;

    bool initialize() override;
    void shutdown() override;
    RenderBackendType type() const override;
};

} // namespace render
} // namespace vanguard
