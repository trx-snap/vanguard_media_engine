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

    // ANDROID-DUET-VULKAN-GPU-MASK: imports gpuMaskBuffer (a non-null
    // AHardwareBuffer* cast to void*, e.g. an R8 or RGBA mask already
    // produced on GPU) as the session's GPU-resident green-screen mask via
    // the same Vulkan hardware-buffer import path used for the decoder/
    // camera layers in RenderFrame, storing it separately from the
    // CPU-uploaded mask above so both remain independently valid. Unlike the
    // decoder/camera imports (imported and released within a single
    // RenderFrame call), this import is HELD across frames until replaced by
    // a later UpdateGpuMask() call or released by this session's
    // destruction; RenderFrame never releases it.
    //
    // On success the previous GPU mask (if any) is released and replaced by
    // the new import. On failure (null buffer, non-positive width/height, or
    // an unsupported/failed import) the previous GPU mask (if any) is left
    // valid and this returns false; the CPU-uploaded mask remains available
    // as RenderFrame's fallback either way.
    //
    // Caller contract: gpuMaskBuffer must be a DIFFERENT underlying
    // AHardwareBuffer from any GPU mask currently held by this session (the
    // Vulkan import table rejects re-importing a buffer with an active
    // import); reusing the same still-held buffer across calls is a caller
    // error this slice does not special-case.
    bool UpdateGpuMask(void* gpuMaskBuffer, uint32_t width, uint32_t height, int acquireFenceFd = -1);

    // Imports decoderBuffer/cameraBuffer (each a non-null AHardwareBuffer*
    // cast to void*) as the source/camera layers respectively and presents
    // one frame onto the attached surface. In both modes the decoder is
    // aspect-filled into sourceRect and the camera into cameraRect, using a
    // crop dimension resolved per layer as sourceContentWidth/Height (resp.
    // cameraContentWidth/Height) when both are > 0, else falling back to
    // that import's own AHardwareBuffer descriptor width/height (both rects
    // must have width/height > 0 or this returns false before importing
    // anything). The caller-provided content dimensions take precedence
    // because the AHB descriptor can carry consumer/allocator padding (e.g.
    // a portrait ImageReader request rounded up to a square allocation) that
    // the descriptor alone cannot distinguish from real content size; the
    // descriptor remains the fallback for import/validation only:
    //   * greenScreenEnabled == true (ANDROID-DUET-VULKAN-GREENSCREEN-VISUAL):
    //     draws the decoder opaque into sourceRect, then the camera into
    //     cameraRect over it alpha-masked by the session's current mask, via
    //     VulkanBackend::renderDuetGreenScreenFrame — the GPU mask from
    //     UpdateGpuMask() is preferred when present and valid, falling back
    //     to the CPU mask from UpdateMask() otherwise,
    //   * greenScreenEnabled == false (PiP / split / green-screen terminal
    //     fallback): draws both layers opaque via
    //     VulkanBackend::renderDuetLayoutFrame.
    // Both imports are released (draining and closing any release fence)
    // before returning, on every path after import; the GPU mask import is
    // never released here. Returns false without importing anything when no
    // surface is attached. Never retains either pointer beyond this call.
    // ANDROID-DUET-VULKAN-TRANSFORM: sourceRotationDegrees/cameraRotationDegrees
    // are each layer's cardinal clockwise display rotation (0/90/180/270;
    // non-cardinal values normalize to 0 in the backend), applied before the
    // aspect-fill crop exactly like a solo frame's VideoFrameTransform. The
    // source/decoder layer is never mirrored (front/back camera mirroring is
    // a camera-only concern); cameraMirrorHorizontal mirrors the camera layer
    // horizontally (front camera) in both the green-screen and layout paths.
    // debugMode is the RND matte-visualization mode forwarded to
    // VulkanBackend::renderDuetGreenScreenFrame when greenScreenEnabled is
    // true (0 = normal, 1 = mask_direct, 2 = mask_mapped,
    // 3 = mask_direct_mirror_x, 4 = mask_direct_flip_y); ignored on the
    // opaque layout path.
    // ANDROID-DUET-VULKAN-CAMERA-CONTENT-DIMENSIONS: sourceContentWidth/
    // sourceContentHeight and cameraContentWidth/cameraContentHeight are the
    // caller's logical content size for the decoder/camera layer
    // respectively, used as the aspect-fill crop dimensions in place of that
    // layer's imported AHardwareBuffer descriptor width/height whenever both
    // are > 0. The decoder's pair is sourced from the originating Image's
    // width/height; the camera's pair is sourced from the caller's own
    // requested camera reader dimensions rather than the originating
    // Image's width/height, since on Android that Image is on a
    // PRIVATE-format ImageReader whose width/height can reflect a padded
    // consumer/allocator allocation instead of the requested content size.
    // Pass 0 for a pair to fall back to the descriptor's own dimensions,
    // which remain fallback/diagnostic only.
    bool RenderFrame(void* decoderBuffer,
                     void* cameraBuffer,
                     bool greenScreenEnabled,
                     const AndroidDuetVulkanPreviewLayoutRect& sourceRect,
                     const AndroidDuetVulkanPreviewLayoutRect& cameraRect,
                     uint32_t sourceRotationDegrees,
                     uint32_t cameraRotationDegrees,
                     bool cameraMirrorHorizontal,
                     int32_t debugMode = 0,
                     uint32_t sourceContentWidth = 0,
                     uint32_t sourceContentHeight = 0,
                     uint32_t cameraContentWidth = 0,
                     uint32_t cameraContentHeight = 0);

    // ANDROID-DUET-VULKAN-GREENSCREEN-STATIC-BACKGROUND (RND diagnostic
    // only): camera-only green-screen frame over a static background. Imports
    // ONLY cameraBuffer (a non-null AHardwareBuffer* cast to void*) as the
    // camera layer and presents one frame onto the attached surface via
    // VulkanBackend::renderDuetGreenScreenStaticBackgroundFrame: the canvas is
    // cleared to the static colour selected by backgroundMode (1 = solid_teal,
    // mirroring render::DuetGreenScreenStaticBackgroundMode; any other value
    // returns false before importing anything) instead of drawing a decoded
    // source layer, then the camera is aspect-filled into cameraRect over it
    // alpha-masked by the session's current mask -- the GPU mask from
    // UpdateGpuMask() preferred when present and valid, the CPU mask from
    // UpdateMask() otherwise, exactly as RenderFrame's green-screen path
    // selects it. cameraRotationDegrees / cameraMirrorHorizontal / debugMode /
    // cameraContentWidth / cameraContentHeight follow RenderFrame's camera
    // contract verbatim (content dimensions preferred over the import
    // descriptor when both > 0). The camera import is released (draining and
    // closing any release fence) before returning on every path after import;
    // the GPU mask import is never released here. Returns false without
    // importing anything when no surface is attached or cameraRect has a
    // non-positive size. Never retains cameraBuffer beyond this call.
    // RenderFrame above is unchanged.
    bool RenderStaticBackgroundFrame(void* cameraBuffer,
                                     const AndroidDuetVulkanPreviewLayoutRect& cameraRect,
                                     uint32_t cameraRotationDegrees,
                                     bool cameraMirrorHorizontal,
                                     int32_t debugMode,
                                     int32_t backgroundMode,
                                     uint32_t cameraContentWidth = 0,
                                     uint32_t cameraContentHeight = 0);

private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};

} // namespace android
} // namespace vanguard
