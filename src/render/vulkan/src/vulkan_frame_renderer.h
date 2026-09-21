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

// ANDROID-DUET-VULKAN-GREENSCREEN-FREE-TRANSFORM: Duet-only foreground
// free-rotation for the green-screen camera layer preview -- entirely
// independent from VulkanFrameRenderer::DuetLayoutLayer::rotationDegrees
// (camera sensor/content rotation, which stays in the aspect-fill UV
// transform; both may be non-zero at once). [degrees] is visual clockwise in
// canvas-pixel space (Dart/top-left convention), any finite value including
// negative or beyond +-360; identity (default 0.0, or any non-finite value,
// or any magnitude below VulkanGreenScreenFrameRenderer::recordCameraDraw's
// small epsilon) keeps the pre-rotation axis-aligned draw exactly.
// [anchorX]/[anchorY] are the normalized [0,1] pivot within the camera rect
// the rotation is applied around (default 0.5, 0.5 -- rect centre);
// out-of-range or non-finite values are clamped/defaulted defensively, never
// fail closed.
//
// Deliberately declared at namespace scope rather than nested inside
// VulkanFrameRenderer: a nested class's default member initializers cannot
// be used to default-construct a default ARGUMENT of another member function
// of that same enclosing class (Clang rejects this as "default member
// initializer ... needed within definition of enclosing class ... outside of
// member functions"), matching how VideoBeautyV2RenderParams -- used the
// same way as a defaulted reference parameter below -- is also a namespace-
// scope struct rather than a nested one.
struct VulkanGreenScreenForegroundRotation {
    float degrees = 0.0f;
    float anchorX = 0.5f;
    float anchorY = 0.5f;
};

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

    // ANDROID-DUET-VULKAN-LAYOUT: one Duet layer. [rect] is the canvas pixel
    // rect (top-left origin, Y-down, width/height > 0) the layer
    // aspect-fills; [bufferWidth]/[bufferHeight] are the imported buffer's
    // content dimensions used for the aspect-fill crop (0 on either axis
    // stretches the layer to the rect instead). Shared by the opaque layout
    // frame and the green-screen frame below.
    struct DuetLayoutLayer {
        HardwareBufferHandle handle = kInvalidHardwareBufferHandle;
        RenderDestinationRect rect;
        uint32_t bufferWidth = 0;
        uint32_t bufferHeight = 0;
        // ANDROID-DUET-VULKAN-TRANSFORM: cardinal clockwise display rotation
        // of this layer's buffer content (0/90/180/270; non-cardinal values
        // normalize to 0) and whether it is additionally mirrored
        // horizontally (front camera). Threaded straight into
        // VulkanDuetLayoutLayerGeometry / ResolveVulkanDuetLayoutLayerPlacement,
        // applied before the aspect-fill crop, exactly like a solo frame's
        // VideoFrameTransform.
        uint32_t rotationDegrees = 0;
        bool mirrorHorizontal = false;
        float cornerRadiusPx = 0.0f;
    };

    // ANDROID-DUET-VULKAN-GREENSCREEN-VISUAL: the green-screen matte.
    // [imageViewHandle] is the mask's VkImageView widened to uint64_t; it is
    // sampled with VulkanGreenScreenFrameRenderer's own LINEAR sampler, so it
    // must be a non-external-format R8 / RGBA8 image whose .r channel is the
    // matte (0 -> source shows through, 1 -> camera). [width]/[height] must
    // be > 0.
    //
    // When [gpuMaskHandle] is a currently active import (the GPU-resident
    // mask the session holds across frames), renderDuetGreenScreenFrame also
    // owns that import's per-frame bookkeeping: it records the
    // UNDEFINED -> SHADER_READ_ONLY_OPTIMAL transition on first use, waits on
    // its pending acquire semaphore, and marks it submitted / transitioned
    // after a successful submit -- but never releases it and never stores a
    // release sync-fd on it. Leave it kInvalidHardwareBufferHandle for the
    // CPU-uploaded overlay-texture mask, which needs none of that.
    struct VulkanGreenScreenMaskInfo {
        uint64_t imageViewHandle = 0;
        uint32_t width = 0;
        uint32_t height = 0;
        HardwareBufferHandle gpuMaskHandle = kInvalidHardwareBufferHandle;

        // RND debug visualization mode forwarded verbatim to
        // VulkanGreenScreenCameraDraw::debugMode (0 = normal, 1 = mask_direct,
        // 2 = mask_mapped, 3 = mask_direct_mirror_x, 4 = mask_direct_flip_y).
        int32_t debugMode = 0;
    };

    // ANDROID-DUET-VULKAN-GREENSCREEN-VISUAL: Duet green-screen frame.
    // [source] (decoder) is drawn first, opaque and aspect-filled into its
    // rect through its import's own descriptor resources and the core
    // passthrough shaders (the same cached per-layer pipeline
    // renderDuetLayoutFrame uses), then [camera] is drawn aspect-filled into
    // ITS rect through VulkanGreenScreenFrameRenderer::recordCameraDraw: the
    // camera import's own external-format descriptor set, alpha-masked by
    // [maskInfo] and straight-alpha blended over the source layer. Both
    // placements come from ResolveVulkanDuetLayoutLayerPlacement, so rect /
    // aspect-fill crop / colour semantics are identical to the layout path;
    // the mask is sampled at the camera's cropped UV (no extra rotation or
    // mirror -- see the shader for the CPU-mask orientation caveat).
    //
    // Same acquire / frame fence / imageAvailable + presentReady semaphore /
    // pending AHB acquire semaphore wait / release-fence export (one export,
    // dup'd to the second import) / present protocol and post-submit
    // bookkeeping as renderDuetLayoutFrame, plus the GPU-mask bookkeeping
    // described on VulkanGreenScreenMaskInfo. Invalid geometry fails closed
    // with kVulkanFailure before the swapchain is touched; any later failure
    // fails closed with no partial present.
    // [foregroundRotation] defaults to identity, so an existing caller that
    // does not pass it observes byte-for-byte identical behavior.
    RenderFrameResult renderDuetGreenScreenFrame(
        void* queueHandle,
        VulkanSurfaceSwapchain& swapchain,
        VulkanHardwareBufferImports& ahbImports,
        VulkanCoreShaderModules& coreShaders,
        const DuetLayoutLayer& source,
        const DuetLayoutLayer& camera,
        const VulkanGreenScreenMaskInfo& maskInfo,
        const VulkanGreenScreenForegroundRotation& foregroundRotation =
            VulkanGreenScreenForegroundRotation{});

    // ANDROID-DUET-VULKAN-GREENSCREEN-STATIC-BACKGROUND (RND diagnostic
    // only): the static, non-video background of a camera-only green-screen
    // frame. [clearRgba] is the swapchain render pass clear colour the whole
    // canvas is filled with in place of the decoded source layer;
    // [modeLabel] is the caller's backgroundMode token (e.g. "solid_teal"),
    // used verbatim in the one-shot first-frame structured log only. Never
    // null; not retained beyond the call.
    struct DuetStaticBackground {
        float clearRgba[4] = {0.0f, 0.0f, 0.0f, 1.0f};
        const char* modeLabel = "";
    };

    // ANDROID-DUET-VULKAN-GREENSCREEN-STATIC-BACKGROUND (RND diagnostic
    // only): camera-only Duet green-screen frame over a static background.
    // Identical to renderDuetGreenScreenFrame above EXCEPT that there is no
    // source / decoder layer at all: the swapchain render pass is begun with
    // [background].clearRgba as its clear colour (via the same
    // VulkanGraphicsCommandRecorder::recordTransitionPassBodyKeepOpen body
    // with zero layer draws), nothing is drawn for the source, and [camera]
    // is then drawn aspect-filled into ITS rect through
    // VulkanGreenScreenFrameRenderer::recordCameraDraw with the SAME
    // ResolveVulkanDuetLayoutLayerPlacement placement, [maskInfo] mask and
    // debugMode handling as the production path. Lets RND evaluate person
    // matte quality without video-background decoder pressure.
    //
    // Same acquire / frame fence / imageAvailable + presentReady semaphore /
    // pending AHB acquire semaphore wait / present protocol, the same
    // GPU-mask bookkeeping described on VulkanGreenScreenMaskInfo, and the
    // same post-submit bookkeeping for the single camera import (marked
    // submitted, one release sync-fd export stored on it). Invalid geometry
    // fails closed with kVulkanFailure before the swapchain is touched; any
    // later failure fails closed with no partial present. Production
    // renderDuetGreenScreenFrame / renderDuetLayoutFrame behaviour is
    // unchanged.
    // [foregroundRotation] defaults to identity, so an existing caller that
    // does not pass it observes byte-for-byte identical behavior. Same
    // contract as renderDuetGreenScreenFrame's [foregroundRotation] above.
    RenderFrameResult renderDuetGreenScreenStaticBackgroundFrame(
        void* queueHandle,
        VulkanSurfaceSwapchain& swapchain,
        VulkanHardwareBufferImports& ahbImports,
        const DuetLayoutLayer& camera,
        const VulkanGreenScreenMaskInfo& maskInfo,
        const DuetStaticBackground& background,
        const VulkanGreenScreenForegroundRotation& foregroundRotation =
            VulkanGreenScreenForegroundRotation{});

    // ANDROID-DUET-VULKAN-LAYOUT: two-layer opaque Duet layout frame (PiP /
    // split, and the green-screen terminal fallback to safe PiP): [source]
    // (decoder) is drawn first, then [camera] over it, each aspect-filled
    // into its own rect through its import's own descriptor resources and
    // the core passthrough shaders -- the same per-import-layout pipelines
    // the solo / transition paths use, so external-format YCbCr imports
    // sample correctly. Same acquire / frame fence / imageAvailable +
    // presentReady semaphore / pending AHB acquire semaphore wait /
    // release-fence export / present protocol as renderDuetGreenScreenFrame,
    // including marking both imports submitted and storing a release sync-fd
    // on each. The two per-layer pipelines are cached against (pipeline
    // layout, render pass) and rebuilt after a device idle wait only when
    // either changes. Invalid geometry (see
    // ResolveVulkanDuetLayoutLayerPlacement) fails closed with
    // kVulkanFailure before the swapchain is touched; any later failure
    // fails closed with no partial present.
    RenderFrameResult renderDuetLayoutFrame(
        void* queueHandle,
        VulkanSurfaceSwapchain& swapchain,
        VulkanHardwareBufferImports& ahbImports,
        VulkanCoreShaderModules& coreShaders,
        const DuetLayoutLayer& source,
        const DuetLayoutLayer& camera);

private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};

} // namespace render
} // namespace vanguard
