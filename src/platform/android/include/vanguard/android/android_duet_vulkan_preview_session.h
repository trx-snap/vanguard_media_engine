#pragma once

#include <cstddef>
#include <cstdint>
#include <memory>

struct ANativeWindow;

namespace vanguard {
namespace android {

// ANDROID-DUET-VULKAN-LAYOUT: canvas pixel rect (top-left origin, Y-down) of
// one Duet layout layer, as already rounded / clamped by the Kotlin
// compositor. Kept as a plain struct so this header stays free of render
// headers; RenderFrame converts it to the backend's RenderDestinationRect.
struct AndroidDuetVulkanPreviewLayoutRect {
    int32_t x = 0;
    int32_t y = 0;
    int32_t width = 0;
    int32_t height = 0;
};

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
    // cast to void*) as the background/foreground layers respectively and
    // presents one frame onto the attached surface:
    //   * greenScreenEnabled == true: composites them with the session's
    //     current mask via VulkanBackend::renderDuetGreenScreenFrame
    //     (full-canvas; sourceRect/cameraRect are ignored),
    //   * greenScreenEnabled == false (PiP / split / green-screen terminal
    //     fallback): draws the decoder aspect-filled into sourceRect, then
    //     the camera aspect-filled into cameraRect over it, via
    //     VulkanBackend::renderDuetLayoutFrame using each import's own
    //     buffer dimensions for the crop.
    // Both imports are released (draining and closing any release fence)
    // before returning, on every path after import. Returns false without
    // importing anything when no surface is attached. Never retains either
    // pointer beyond this call.
    bool RenderFrame(void* decoderBuffer,
                     void* cameraBuffer,
                     bool greenScreenEnabled,
                     const AndroidDuetVulkanPreviewLayoutRect& sourceRect,
                     const AndroidDuetVulkanPreviewLayoutRect& cameraRect);

private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};

} // namespace android
} // namespace vanguard
