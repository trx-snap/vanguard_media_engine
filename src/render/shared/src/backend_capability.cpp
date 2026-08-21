#include "vanguard/render/backend_capability.h"

namespace vanguard {
namespace render {

// Default stub. Real probe in platform-specific code.
BackendCapability ProbeBackendCapability() {
    BackendCapability cap;
    cap.selected             = RenderBackendType::kUnavailable;
    cap.vulkanSupported      = false;
    cap.glesSupported        = false;
    cap.fallbackReason       = "not_implemented";
    cap.gpuVendor            = "";
    cap.gpuRenderer          = "";
    cap.vendorId             = 0;
    cap.deviceId             = 0;
    cap.apiVersion           = 0;
    cap.vulkanDriverVersion  = 0;
    cap.profileGateStatus    = "unverified";
    cap.blacklistStatus      = "not_evaluated";
    return cap;
}

} // namespace render
} // namespace vanguard
