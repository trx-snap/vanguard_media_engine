#include "vanguard/render/gles_backend.h"

#if !defined(_WIN32)
#include <unistd.h>   // close()
#endif

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

// ---------------------------------------------------------------------------
// Phase 2C: AHardwareBuffer import stubs - GLES backend does not support this.
// ---------------------------------------------------------------------------

HardwareBufferImportResult GlesBackend::importHardwareBuffer(
    void* /*hardwareBuffer*/,
    int acquireFenceFd,
    HardwareBufferHandle* outHandle,
    HardwareBufferDescriptor* outDescriptor)
{
    // Ownership of acquireFenceFd transfers at call entry; close it if valid.
#if !defined(_WIN32)
    if (acquireFenceFd >= 0) {
        ::close(acquireFenceFd);
    }
#else
    (void)acquireFenceFd;
#endif
    if (outHandle) {
        *outHandle = kInvalidHardwareBufferHandle;
    }
    if (outDescriptor) {
        *outDescriptor = HardwareBufferDescriptor{};
    }
    return HardwareBufferImportResult::kUnavailable;
}

HardwareBufferImportResult GlesBackend::releaseHardwareBuffer(
    HardwareBufferHandle /*handle*/,
    int* outReleaseFenceFd)
{
    if (outReleaseFenceFd) {
        *outReleaseFenceFd = -1;
    }
    return HardwareBufferImportResult::kUnavailable;
}

bool GlesBackend::hasHardwareBuffer(HardwareBufferHandle /*handle*/) const {
    return false;
}

} // namespace render
} // namespace vanguard
