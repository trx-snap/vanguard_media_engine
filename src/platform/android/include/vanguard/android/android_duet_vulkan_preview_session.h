#pragma once

#include <cstddef>
#include <cstdint>
#include <memory>

struct ANativeWindow;

namespace vanguard {
namespace android {

class AndroidDuetVulkanPreviewSession {
public:
    AndroidDuetVulkanPreviewSession();
    ~AndroidDuetVulkanPreviewSession();

    // Non-copyable, non-movable
    AndroidDuetVulkanPreviewSession(const AndroidDuetVulkanPreviewSession&) = delete;
    AndroidDuetVulkanPreviewSession& operator=(const AndroidDuetVulkanPreviewSession&) = delete;

    // Creates the backend and a default 1x1 zero R8 mask texture, so a
    // RenderFrame call before the first UpdateMask never observes an invalid
    // mask handle.
    bool Initialize();
    bool AttachSurface(ANativeWindow* window, uint32_t width, uint32_t height);
    void DetachSurface();

    // Creates or updates the session-owned R8 green-screen mask texture from
    // a tightly packed (rowStrideBytes == width) single-channel buffer.
    // r8ByteCount is the caller-declared size of r8 in bytes. Same-size
    // updates are applied in place; a size change releases the old texture
    // and creates a new one. On failure the previously valid mask (if any)
    // is left in place, so the session's mask handle never becomes invalid
    // as a result of a failed update.
    bool UpdateMask(const uint8_t* r8, size_t r8ByteCount, uint32_t width, uint32_t height);

    // Imports decoderBuffer/cameraBuffer (each a non-null AHardwareBuffer*
    // cast to void*) as the background/foreground layers respectively,
    // composites them with the session's current mask via
    // VulkanBackend::renderDuetGreenScreenFrame onto the attached surface,
    // then releases both imports (draining and closing any release fence)
    // before returning, on every path. Returns false without importing
    // anything when no surface is attached. Never retains either pointer
    // beyond this call.
    bool RenderFrame(void* decoderBuffer, void* cameraBuffer);

private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};

} // namespace android
} // namespace vanguard
