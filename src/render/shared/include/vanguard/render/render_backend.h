#pragma once
#include "vanguard/core/status.h"
#include "vanguard/render/hardware_buffer_import.h"
#include "vanguard/render/render_transform.h"
#include <cstdint>

namespace vanguard {
namespace render {

enum class RenderBackendType {
    kVulkan,
    kGles,
    kUnavailable
};

// ---------------------------------------------------------------------------
// Phase 2O1: RenderFrameResult - explicit per-frame render outcome.
// Using explicit states rather than bool to enable precise error propagation
// to the DAG orchestrator without losing distinction between recoverable and
// irrecoverable conditions.
// ---------------------------------------------------------------------------
enum class RenderFrameResult {
    kSuccess,              // Frame rendered and presented successfully.
    kSuboptimal,           // Rendered but swapchain is suboptimal (resize soon).
    kBackendNotInitialized,// Backend initialize() has not succeeded.
    kNoSurface,            // No swapchain surface is attached.
    kInvalidBufferHandle,  // handle does not identify an active import.
    kOutOfDate,            // Swapchain is out of date; caller must resize/reattach.
    kSurfaceLost,          // Surface was lost; caller must detach and reattach.
    kDeviceLost,           // Device lost; backend must be shut down and recreated.
    kVulkanFailure,        // Unclassified Vulkan error.
    kUnavailable,          // Operation not supported on this backend/platform.
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
    // outReleaseFenceFd - optional; if non-null, set to -1 first. On
    //                     kSuccess a backend may instead return an owned
    //                     sync fd (fd >= 0) that the caller must close; the
    //                     backend never closes it. A value of -1 simply
    //                     means no fence was produced for this release and
    //                     is not itself an error condition.
    //
    // Destroys GPU resources, releases the AHardwareBuffer ref, closes the
    // stored acquireFenceFd, and removes the entry from the handle table.
    // Returns kUnknownHandle for unrecognised handles.
    virtual HardwareBufferImportResult releaseHardwareBuffer(
        HardwareBufferHandle handle,
        int* outReleaseFenceFd) = 0;

    // Returns true iff handle identifies an active import in this backend.
    virtual bool hasHardwareBuffer(HardwareBufferHandle handle) const = 0;

    // ---------------------------------------------------------------------------
    // Phase 2O1: Frame rendering seam.
    // ---------------------------------------------------------------------------

    // Render a single frame using the imported AHardwareBuffer identified by
    // handle as the source image.  Returns an explicit result code.
    //
    // Phase 2O1 stubs: all backends return kUnavailable.
    // Phase 2O2 will wire acquire-semaphore wait, command recording, queue
    // submit, and swapchain present behind this seam.
    //
    // handle - must be a handle returned by a successful importHardwareBuffer.
    virtual RenderFrameResult renderFrame(HardwareBufferHandle handle) = 0;

    // ---------------------------------------------------------------------------
    // Phase 4B2C: renderFrame with spatial rotation transform.
    //
    // Identity path: default implementation calls renderFrame(handle) so existing
    // callers compile and behave identically without modification, as long as
    // transform carries no non-default destination rect (aspect-fit scaling).
    // A non-default destination rect requires backend support for scissor/
    // viewport-scoped rendering; a backend that has not overridden this method
    // cannot honor it, so this default fails closed with kUnavailable instead
    // of silently rendering to the full output extent.
    //
    // Backends that support push constants and destination-rect scaling
    // override this to apply the UV transform and scoped viewport/scissor.
    // ---------------------------------------------------------------------------
    virtual RenderFrameResult renderFrame(HardwareBufferHandle handle,
                                          const VideoFrameTransform& transform) {
        if (!transform.destinationRect.isDefault()) {
            return RenderFrameResult::kUnavailable;
        }
        return renderFrame(handle);
    }
};

} // namespace render
} // namespace vanguard
