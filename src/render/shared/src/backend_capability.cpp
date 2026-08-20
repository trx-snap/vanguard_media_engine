#include "vanguard/render/backend_capability.h"

namespace vanguard {
namespace render {

// Default stub. Real probe in platform-specific code.
BackendCapability ProbeBackendCapability() {
    return BackendCapability{
        RenderBackendType::kUnavailable,
        false,
        false,
        "Not implemented"
    };
}

} // namespace render
} // namespace vanguard
