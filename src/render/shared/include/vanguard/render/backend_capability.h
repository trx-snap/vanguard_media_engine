#pragma once
#include "vanguard/render/render_backend.h"
#include <cstdint>
#include <string>

namespace vanguard {
namespace render {

struct BackendCapability {
    RenderBackendType selected;
    bool vulkanSupported;
    bool glesSupported;
    std::string fallbackReason;

    // Diagnostics populated by real probe (Phase 2A+). Empty strings on GLES fallback.
    std::string gpuVendor;
    std::string gpuRenderer;
    uint32_t    vulkanDriverVersion = 0;
};

BackendCapability ProbeBackendCapability();

} // namespace render
} // namespace vanguard
