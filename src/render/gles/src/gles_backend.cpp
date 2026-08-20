#include "vanguard/render/gles_backend.h"

namespace vanguard {
namespace render {

bool GlesBackend::initialize() {
    return true; // Scaffold
}

void GlesBackend::shutdown() {
    // Scaffold
}

RenderBackendType GlesBackend::type() const {
    return RenderBackendType::kGles;
}

bool GlesBackend::attachSurface(void*, uint32_t, uint32_t) {
    return false;
}

bool GlesBackend::resizeSurface(uint32_t, uint32_t) {
    return false;
}

void GlesBackend::detachSurface() {}

bool GlesBackend::hasSurface() const {
    return false;
}

} // namespace render
} // namespace vanguard
