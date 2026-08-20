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

} // namespace render
} // namespace vanguard
