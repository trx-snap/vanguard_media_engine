#pragma once
#include "vanguard/render/render_backend.h"
#include <string>

namespace vanguard {
namespace render {

struct BackendCapability {
    RenderBackendType selected;
    bool vulkanSupported;
    bool glesSupported;
    std::string fallbackReason;
};

BackendCapability ProbeBackendCapability();

} // namespace render
} // namespace vanguard
