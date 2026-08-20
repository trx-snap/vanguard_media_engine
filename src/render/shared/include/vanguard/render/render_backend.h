#pragma once
#include "vanguard/core/status.h"

namespace vanguard {
namespace render {

enum class RenderBackendType {
    kVulkan,
    kGles,
    kUnavailable
};

class RenderBackend {
public:
    virtual ~RenderBackend() = default;
    
    // Lifecycle/capability only in Phase 1
    virtual bool initialize() = 0;
    virtual void shutdown() = 0;
    virtual RenderBackendType type() const = 0;
};

} // namespace render
} // namespace vanguard
