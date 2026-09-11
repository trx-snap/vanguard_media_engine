// vulkan_frame_renderer.h
// Phase 2O2B1: Modular Frame Renderer Extraction.
//
// VulkanFrameRenderer is a private helper class encapsulating frame rendering
// orchestration, per-frame synchronization, graphics pipeline lifecycle, and
// cached pipeline layout/render pass metadata behind a PImpl.
//
// All Vulkan and Android headers are strictly confined to the .cpp translation unit.
// This header includes only <cstdint>, <memory>, and shared render types.

#pragma once

#include "vanguard/render/hardware_buffer_import.h"
#include "vanguard/render/render_backend.h"
#include "vanguard/render/render_transform.h"

#include <cstdint>
#include <memory>

namespace vanguard {
namespace render {

class VulkanSurfaceSwapchain;
class VulkanHardwareBufferImports;
struct VulkanCoreShaderModules;

// P5-OVERLAYS-TRANS / P5-OVERLAYS-PRODUCTION-EXPORT-ROUTE-A: forward-declared
// only. VulkanOverlayFrameDraw is a plain, platform-neutral data struct (see
// vulkan_overlay_frame_renderer.h); this header never needs its definition,
// only a pointer to it, so the Vulkan overlay helper header is included
// solely from the .cpp translation unit.
struct VulkanOverlayFrameDraw;

class VulkanFrameRenderer {
public:
    static constexpr uint32_t kDefaultFramesInFlight = 2;

    VulkanFrameRenderer();
    ~VulkanFrameRenderer();

    // Non-copyable, non-movable.
    VulkanFrameRenderer(const VulkanFrameRenderer&) = delete;
    VulkanFrameRenderer& operator=(const VulkanFrameRenderer&) = delete;
    VulkanFrameRenderer(VulkanFrameRenderer&&) = delete;
    VulkanFrameRenderer& operator=(VulkanFrameRenderer&&) = delete;

    // Initializes frame synchronization and renderer state with borrowed device and command pool.
    // deviceHandle is cast from VkDevice (dispatchable); commandPoolHandle is encoded from VkCommandPool via memcpy.
    bool initialize(void* deviceHandle,
                    uint64_t commandPoolHandle,
                    uint32_t frameCount = kDefaultFramesInFlight);

    // Tears down graphics pipeline and frame synchronization resources. Idempotent.
    void shutdown();

    // Returns true if renderer is initialized.
    bool isInitialized() const;

    // Invalidates and destroys cached graphics pipeline and compatibility metadata.
    void invalidatePipeline();

    // Waits for device/GPU execution across all frames to complete.
    void waitAllFramesIdle();

    // Frame rendering entry point (identity transform path).
    // Validates preconditions and returns explicit result.
    RenderFrameResult renderFrame(
        void* queueHandle,
        VulkanSurfaceSwapchain& swapchain,
        VulkanHardwareBufferImports& ahbImports,
        VulkanCoreShaderModules& coreShaders,
        HardwareBufferHandle handle);

    // Phase 4B2C: Frame rendering with rotation transform.
    RenderFrameResult renderFrame(
        void* queueHandle,
        VulkanSurfaceSwapchain& swapchain,
        VulkanHardwareBufferImports& ahbImports,
        VulkanCoreShaderModules& coreShaders,
        HardwareBufferHandle handle,
        const VideoFrameTransform& transform);

