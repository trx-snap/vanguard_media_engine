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

// ANDROID-DUET-VULKAN-GREENSCREEN-STATIC-BACKGROUND (RND diagnostic only):
// static, non-video background selector for
// VulkanBackend::renderDuetGreenScreenStaticBackgroundFrame below. The
// integer values are the wire values crossing the Kotlin/JNI boundary
// (VanguardNativeBridge.renderAndroidDuetVulkanPreviewStaticBackgroundFrame
// backgroundMode); anything not listed here fails closed.
enum class DuetGreenScreenStaticBackgroundMode : int32_t {
    // Whole canvas cleared to an opaque teal (0.0, 0.5, 0.5, 1.0) in place
    // of the decoded source layer; camera drawn masked over it.
    kSolidTeal = 1,
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

    // ANDROID-DUET-VULKAN-GREENSCREEN-VISUAL: Duet green-screen frame. The
    // source/decoder import [sourceHandle] is drawn first, opaque and
    // aspect-filled into [sourceRect] exactly as renderDuetLayoutFrame below
    // draws it; the camera import [cameraHandle] is then aspect-filled into
    // [cameraRect] over it, alpha-masked by the session's green-screen mask
    // (mask sampled at the camera's own cropped UV) and straight-alpha
    // blended. Rects / buffer dimensions follow renderDuetLayoutFrame's
    // contract and placement math, and every layer is sampled through its
    // import's own external-format descriptor resources, so colour /
    // orientation / crop match the layout path.
    //
    // ANDROID-DUET-VULKAN-GPU-MASK: prefers the GPU-resident mask identified
    // by gpuMaskHandle (already imported via importHardwareBuffer, e.g. by
    // AndroidDuetVulkanPreviewSession::UpdateGpuMask) over the CPU-uploaded
    // overlay-texture mask identified by cpuMaskHandle (see UpdateMask() /
    // createOverlayTextureR8 below), whenever gpuMaskHandle is a currently
    // active, non-external-format import distinct from sourceHandle /
    // cameraHandle and gpuMaskWidth/gpuMaskHeight are both > 0. The GPU mask
    // import's first-use layout transition, pending acquire-semaphore wait
    // and submitted marking are handled per frame; it is never released by
    // this call. Pass kInvalidHardwareBufferHandle (with 0 width/height) for
    // gpuMaskHandle to always use the CPU mask.
    //
    // Same swapchain acquire / submit / present lifecycle and post-submit
    // import bookkeeping as renderDuetLayoutFrame. Not part of the shared
    // RenderBackend interface (no `override`); host builds return
    // kUnavailable. Invalid geometry fails closed with kVulkanFailure before
    // the swapchain is touched.
    // ANDROID-DUET-VULKAN-TRANSFORM: sourceRotationDegrees/cameraRotationDegrees
    // are each layer's cardinal clockwise display rotation (0/90/180/270;
    // non-cardinal values normalize to 0), applied before the aspect-fill
    // crop exactly like a solo frame's VideoFrameTransform.
    // sourceMirrorHorizontal/cameraMirrorHorizontal mirror that layer
    // horizontally in addition to the rotation.
    // debugMode is the RND matte-visualization mode forwarded verbatim to
    // VulkanFrameRenderer::VulkanGreenScreenMaskInfo::debugMode (0 = normal,
    // 1 = mask_direct, 2 = mask_mapped, 3 = mask_direct_mirror_x,
    // 4 = mask_direct_flip_y).
    // ANDROID-DUET-VULKAN-GREENSCREEN-FREE-TRANSFORM: foregroundRotationDegrees/
    // foregroundAnchorX/foregroundAnchorY are the Duet-only user foreground
    // free-rotation for the camera layer -- entirely independent from
    // cameraRotationDegrees above (camera sensor/content rotation; both may
    // be non-zero at once). foregroundRotationDegrees is visual clockwise in
    // canvas-pixel space, any finite value; identity default (0.0) keeps
    // this call byte-for-byte identical to before this parameter existed.
    // foregroundAnchorX/foregroundAnchorY are the normalized [0,1] pivot
    // within cameraRect the rotation is applied around (default 0.5, 0.5 --
    // centre). Forwarded verbatim to
    // VulkanFrameRenderer::VulkanGreenScreenForegroundRotation.
    RenderFrameResult renderDuetGreenScreenFrame(HardwareBufferHandle sourceHandle,
                                                 HardwareBufferHandle cameraHandle,
                                                 const RenderDestinationRect& sourceRect,
                                                 const RenderDestinationRect& cameraRect,
                                                 uint32_t sourceBufferWidth,
                                                 uint32_t sourceBufferHeight,
                                                 uint32_t cameraBufferWidth,
                                                 uint32_t cameraBufferHeight,
                                                 VulkanOverlayTextureHandle cpuMaskHandle,
                                                 HardwareBufferHandle gpuMaskHandle,
                                                 uint32_t gpuMaskWidth,
                                                 uint32_t gpuMaskHeight,
                                                 uint32_t sourceRotationDegrees,
                                                 bool sourceMirrorHorizontal,
                                                 uint32_t cameraRotationDegrees,
                                                 bool cameraMirrorHorizontal,
                                                 int32_t debugMode = 0,
                                                 float foregroundRotationDegrees = 0.0f,
                                                 float foregroundAnchorX = 0.5f,
                                                 float foregroundAnchorY = 0.5f);

