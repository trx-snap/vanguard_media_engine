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

    // P1-GLES-DECODED-ROUTE-CAPABILITY-REALIGNMENT: decoded-frame GLES route
    // capability reporting only. Does not change production rendering and
    // does not retry ImageReader.PRIVATE AHB import.
    //
    // decodedFramePreferredPath: the preferred path for decoded-frame
    // presentation given the selected backend, e.g. "vulkan_primary" when
    // Vulkan is selected. "unknown" when unverified.
    std::string decodedFramePreferredPath = "unknown";
    // glesDecodedSurfaceTextureOesSupported: whether the verified
    // MediaCodec -> SurfaceTexture -> GL_TEXTURE_EXTERNAL_OES -> native GLES
    // DAG render/present fallback route is supported on this platform.
    bool glesDecodedSurfaceTextureOesSupported = false;
    // glesPrivateAhbImportSupported: whether GLES ImageReader.PRIVATE
    // AHardwareBuffer import is supported. Remains false; this slice does not
    // retry that import path.
    bool glesPrivateAhbImportSupported = false;
    // glesPrivateAhbImportStatus: explicit stable token recording the known
    // AHB import boundary, e.g. "deferred_ahb_import_unsupported_format".
    std::string glesPrivateAhbImportStatus = "unverified";
    // glesDecodedFallbackPolicy: explicit stable token naming the decoded
    // GLES fallback policy, e.g.
    // "surface_texture_oes_without_private_ahb_import".
    std::string glesDecodedFallbackPolicy = "unverified";
};

BackendCapability ProbeBackendCapability();

} // namespace render
} // namespace vanguard
