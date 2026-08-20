#pragma once
#include "vanguard/core/status.h"
#include "vanguard/render/hardware_buffer_import.h"
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

    // ---------------------------------------------------------------------------
    // Phase 2C: AHardwareBuffer import foundation.
    // ---------------------------------------------------------------------------

    // Import an AHardwareBuffer into the backend for GPU use.
    //
    // hardwareBuffer  - non-null AHardwareBuffer* cast to void*.
    // acquireFenceFd  - file descriptor for the acquire fence, or -1 if none.
    //                   Ownership transfers to the backend unconditionally at
    //                   call entry regardless of return value.  The backend
    //                   closes it on failure before returning, and on success
    //                   stores it until release/shutdown.
    // outHandle       - non-null; receives the opaque handle on success, or
    //                   kInvalidHardwareBufferHandle on failure.
    // outDescriptor   - non-null; populated with buffer properties on success,
    //                   or zeroed on failure.
    //
    // Returns HardwareBufferImportResult::kSuccess on success.
    virtual HardwareBufferImportResult importHardwareBuffer(
        void* hardwareBuffer,
        int acquireFenceFd,
        HardwareBufferHandle* outHandle,
        HardwareBufferDescriptor* outDescriptor) = 0;

    // Release a previously imported buffer by handle.
    //
    // handle            - handle returned by a successful importHardwareBuffer.
    // outReleaseFenceFd - optional; if non-null set to -1 (Phase 2C does not
    //                     produce a release fence).
    //
    // Destroys GPU resources, releases the AHardwareBuffer ref, closes the
    // stored acquireFenceFd, and removes the entry from the handle table.
    // Returns kUnknownHandle for unrecognised handles.
    virtual HardwareBufferImportResult releaseHardwareBuffer(
        HardwareBufferHandle handle,
        int* outReleaseFenceFd) = 0;

    // Returns true iff handle identifies an active import in this backend.
    virtual bool hasHardwareBuffer(HardwareBufferHandle handle) const = 0;
};

} // namespace render
} // namespace vanguard
