#pragma once
// Phase 2B2: VulkanBackend - public header.
// Phase 2C: Added AHardwareBuffer import methods.
// Phase 2O1: Added renderFrame seam.
// Must NOT include Vulkan or Android headers.
// All Vulkan types live exclusively in vulkan_backend.cpp.

#include "vanguard/render/render_backend.h"

#include <cstddef>
#include <cstdint>
#include <memory>

namespace vanguard {
namespace render {

// P5-OVERLAYS-TRANS / P5-OVERLAYS-PRODUCTION-EXPORT-ROUTE-A: forward-declared
// only. VulkanOverlayFrameDraw is a private helper type (see
// vulkan_overlay_frame_renderer.h) never exposed by this public header; only
// a pointer to it crosses this seam.
struct VulkanOverlayFrameDraw;

// P5-OVERLAYS-TRANS / P5-OVERLAYS-PRODUCTION-EXPORT-ROUTE-A backend seam
// sub-slice N4: opaque handle + descriptor for a backend-owned Vulkan
// overlay texture (see VulkanBackend::createOverlayTextureRgba8888 below and
// the private VulkanOverlayTextureStore helper). imageViewHandle /
// samplerHandle are VkImageView / VkSampler non-dispatchable handles widened
// to uint64_t, matching VulkanOverlayFrameDraw::imageViewHandle /
// samplerHandle so a caller can populate a draw directly from this info.
using VulkanOverlayTextureHandle = uint64_t;
constexpr VulkanOverlayTextureHandle kInvalidOverlayTextureHandle = 0;

struct VulkanOverlayTextureInfo {
    uint64_t imageViewHandle = 0;
    uint64_t samplerHandle = 0;
    uint32_t width = 0;
    uint32_t height = 0;
};

class VulkanBackend : public RenderBackend {
public:
    VulkanBackend();
    ~VulkanBackend() override;

    // Non-copyable, non-movable (owns Vulkan state).
    VulkanBackend(const VulkanBackend&) = delete;
    VulkanBackend& operator=(const VulkanBackend&) = delete;

    bool initialize() override;
    void shutdown() override;
    RenderBackendType type() const override;

    // Surface / swapchain lifecycle (delegates to VulkanSurfaceSwapchain).
    bool attachSurface(void* nativeWindow,
                       uint32_t width,
                       uint32_t height) override;
    bool resizeSurface(uint32_t width, uint32_t height) override;
    void detachSurface() override;
    bool hasSurface() const override;

    // Phase 2C: AHardwareBuffer import foundation.
    HardwareBufferImportResult importHardwareBuffer(
        void* hardwareBuffer,
        int acquireFenceFd,
        HardwareBufferHandle* outHandle,
        HardwareBufferDescriptor* outDescriptor) override;

    HardwareBufferImportResult releaseHardwareBuffer(
        HardwareBufferHandle handle,
        int* outReleaseFenceFd) override;

    bool hasHardwareBuffer(HardwareBufferHandle handle) const override;

    // Phase 2O1: Frame rendering seam stub.
    RenderFrameResult renderFrame(HardwareBufferHandle handle) override;

    // Phase 4B2C: renderFrame with rotation transform.
    RenderFrameResult renderFrame(HardwareBufferHandle handle,
                                  const VideoFrameTransform& transform) override;

    // P5-OVERLAYS-TRANS / P5-OVERLAYS-PRODUCTION-EXPORT-ROUTE-A backend seam
    // sub-slice N3: renderFrame with an optional set of already-resolved
    // overlay draws, mirroring VulkanFrameRenderer's overlay overload. Not
    // part of the shared RenderBackend interface, so this is a concrete
    // VulkanBackend-only addition (no `override`). overlayDraws may be null
    // only when overlayCount is 0; overlayCount == 0 is byte-identical to the
    // transform-only overload above.
    RenderFrameResult renderFrame(HardwareBufferHandle handle,
                                  const VideoFrameTransform& transform,
                                  const VulkanOverlayFrameDraw* overlayDraws,
                                  uint32_t overlayCount);

    // P5-BEAUTY-V2-PRODUCTION-EXPORT-ROUTE-A: renderFrame with an optional
    // Vulkan-only Beauty V2 pre-composite. When beauty.enabled is false this
    // is byte-identical to the transform-only overload above.
    RenderFrameResult renderFrame(HardwareBufferHandle handle,
                                  const VideoFrameTransform& transform,
                                  const VideoBeautyV2RenderParams& beauty) override;

    // P5-OVERLAYS-BEAUTY-SOLO: renderFrame with BOTH an optional Beauty V2
    // pre-composite AND an optional set of already-resolved overlay draws,
    // for a solo (non-transition) frame carrying both features at once. Not
    // part of the shared RenderBackend interface, so this is a concrete
    // VulkanBackend-only addition (no `override`), mirroring the overlay-only
    // and beauty-only concrete overloads above. When beauty.enabled is false
    // this is byte-identical to the overlay-only overload above; when
    // overlayCount == 0 this is byte-identical to the beauty-only overload
    // above. overlayDraws may be null only when overlayCount is 0.
    RenderFrameResult renderFrame(HardwareBufferHandle handle,
                                  const VideoFrameTransform& transform,
                                  const VideoBeautyV2RenderParams& beauty,
                                  const VulkanOverlayFrameDraw* overlayDraws,
                                  uint32_t overlayCount);

