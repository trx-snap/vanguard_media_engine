#pragma once
#include "vanguard/core/status.h"
#include <cstdint>

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

    // Lifecycle / capability
    virtual bool initialize() = 0;
    virtual void shutdown() = 0;
    virtual RenderBackendType type() const = 0;

    // Surface / swapchain lifecycle.
    // nativeWindow is a borrowed ANativeWindow* cast to void*.
    // The caller (platform adapter) owns the native window lifetime;
    // this layer must NOT acquire, release, or store it beyond the call.
    virtual bool attachSurface(void* nativeWindow,
                               uint32_t width,
                               uint32_t height) = 0;
    virtual bool resizeSurface(uint32_t width, uint32_t height) = 0;
    virtual void detachSurface() = 0;
    virtual bool hasSurface() const = 0;
};

} // namespace render
} // namespace vanguard
