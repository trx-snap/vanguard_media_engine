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

    // Diagnostics populated by real probe (Phase 2A+).
    // Early GLES fallback (before device enumeration): fields remain empty/zero.
    // Late GLES fallback (Phase 2Q+, after device enumeration): telemetry from
    // the best real GPU examined is preserved even when Vulkan is not selected.
    std::string gpuVendor;
    std::string gpuRenderer;

    // Phase 2Q: extended diagnostics.
    uint32_t vendorId            = 0;
    uint32_t deviceId            = 0;
    uint32_t apiVersion          = 0;
    uint32_t vulkanDriverVersion = 0;

    // Phase 2Q: safety gate classification.
    // profileGateStatus: "unverified" | "avp2022_partial_pass" | "failed_*"
    // blacklistStatus:   "not_evaluated" | "not_blacklisted" | "blacklisted_match"
    std::string profileGateStatus = "unverified";
    std::string blacklistStatus   = "not_evaluated";
};

BackendCapability ProbeBackendCapability();

} // namespace render
} // namespace vanguard