    // P5-COMPOSITOR-TRANS: two-source clip overlap transition frame through
    // the same swapchain acquire/submit/present lifecycle as renderFrame.
    // P5-BEAUTY-V2-TRANSITION-COMP: optional per-layer Beauty V2 params;
    // byte-identical to the pre-existing behavior when both are disabled.
    RenderFrameResult renderTransitionFrame(
        HardwareBufferHandle fromHandle,
        HardwareBufferHandle toHandle,
        const VideoTransitionFrameTransform& transition,
        const VideoBeautyV2RenderParams& fromBeauty = VideoBeautyV2RenderParams{},
        const VideoBeautyV2RenderParams& toBeauty = VideoBeautyV2RenderParams{}) override;

    // P5-OVERLAYS-TRANSITION-COMP-N1 native-only seam: renderTransitionFrame
    // with an optional set of already-resolved overlay draws composited
    // after the transition layer draws in the SAME final swapchain render
    // pass, mirroring the overlay renderFrame overload above and
    // VulkanFrameRenderer's overlay-aware renderTransitionFrame overload.
    // Not part of the shared RenderBackend interface, so this is a concrete
    // VulkanBackend-only addition (no `override`); the RenderBackend
    // override just above is unchanged. overlayDraws/overlayCount carry no
    // default, so a caller must always be explicit about the overlay set;
    // overlayDraws may be null only when overlayCount is 0. This slice does
    // not add a JNI/Kotlin route or change export admission.
    RenderFrameResult renderTransitionFrame(
        HardwareBufferHandle fromHandle,
        HardwareBufferHandle toHandle,
        const VideoTransitionFrameTransform& transition,
        const VulkanOverlayFrameDraw* overlayDraws,
        uint32_t overlayCount,
        const VideoBeautyV2RenderParams& fromBeauty = VideoBeautyV2RenderParams{},
        const VideoBeautyV2RenderParams& toBeauty = VideoBeautyV2RenderParams{});

    RenderFrameResult renderDuetGreenScreenFrame(HardwareBufferHandle backgroundHandle,
                                                 HardwareBufferHandle foregroundHandle,
                                                 VulkanOverlayTextureHandle maskHandle);

    // P5-OVERLAYS-TRANS / P5-OVERLAYS-PRODUCTION-EXPORT-ROUTE-A backend seam
    // sub-slice N4: backend-owned Vulkan overlay texture store for static
    // sticker RGBA pixels (see the private VulkanOverlayTextureStore
    // helper). Not part of the shared RenderBackend interface, so these are
    // concrete VulkanBackend-only additions (no `override`); host builds
    // stub every method to false/no-op.
    //
    // Threading contract (Opus validation): this store performs no internal
    // synchronization. Every call below must be made from the same
    // thread/serialized lane that owns this VulkanBackend's render
    // loop/session, and must never run concurrently with renderFrame() (any
    // overload) or with each other on this backend -- the caller is
    // responsible for serializing all overlay texture-store calls against
    // renderFrame()/releaseOverlayTexture()/clearOverlayTextures().

    // Uploads `rgba` into a brand-new persistent, sampled RGBA8 texture and
    // returns a stable handle plus (optionally) its VkImageView/VkSampler/
    // extent via outInfo. rgbaByteCount is the caller-declared size of
    // `rgba` in bytes; rowStrideBytes is the caller's source row stride in
    // bytes, or 0 for tightly packed rows (stride == width * 4). Fails
    // closed (returns false, *outHandle == kInvalidOverlayTextureHandle,
    // *outInfo zeroed when non-null) on any invalid input or Vulkan
    // failure; outInfo may be null.
    bool createOverlayTextureRgba8888(const uint8_t* rgba,
                                      size_t rgbaByteCount,
                                      uint32_t width,
                                      uint32_t height,
                                      uint32_t rowStrideBytes,
                                      VulkanOverlayTextureHandle* outHandle,
                                      VulkanOverlayTextureInfo* outInfo = nullptr);

    bool createOverlayTextureR8(const uint8_t* r8,
                                size_t r8ByteCount,
                                uint32_t width,
                                uint32_t height,
                                uint32_t rowStrideBytes,
                                VulkanOverlayTextureHandle* outHandle,
                                VulkanOverlayTextureInfo* outInfo = nullptr);

    bool updateOverlayTextureR8(VulkanOverlayTextureHandle handle,
                                const uint8_t* r8,
                                size_t r8ByteCount,
                                uint32_t width,
                                uint32_t height,
                                uint32_t rowStrideBytes);

    // Destroys handle's texture. Returns false (no-op) for an unknown or
    // already-released handle.
    bool releaseOverlayTexture(VulkanOverlayTextureHandle handle);

    // Returns true and fills *outInfo iff handle is an active texture;
    // returns false (zeroing *outInfo when non-null) otherwise.
    bool getOverlayTextureInfo(VulkanOverlayTextureHandle handle,
                               VulkanOverlayTextureInfo* outInfo) const;

    // Destroys every active overlay texture and the shared sampler/command
    // pool backing them. Idempotent. Must be called before this backend's
    // VkDevice is destroyed (VulkanBackend::shutdown() already does this).
    void clearOverlayTextures();

private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};

} // namespace render
} // namespace vanguard