    // P5-OVERLAYS-TRANS / P5-OVERLAYS-PRODUCTION-EXPORT-ROUTE-A native
    // renderer integration sub-slice N2: renderFrame with an optional set of
    // already-resolved overlay draws recorded via
    // VulkanOverlayFrameRenderer::recordOverlayDraws immediately after the
    // base decoded frame, inside the SAME render pass (VulkanGraphicsCommand
    // Recorder::recordCompletePass cannot be reused here since it ends the
    // render pass itself before returning). When overlayCount == 0 this
    // delegates directly to the transform-only overload above with zero
    // additional Vulkan calls -- byte-identical to existing non-overlay
    // behavior. overlayDraws may be null only when overlayCount is 0; a
    // non-null overlayCount with a null overlayDraws fails closed with
    // kVulkanFailure before the swapchain is touched. On any overlay record
    // failure the whole frame fails closed -- no partial present.
    RenderFrameResult renderFrame(
        void* queueHandle,
        VulkanSurfaceSwapchain& swapchain,
        VulkanHardwareBufferImports& ahbImports,
        VulkanCoreShaderModules& coreShaders,
        HardwareBufferHandle handle,
        const VideoFrameTransform& transform,
        const VulkanOverlayFrameDraw* overlayDraws,
        uint32_t overlayCount);

    // P5-BEAUTY-V2-PRODUCTION-EXPORT-ROUTE-A: renderFrame with an optional
    // Vulkan-only Beauty V2 pre-composite recorded via VulkanBeautyFrameRenderer
    // ahead of the existing placement draw. When beauty.enabled is false this
    // delegates directly to the transform-only overload above with zero
    // additional Vulkan calls -- byte-identical to existing non-beauty
    // behavior. physicalDeviceHandle is a VkPhysicalDevice cast to void*,
    // needed only for the beauty intermediates' device-local memory
    // allocation when beauty.enabled is true.
    RenderFrameResult renderFrame(
        void* queueHandle,
        void* physicalDeviceHandle,
        VulkanSurfaceSwapchain& swapchain,
        VulkanHardwareBufferImports& ahbImports,
        VulkanCoreShaderModules& coreShaders,
        HardwareBufferHandle handle,
        const VideoFrameTransform& transform,
        const VideoBeautyV2RenderParams& beauty);

    // P5-OVERLAYS-BEAUTY-SOLO: renderFrame with BOTH an optional Vulkan-only
    // Beauty V2 pre-composite AND an optional set of already-resolved overlay
    // draws, for a solo (non-transition) frame carrying both features at
    // once. When beauty.enabled is false this delegates directly to the
    // overlay-aware overload above with zero additional Vulkan calls --
    // byte-identical to the existing overlay-only behavior. When
    // overlayCount == 0 this delegates directly to the beauty-aware overload
    // above with zero additional Vulkan calls -- byte-identical to the
    // existing beauty-only behavior. When both are active, the beauty
    // pre-composite's placement pass
    // (VulkanBeautyFrameRenderer::recordBeautyKeepOpen) is recorded into the
    // caller's swapchain render pass and left OPEN so the overlay draws
    // (VulkanOverlayFrameRenderer::recordOverlayDraws) can be appended into
    // the SAME render pass immediately afterward -- overlays always
    // composite on top of the beautified base frame -- before this method
    // itself ends the render pass and the command buffer. overlayDraws may
    // be null only when overlayCount is 0. On any record failure the whole
    // frame fails closed -- no partial present.
    RenderFrameResult renderFrame(
        void* queueHandle,
        void* physicalDeviceHandle,
        VulkanSurfaceSwapchain& swapchain,
        VulkanHardwareBufferImports& ahbImports,
        VulkanCoreShaderModules& coreShaders,
        HardwareBufferHandle handle,
        const VideoFrameTransform& transform,
        const VideoBeautyV2RenderParams& beauty,
        const VulkanOverlayFrameDraw* overlayDraws,
        uint32_t overlayCount);