    // ANDROID-DUET-VULKAN-GREENSCREEN-STATIC-BACKGROUND (RND diagnostic
    // only): camera-only Duet green-screen frame over a static background.
    // Identical to renderDuetGreenScreenFrame above -- same camera rect /
    // buffer-dimension / rotation / mirror placement contract, same CPU-vs-GPU
    // mask selection (gpuMaskHandle preferred when active, non-external-format
    // and distinct from cameraHandle, cpuMaskHandle otherwise), same debugMode
    // forwarding, same swapchain acquire / submit / present lifecycle and
    // post-submit import bookkeeping for the camera import and the held GPU
    // mask -- except that there is NO source / decoder layer: the swapchain
    // render pass is begun with the clear colour selected by backgroundMode
    // and nothing is drawn for the source before the masked camera draw. Lets
    // RND evaluate person matte quality without video-background decoder
    // pressure. Not part of the shared RenderBackend interface (no
    // `override`); host builds return kUnavailable. An unrecognized
    // backgroundMode or invalid geometry fails closed with kVulkanFailure
    // before the swapchain is touched. Production renderDuetGreenScreenFrame /
    // renderDuetLayoutFrame behaviour is unchanged.
    // ANDROID-DUET-VULKAN-GREENSCREEN-FREE-TRANSFORM: same foreground
    // free-rotation contract as renderDuetGreenScreenFrame above.
    RenderFrameResult renderDuetGreenScreenStaticBackgroundFrame(
        HardwareBufferHandle cameraHandle,
        const RenderDestinationRect& cameraRect,
        uint32_t cameraBufferWidth,
        uint32_t cameraBufferHeight,
        VulkanOverlayTextureHandle cpuMaskHandle,
        HardwareBufferHandle gpuMaskHandle,
        uint32_t gpuMaskWidth,
        uint32_t gpuMaskHeight,
        uint32_t cameraRotationDegrees,
        bool cameraMirrorHorizontal,
        int32_t debugMode,
        DuetGreenScreenStaticBackgroundMode backgroundMode,
        float foregroundRotationDegrees = 0.0f,
        float foregroundAnchorX = 0.5f,
        float foregroundAnchorY = 0.5f);

    // ANDROID-DUET-VULKAN-LAYOUT: two-layer opaque Duet layout frame (PiP /
    // split, and the green-screen terminal fallback to safe PiP). The
    // background/source import [sourceHandle] is aspect-filled into
    // [sourceRect] first, then the foreground/camera import [cameraHandle]
    // is aspect-filled into [cameraRect] over it; both rects are canvas pixel
    // rects (top-left origin, Y-down, width/height > 0). The buffer
    // dimensions are each import's content size used for the aspect-fill
    // crop (0 on either axis stretches that layer to its rect instead). Same
    // swapchain acquire / submit / present lifecycle and post-submit import
    // bookkeeping (both imports marked submitted, a release sync-fd stored on
    // each) as renderDuetGreenScreenFrame. Not part of the shared
    // RenderBackend interface (no `override`); host builds return
    // kUnavailable. Invalid geometry fails closed with kVulkanFailure before
    // the swapchain is touched.
    // ANDROID-DUET-VULKAN-TRANSFORM: see renderDuetGreenScreenFrame above for
    // the rotation/mirror contract; identical here.
    RenderFrameResult renderDuetLayoutFrame(HardwareBufferHandle sourceHandle,
                                            HardwareBufferHandle cameraHandle,
                                            const RenderDestinationRect& sourceRect,
                                            const RenderDestinationRect& cameraRect,
                                            uint32_t sourceBufferWidth,
                                            uint32_t sourceBufferHeight,
                                            uint32_t cameraBufferWidth,
                                            uint32_t cameraBufferHeight,
                                            uint32_t sourceRotationDegrees,
                                            bool sourceMirrorHorizontal,
                                            uint32_t cameraRotationDegrees,
                                            bool cameraMirrorHorizontal,
                                            float cameraCornerRadiusPx = 0.0f);

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