    // P5-COMPOSITOR-TRANS: two-source clip overlap transition frame. Same
    // acquire / frame fence / imageAvailable + presentReady semaphore /
    // pending AHB acquire semaphore wait / release-fence export / present
    // protocol as renderFrame, with the "from" and "to" imports drawn into
    // one clear render pass per [VideoTransitionFrameTransform]'s draw model.
    // Transition pipelines are rebuilt per call (pipeline layouts are per
    // import) after a device idle wait and retired on the next render call,
    // failClosed, invalidatePipeline or shutdown.
    //
    // P5-BEAUTY-V2-TRANSITION-COMP: [fromBeauty]/[toBeauty] are optional
    // per-layer Vulkan-only Beauty V2 pre-composite requests, mirroring the
    // solo-frame beauty renderFrame overload. When both are disabled this is
    // byte-identical to the pre-existing non-beauty transition path.
    // [physicalDeviceHandle] is a VkPhysicalDevice cast to void*, needed only
    // for a beauty-enabled layer's intermediates; failing closed on a null
    // handle happens only when a beauty layer is actually enabled, exactly
    // like the solo beauty overload.
    RenderFrameResult renderTransitionFrame(
        void* queueHandle,
        void* physicalDeviceHandle,
        VulkanSurfaceSwapchain& swapchain,
        VulkanHardwareBufferImports& ahbImports,
        VulkanCoreShaderModules& coreShaders,
        HardwareBufferHandle fromHandle,
        HardwareBufferHandle toHandle,
        const VideoTransitionFrameTransform& transition,
        const VideoBeautyV2RenderParams& fromBeauty = VideoBeautyV2RenderParams{},
        const VideoBeautyV2RenderParams& toBeauty = VideoBeautyV2RenderParams{});

    // P5-OVERLAYS-TRANSITION-COMP-N1 native-only seam: renderTransitionFrame
    // with an optional set of already-resolved overlay draws recorded via
    // VulkanOverlayFrameRenderer::recordOverlayDraws immediately after the
    // transition layer draws, inside the SAME final swapchain render pass
    // (VulkanGraphicsCommandRecorder::recordTransitionPass /
    // recordTransitionPassBody cannot be reused here since both end the
    // render pass themselves before returning; see
    // recordTransitionPassBodyKeepOpen in vulkan_graphics_command_recorder.h).
    // overlayDraws/overlayCount carry no default so a caller must always be
    // explicit about the overlay set; when overlayCount == 0 this delegates
    // directly to the overload above with zero additional Vulkan calls --
    // byte-identical to the pre-existing non-overlay transition behavior.
    // overlayDraws may be null only when overlayCount is 0; a non-null
    // overlayCount with a null overlayDraws fails closed with
    // kVulkanFailure before any Vulkan mutation. On any overlay record
    // failure the whole frame fails closed -- no partial present.
    //
    // N1 is native-only: no JNI/Kotlin route calls this yet, and this slice
    // does not change export admission.
    RenderFrameResult renderTransitionFrame(
        void* queueHandle,
        void* physicalDeviceHandle,
        VulkanSurfaceSwapchain& swapchain,
        VulkanHardwareBufferImports& ahbImports,
        VulkanCoreShaderModules& coreShaders,
        HardwareBufferHandle fromHandle,
        HardwareBufferHandle toHandle,
        const VideoTransitionFrameTransform& transition,
        const VulkanOverlayFrameDraw* overlayDraws,
        uint32_t overlayCount,
        const VideoBeautyV2RenderParams& fromBeauty = VideoBeautyV2RenderParams{},
        const VideoBeautyV2RenderParams& toBeauty = VideoBeautyV2RenderParams{});

    struct VulkanGreenScreenMaskInfo {
        uint64_t imageViewHandle = 0;
        uint64_t samplerHandle = 0;
        uint32_t width = 0;
        uint32_t height = 0;
    };

    RenderFrameResult renderDuetGreenScreenFrame(
        void* queueHandle,
        VulkanSurfaceSwapchain& swapchain,
        VulkanHardwareBufferImports& ahbImports,
        HardwareBufferHandle backgroundHandle,
        HardwareBufferHandle foregroundHandle,
        const VulkanGreenScreenMaskInfo& maskInfo);

private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};

} // namespace render
} // namespace vanguard
