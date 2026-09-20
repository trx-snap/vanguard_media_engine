// vulkan_frame_renderer.cpp
// Phase 2O2B2: Native Vulkan Frame Execution Loop.
//
// Implements VulkanFrameRenderer helper managing frame synchronization,
// graphics pipeline caching, and frame rendering orchestration behind a PImpl.
//
// On Android (__ANDROID__):
//   - Manages VulkanFrameSynchronization and VulkanGraphicsPipeline.
//   - Executes acquire, record, submit, and present for one graphics frame.
//
// On non-Android host builds:
//   - Compiles without Vulkan SDK.
//   - initialize() returns false; renderFrame returns kUnavailable.

#include "vulkan_frame_renderer.h"
#include "vulkan_beauty_frame_renderer.h"
#include "vulkan_frame_synchronization.h"
#include "vulkan_graphics_command_recorder.h"
#include "vulkan_graphics_pipeline.h"
#include "vulkan_surface_swapchain.h"
#include "vulkan_hardware_buffer_imports.h"
#include "vulkan_overlay_frame_renderer.h"
#include "vulkan_greenscreen_frame_renderer.h"
#include "vulkan_duet_layout_frame_renderer.h"
#include "vulkan_shader_module.h"
#include "vulkan_transition_frame_renderer.h"
#include "vanguard/render/render_transform.h"

#include <algorithm>
#include <cmath>
#include <cstring>
#include <unistd.h>

#if defined(__ANDROID__)

#include <vulkan/vulkan.h>
#include <android/log.h>
#include <inttypes.h>

#define VGLOG_VFR(...) __android_log_print(ANDROID_LOG_DEBUG, "VanguardVkFrameRenderer", __VA_ARGS__)

namespace vanguard {
namespace render {

namespace {

// Portable helper: reconstruct a Vulkan non-dispatchable handle from a uint64_t
// value produced by memcpy. Safe on 32-bit and 64-bit Android ABIs.
template <typename VkHandle>
static inline VkHandle u64ToVkHandle(uint64_t v) {
    static_assert(sizeof(VkHandle) <= sizeof(uint64_t),
                  "VkHandle too large for uint64_t");
    VkHandle h{};
    // NOLINTNEXTLINE(bugprone-undefined-memory-manipulation)
    std::memcpy(&h, &v, sizeof(VkHandle));
    return h;
}

// Portable helper: encode a Vulkan non-dispatchable handle as uint64_t using
// the same representation consumed by the private WSI/import seams.
template <typename VkHandle>
static inline uint64_t vkHandleToU64(VkHandle h) {
    static_assert(sizeof(VkHandle) <= sizeof(uint64_t),
                  "VkHandle too large for uint64_t");
    uint64_t v = 0;
    // NOLINTNEXTLINE(bugprone-undefined-memory-manipulation)
    std::memcpy(&v, &h, sizeof(VkHandle));
    return v;
}

// P5-OVERLAYS-TRANS / P5-OVERLAYS-PRODUCTION-EXPORT-ROUTE-A native renderer
// integration sub-slice N2: mirrors VulkanGraphicsCommandRecorder::
// recordGraphicsPass's validate + record body (vulkan_graphics_command_
// recorder.cpp) exactly, except it never calls vkCmdEndRenderPass, so a
// caller can record additional draws (overlays) into the SAME open render
// pass before ending it -- recordCompletePass/recordGraphicsPass cannot be
// reused directly for that because they end the render pass themselves.
// commandBuffer must already be in the recording state (vkBeginCommandBuffer
// already called); this function never begins/ends the command buffer and
// never ends the render pass it begins.
bool recordBaseFramePassKeepOpen(const VulkanGraphicsPassParams& params) {
    if (params.commandBuffer == VK_NULL_HANDLE || params.renderPass == VK_NULL_HANDLE ||
        params.framebuffer == VK_NULL_HANDLE || params.pipelineLayout == VK_NULL_HANDLE ||
        params.descriptorSet == VK_NULL_HANDLE || params.pipeline == VK_NULL_HANDLE ||
        params.extentWidth == 0 || params.extentHeight == 0) {
        return false;
    }
    if (params.transitionSourceImage &&
        (params.sourceImage == nullptr || params.sourceImage->image == VK_NULL_HANDLE)) {
        return false;
    }
    const bool hasDestinationRect =
        params.destinationX != 0 || params.destinationY != 0 ||
        params.destinationWidth != 0 || params.destinationHeight != 0;
    if (hasDestinationRect) {
        if (params.destinationWidth == 0 || params.destinationHeight == 0 ||
            params.destinationX < 0 || params.destinationY < 0) {
            return false;
        }
        const uint64_t right =
            static_cast<uint64_t>(params.destinationX) + static_cast<uint64_t>(params.destinationWidth);
        const uint64_t bottom =
            static_cast<uint64_t>(params.destinationY) + static_cast<uint64_t>(params.destinationHeight);
        if (right > params.extentWidth || bottom > params.extentHeight) {
            return false;
        }
    }

    if (params.transitionSourceImage) {
        params.sourceImage->recordLayoutTransition(
            params.commandBuffer,
            params.sourceOldLayout,
            params.sourceNewLayout,
            params.srcStageMask,
            params.dstStageMask,
            params.srcAccessMask,
            params.dstAccessMask,
            params.srcQueueFamilyIndex,
            params.dstQueueFamilyIndex);
    }

    VkClearValue clearValue{};
    clearValue.color = params.clearColor;

    VkRenderPassBeginInfo renderPassBeginInfo{};
    renderPassBeginInfo.sType = VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO;
    renderPassBeginInfo.pNext = nullptr;
    renderPassBeginInfo.renderPass = params.renderPass;
    renderPassBeginInfo.framebuffer = params.framebuffer;
    renderPassBeginInfo.renderArea.offset = {0, 0};
    renderPassBeginInfo.renderArea.extent = {params.extentWidth, params.extentHeight};
    renderPassBeginInfo.clearValueCount = 1;
    renderPassBeginInfo.pClearValues = &clearValue;

    vkCmdBeginRenderPass(params.commandBuffer, &renderPassBeginInfo, VK_SUBPASS_CONTENTS_INLINE);

    // Aspect-fit destination sub-rect: mirrors recordGraphicsPass exactly.
    const int32_t destX = hasDestinationRect ? params.destinationX : 0;
    const int32_t destY = hasDestinationRect ? params.destinationY : 0;
    const uint32_t destWidth = hasDestinationRect ? params.destinationWidth : params.extentWidth;
    const uint32_t destHeight = hasDestinationRect ? params.destinationHeight : params.extentHeight;

    VkViewport viewport{};
    viewport.x = static_cast<float>(destX);
    viewport.y = static_cast<float>(destY);
    viewport.width = static_cast<float>(destWidth);
    viewport.height = static_cast<float>(destHeight);
    viewport.minDepth = 0.0f;
    viewport.maxDepth = 1.0f;
    vkCmdSetViewport(params.commandBuffer, 0, 1, &viewport);

    VkRect2D scissor{};
    scissor.offset = {destX, destY};
    scissor.extent = {destWidth, destHeight};
    vkCmdSetScissor(params.commandBuffer, 0, 1, &scissor);

    vkCmdBindPipeline(params.commandBuffer, VK_PIPELINE_BIND_POINT_GRAPHICS, params.pipeline);

    vkCmdBindDescriptorSets(
        params.commandBuffer,
        VK_PIPELINE_BIND_POINT_GRAPHICS,
        params.pipelineLayout,
        0,
        1,
        &params.descriptorSet,
        0,
        nullptr);

    vkCmdPushConstants(
        params.commandBuffer,
        params.pipelineLayout,
        VK_SHADER_STAGE_VERTEX_BIT | VK_SHADER_STAGE_FRAGMENT_BIT,
        0,
        sizeof(params.pushConstants),
        &params.pushConstants);

    vkCmdDraw(params.commandBuffer, 3, 1, 0, 0);

    return true; // Render pass intentionally left open for the caller to append draws.
}

// P5-OVERLAYS-TRANS / P5-OVERLAYS-PRODUCTION-EXPORT-ROUTE-A native renderer
// integration sub-slice N2 correction 1: mirrors VulkanOverlayFrameRenderer::
// recordOverlayDraws's own pre-Vulkan caller-data validation
// (vulkan_overlay_frame_renderer.cpp: DrawFieldsFinite / DrawScissorValid and
// the per-draw imageViewHandle/samplerHandle/opacity checks) exactly, but
// runs here BEFORE the swapchain is even acquired and before
// recordBaseFramePassKeepOpen begins the command buffer / opens the render
// pass -- not just before recordOverlayDraws is reached with the base frame's
// render pass already open. This is intentional duplication: it lets invalid
// caller-supplied overlay data fail closed without ever touching the
// swapchain or base frame, while recordOverlayDraws keeps its own defense in
// depth for direct callers. draws must be non-null and overlayCount > 0 (the
// overlayCount == 0 no-op and the null-draws-with-nonzero-count case are
// both handled by the caller before this is reached).
bool overlayFrameDrawsValid(const VulkanOverlayFrameDraw* draws,
                             uint32_t overlayCount,
                             uint32_t canvasWidth,
                             uint32_t canvasHeight) {
    if (draws == nullptr || canvasWidth == 0 || canvasHeight == 0) {
        return false;
    }
    for (uint32_t i = 0; i < overlayCount; ++i) {
        const VulkanOverlayFrameDraw& d = draws[i];
        if (d.imageViewHandle == 0 || d.samplerHandle == 0) {
            return false;
        }
        for (int j = 0; j < 4; ++j) {
            if (!std::isfinite(d.uvRow0[j]) || !std::isfinite(d.uvRow1[j])) {
                return false;
            }
        }
        if (!std::isfinite(d.opacity) || d.opacity < 0.0f || d.opacity > 1.0f) {
            return false;
        }
        if (d.scissorWidth == 0 || d.scissorHeight == 0) {
            return false;
        }
        if (d.scissorX < 0 || d.scissorY < 0) {
            return false;
        }
        const uint64_t right =
            static_cast<uint64_t>(d.scissorX) + static_cast<uint64_t>(d.scissorWidth);
        const uint64_t bottom =
            static_cast<uint64_t>(d.scissorY) + static_cast<uint64_t>(d.scissorHeight);
        if (right > static_cast<uint64_t>(canvasWidth) ||
            bottom > static_cast<uint64_t>(canvasHeight)) {
            return false;
        }
    }
    return true;
}

// P5-OVERLAYS-TRANS / P5-OVERLAYS-PRODUCTION-EXPORT-ROUTE-A native renderer
// integration sub-slice N2 correction 1: best-effort close of the base
// frame's already-open render pass and already-recording command buffer on a
// failure path that must never submit or present -- used only when
// recordOverlayDraws() fails AFTER recordBaseFramePassKeepOpen has already
// begun the command buffer and opened the render pass (e.g. a descriptor
// pool allocation failure), since overlayFrameDrawsValid() above has already
// ruled out invalid caller data before that point. vkCmdEndRenderPass never
// fails (void); vkEndCommandBuffer's result is intentionally ignored since
// the command buffer is left in a non-recording state either way and is
// about to be reset/destroyed by failClosed() regardless.
void abandonOpenRenderPass(VkCommandBuffer commandBuffer) {
    vkCmdEndRenderPass(commandBuffer);
    vkEndCommandBuffer(commandBuffer);
}

// P5-OVERLAYS-TRANS / P5-OVERLAYS-PRODUCTION-EXPORT-ROUTE-A native renderer
// integration sub-slice N2 correction 2: best-effort close of an
// already-recording command buffer that never got as far as opening a render
// pass -- used only when recordBaseFramePassKeepOpen() itself returns false,
// which today only happens during its own validation phase (e.g. an invalid
// destination rect) before it ever calls vkCmdBeginRenderPass. Unlike
// abandonOpenRenderPass() above, this must NOT call vkCmdEndRenderPass, since
// no render pass was opened on this path. vkEndCommandBuffer's result is
// intentionally ignored since the command buffer is left in a non-recording
// state either way and is about to be reset/destroyed by failClosed()
// regardless.
void abandonRecordingCommandBuffer(VkCommandBuffer commandBuffer) {
    vkEndCommandBuffer(commandBuffer);
}

} // anonymous namespace

struct VulkanFrameRenderer::Impl {
    VkDevice device = VK_NULL_HANDLE;
    VkCommandPool commandPool = VK_NULL_HANDLE;

    std::unique_ptr<VulkanFrameSynchronization> frameSync;
    std::unique_ptr<VulkanGraphicsPipeline> graphicsPipeline;

    VkPipelineLayout activePipelineLayout = VK_NULL_HANDLE;
    uint64_t activeRenderPassHandle = 0;
    uint32_t currentFrameIndex = 0;
    bool initialized = false;

    // Phase 2P1: diagnostic release-semaphore export via vkGetSemaphoreFdKHR.
    // Null if VK_KHR_external_semaphore_fd is unavailable; non-null logs but
    // does not fail initialization.
    PFN_vkGetSemaphoreFdKHR pfnGetSemaphoreFd = nullptr;

    // P5-COMPOSITOR-TRANS: per-transition-frame pipelines. Pipeline layouts
    // are per import, so these are rebuilt for every transition frame (after
    // a device idle wait) and retired only after the GPU is idle again: on
    // the next render call, failClosed(), invalidatePipeline() or shutdown().
    std::unique_ptr<VulkanGraphicsPipeline> transitionFromPipeline;
    std::unique_ptr<VulkanGraphicsPipeline> transitionToOpaquePipeline;
    VkPipeline transitionToBlendPipeline = VK_NULL_HANDLE;

    // P5-BEAUTY-V2-PRODUCTION-EXPORT-ROUTE-A: lazily constructed on the first
    // beauty-enabled renderFrame() call. Owns its own crop/placement pipeline
    // cache entirely independent of graphicsPipeline/transition* above, so
    // routine solo/transition pipeline invalidation (invalidatePipeline())
    // never touches it and beauty frames never churn the solo pipeline cache.
    std::unique_ptr<VulkanBeautyFrameRenderer> beautyRenderer;

    // P5-BEAUTY-V2-TRANSITION-COMP: two DISTINCT transition-path beauty
    // renderer instances (one for the "from" layer, one for "to"), lazily
    // constructed on the first beauty-enabled renderTransitionFrame() call.
    // A single shared instance would alias slot.beautified between the two
    // layers whenever both share the same (cropWidth, cropHeight) geometry
    // (findOrCreateGeometry keys purely on crop size, not layer identity),
    // since each layer's crop -> ... -> composite sequence writes into the
    // SAME per-geometry beautified image for that frame slot. Entirely
    // independent of [beautyRenderer] above (the solo path) and of each
    // other's caches.
    std::unique_ptr<VulkanBeautyFrameRenderer> beautyRendererFrom;
    std::unique_ptr<VulkanBeautyFrameRenderer> beautyRendererTo;

    // P5-OVERLAYS-TRANS / P5-OVERLAYS-PRODUCTION-EXPORT-ROUTE-A native
    // renderer integration sub-slice N2: lazily constructed on the first
    // overlay-enabled renderFrame() call. Unlike beautyRenderer above, its
    // render-pass-bound pipeline is built against the SAME swapchain render
    // pass as graphicsPipeline (the overlay draws are recorded into the base
    // frame's own render pass, not a separate one), so it is invalidated in
    // lockstep with graphicsPipeline by the routine invalidatePipeline()
    // below rather than surviving until shutdown()/failClosed() like
    // beauty's separately-cached placement pipeline. Its descriptor set
    // layout / pipeline layout / descriptor pool are still destroyed only on
    // shutdown()/failClosed() (see shutdownOverlay() below).
    std::unique_ptr<VulkanOverlayFrameRenderer> overlayRenderer;
    std::unique_ptr<VulkanGreenScreenFrameRenderer> greenScreenRenderer;

    // ANDROID-DUET-VULKAN-LAYOUT: the two per-layer opaque pipelines of the
    // Duet layout frame, cached against the (per-import pipeline layout,
    // render pass) pair each was built for. Unlike the transition pipelines
    // above they are NOT rebuilt per frame: the AHB import table shares one
    // pipeline layout per external-format conversion configuration, so the
    // decoder and camera layouts are stable across frames and a rebuild only
    // happens on the first layout frame, after a swapchain re-attach, or if
    // a producer's format changes. Destroyed (after the caller's device idle
    // wait) by invalidateDuetLayoutPipelines() / invalidatePipeline().
    std::unique_ptr<VulkanGraphicsPipeline> duetLayoutSourcePipeline;
    std::unique_ptr<VulkanGraphicsPipeline> duetLayoutCameraPipeline;
    VkPipelineLayout duetLayoutSourceLayout = VK_NULL_HANDLE;
    VkPipelineLayout duetLayoutCameraLayout = VK_NULL_HANDLE;
    uint64_t duetLayoutRenderPassHandle = 0;

    bool hasDuetLayoutPipelines() const {
        return duetLayoutSourcePipeline != nullptr || duetLayoutCameraPipeline != nullptr;
    }

    void invalidateDuetLayoutPipelines() {
        if (duetLayoutSourcePipeline) {
            duetLayoutSourcePipeline->destroy(device);
            duetLayoutSourcePipeline.reset();
        }
        if (duetLayoutCameraPipeline) {
            duetLayoutCameraPipeline->destroy(device);
            duetLayoutCameraPipeline.reset();
        }
        duetLayoutSourceLayout = VK_NULL_HANDLE;
        duetLayoutCameraLayout = VK_NULL_HANDLE;
        duetLayoutRenderPassHandle = 0;
    }

    // ANDROID-DUET-VULKAN-LAYOUT / ANDROID-DUET-VULKAN-GREENSCREEN-VISUAL:
    // (re)builds the two per-layer opaque Duet pipelines when the cached
    // (source layout, camera layout, render pass) key differs. Shared by the
    // layout and green-screen paths -- the latter draws only the source
    // layer through it, but keeping one key for both means a green-screen
    // <-> layout toggle never churns the pair. The previous pair may still be
    // in flight on the other frame slot, so the device is idled before
    // destroying it. Returns false (with the pair invalidated) on failure.
    bool ensureDuetLayoutPipelines(VkPipelineLayout sourceLayout,
                                   VkPipelineLayout cameraLayout,
                                   uint64_t renderPassHandle,
                                   VkRenderPass renderPass,
                                   VulkanCoreShaderModules& coreShaders) {
        const bool pipelinesValid =
            duetLayoutSourcePipeline && duetLayoutSourcePipeline->isValid() &&
            duetLayoutCameraPipeline && duetLayoutCameraPipeline->isValid();
        const bool mismatch =
            !pipelinesValid ||
            duetLayoutSourceLayout != sourceLayout ||
            duetLayoutCameraLayout != cameraLayout ||
            duetLayoutRenderPassHandle != renderPassHandle;
        if (!mismatch) {
            return true;
        }
        if (vkDeviceWaitIdle(device) != VK_SUCCESS) {
            return false;
        }
        invalidateDuetLayoutPipelines();
        duetLayoutSourcePipeline = std::make_unique<VulkanGraphicsPipeline>();
        if (!duetLayoutSourcePipeline->create(device, sourceLayout, renderPass,
                                              coreShaders.vertex.get(),
                                              coreShaders.fragment.get())) {
            invalidateDuetLayoutPipelines();
            return false;
        }
        duetLayoutCameraPipeline = std::make_unique<VulkanGraphicsPipeline>();
        if (!duetLayoutCameraPipeline->create(device, cameraLayout, renderPass,
                                              coreShaders.vertex.get(),
                                              coreShaders.fragment.get())) {
            invalidateDuetLayoutPipelines();
            return false;
        }
        duetLayoutSourceLayout = sourceLayout;
        duetLayoutCameraLayout = cameraLayout;
        duetLayoutRenderPassHandle = renderPassHandle;
        return true;
    }

    // ANDROID-DUET-VULKAN-GREENSCREEN-VISUAL: one-shot structured log of the
    // first successfully submitted green-screen frame's geometry / mask
    // source, for physical-smoke log analysis.
    bool greenScreenFirstFrameLogged = false;

    // ANDROID-DUET-VULKAN-GREENSCREEN-STATIC-BACKGROUND: one-shot structured
    // log of the first successfully submitted camera-only static-background
    // green-screen frame (RND diagnostic), independent of the flag above.
    bool greenScreenStaticBackgroundFirstFrameLogged = false;

    // Torn down only on shutdown()/failClosed() (never from the routine
    // invalidatePipeline() hot path) so beauty's cached geometry/pipelines
    // survive ordinary per-frame pipeline-layout churn.
    void shutdownBeauty() {
        if (beautyRenderer) {
            beautyRenderer->shutdown(device);
            beautyRenderer.reset();
        }
        if (beautyRendererFrom) {
            beautyRendererFrom->shutdown(device);
            beautyRendererFrom.reset();
        }
        if (beautyRendererTo) {
            beautyRendererTo->shutdown(device);
            beautyRendererTo.reset();
        }
    }

    // Torn down only on shutdown()/failClosed(), mirroring shutdownBeauty()
    // above; the render-pass-bound pipeline piece is already invalidated in
    // lockstep with graphicsPipeline by invalidatePipeline() below, so this
    // only needs to run once more per full teardown to release the
    // remaining cached descriptor objects.
    void shutdownOverlay() {
        if (overlayRenderer) {
            overlayRenderer->shutdown(device);
            overlayRenderer.reset();
        }
    }

    void shutdownGreenScreen() {
        if (greenScreenRenderer) {
            greenScreenRenderer->shutdown(device);
            greenScreenRenderer.reset();
        }
    }

    bool hasTransitionPipelines() const {
        return transitionFromPipeline != nullptr ||
               transitionToOpaquePipeline != nullptr ||
               transitionToBlendPipeline != VK_NULL_HANDLE;
    }

    void invalidateTransitionPipelines() {
        if (transitionFromPipeline) {
            transitionFromPipeline->destroy(device);
            transitionFromPipeline.reset();
        }
        if (transitionToOpaquePipeline) {
            transitionToOpaquePipeline->destroy(device);
            transitionToOpaquePipeline.reset();
        }
        if (transitionToBlendPipeline != VK_NULL_HANDLE) {
            if (device != VK_NULL_HANDLE) {
                vkDestroyPipeline(device, transitionToBlendPipeline, nullptr);
            }
            transitionToBlendPipeline = VK_NULL_HANDLE;
        }
    }

    void invalidatePipeline() {
        if (graphicsPipeline) {
            graphicsPipeline->destroy(device);
            graphicsPipeline.reset();
        }
        activePipelineLayout = VK_NULL_HANDLE;
        activeRenderPassHandle = 0;
        invalidateTransitionPipelines();
        invalidateDuetLayoutPipelines();
        // The overlay helper's cached pipeline is built against the same
        // render pass as graphicsPipeline above, so it must be invalidated
        // here too rather than left dangling until shutdown().
        if (overlayRenderer) {
            overlayRenderer->invalidate(device);
        }
        if (greenScreenRenderer) {
            greenScreenRenderer->invalidate(device);
        }
    }

    // Phase 2P2: failClosed receives ahbImports so it can drainAllRetired()
    // after vkDeviceWaitIdle and before destroying sync/swapchain/pipeline.
    RenderFrameResult failClosed(VulkanSurfaceSwapchain& swapchain,
                                 VulkanHardwareBufferImports& ahbImports,
                                 RenderFrameResult result) {
        if (device != VK_NULL_HANDLE) {
            vkDeviceWaitIdle(device);
        }
        // Phase 2P2: Drain all retired imports; GPU is now idle.
        ahbImports.drainAllRetired();
        if (frameSync) {
            frameSync->shutdown(device, commandPool);
            frameSync.reset();
        }
        swapchain.detach();
        invalidatePipeline();
        // The swapchain's render pass (destroyed by swapchain.detach() above)
        // may be referenced by beauty's cached placement pipeline; tear the
        // whole beauty cache down rather than leave it dangling.
        shutdownBeauty();
        // The overlay helper's pipeline was already invalidated above (see
        // invalidatePipeline()); this releases its remaining cached
        // descriptor objects while device is still valid.
        shutdownOverlay();
        shutdownGreenScreen();
        pfnGetSemaphoreFd = nullptr; // fail-closed: clear export capability
        initialized = false;
        currentFrameIndex = 0;
        return result;
    }
};

VulkanFrameRenderer::VulkanFrameRenderer()
    : impl_(std::make_unique<Impl>()) {}

VulkanFrameRenderer::~VulkanFrameRenderer() {
    shutdown();
}

bool VulkanFrameRenderer::initialize(void* deviceHandle,
                                     uint64_t commandPoolHandle,
                                     uint32_t frameCount) {
    if (!impl_) return false;
    if (impl_->initialized) {
        return true;
    }
    if (deviceHandle == nullptr || commandPoolHandle == 0) {
        VGLOG_VFR("initialize failed: null device or command pool handle");
        return false;
    }

    VkDevice dev = static_cast<VkDevice>(deviceHandle);
    VkCommandPool pool = u64ToVkHandle<VkCommandPool>(commandPoolHandle);

    impl_->device = dev;
    impl_->commandPool = pool;
    impl_->frameSync = std::make_unique<VulkanFrameSynchronization>();

    if (!impl_->frameSync->initialize(dev, pool, frameCount)) {
        VGLOG_VFR("VulkanFrameSynchronization initialization failed");
        impl_->frameSync.reset();
        impl_->device = VK_NULL_HANDLE;
        impl_->commandPool = VK_NULL_HANDLE;
        impl_->initialized = false;
        return false;
    }

    impl_->graphicsPipeline.reset();
    impl_->activePipelineLayout = VK_NULL_HANDLE;
    impl_->activeRenderPassHandle = 0;
    impl_->currentFrameIndex = 0;

    // Phase 2P1: Resolve vkGetSemaphoreFdKHR for diagnostic release-semaphore export.
    // A null return is diagnostic (logged) but does not fail initialization;
    // the export path will safely leave the stored FD at -1.
    impl_->pfnGetSemaphoreFd = reinterpret_cast<PFN_vkGetSemaphoreFdKHR>(
        vkGetDeviceProcAddr(dev, "vkGetSemaphoreFdKHR"));
    if (!impl_->pfnGetSemaphoreFd) {
        VGLOG_VFR("vkGetSemaphoreFdKHR not resolved; release-semaphore export unavailable");
    }

    impl_->initialized = true;

    VGLOG_VFR("VulkanFrameRenderer initialized with %u frames in flight", frameCount);
    return true;
}

void VulkanFrameRenderer::shutdown() {
    if (!impl_) return;
    Impl& s = *impl_;
    if (!s.initialized && s.device == VK_NULL_HANDLE) {
        return;
    }

    s.invalidatePipeline();
    // P5-BEAUTY-V2-PRODUCTION-EXPORT-ROUTE-A: release cached beauty resources
    // while s.device is still valid, before the device itself is torn down
    // by the owning VulkanBackend.
    s.shutdownBeauty();
    // P5-OVERLAYS-TRANS / P5-OVERLAYS-PRODUCTION-EXPORT-ROUTE-A: release
    // cached overlay resources while s.device is still valid, same rationale
    // as shutdownBeauty() above.
    s.shutdownOverlay();
    s.shutdownGreenScreen();

    if (s.frameSync) {
        s.frameSync->shutdown(s.device, s.commandPool);
        s.frameSync.reset();
    }

    s.device = VK_NULL_HANDLE;
    s.commandPool = VK_NULL_HANDLE;
    s.currentFrameIndex = 0;
    s.pfnGetSemaphoreFd = nullptr;
    s.initialized = false;

    VGLOG_VFR("VulkanFrameRenderer shut down");
}

bool VulkanFrameRenderer::isInitialized() const {
    return impl_ && impl_->initialized;
}

void VulkanFrameRenderer::invalidatePipeline() {
    if (impl_) {
        impl_->invalidatePipeline();
    }
}

void VulkanFrameRenderer::waitAllFramesIdle() {
    if (!impl_ || impl_->device == VK_NULL_HANDLE) return;
    vkDeviceWaitIdle(impl_->device);
}

// ---------------------------------------------------------------------------
// Phase 4B2C: renderFrame — identity path delegates to transform overload.
// Passes VideoFrameTransform{} (rotationDegrees = 0) which resolves to the
// identity push constants already set as defaults in VulkanGraphicsPassParams.
// The transform overload below is the single authoritative render loop.
// ---------------------------------------------------------------------------

RenderFrameResult VulkanFrameRenderer::renderFrame(
    void* queueHandle,
    VulkanSurfaceSwapchain& swapchain,
    VulkanHardwareBufferImports& ahbImports,
    VulkanCoreShaderModules& coreShaders,
    HardwareBufferHandle handle) {
    return renderFrame(queueHandle, swapchain, ahbImports, coreShaders,
                       handle, VideoFrameTransform{});
}

RenderFrameResult VulkanFrameRenderer::renderFrame(
    void* queueHandle,
    VulkanSurfaceSwapchain& swapchain,
    VulkanHardwareBufferImports& ahbImports,
    VulkanCoreShaderModules& coreShaders,
    HardwareBufferHandle handle,
    const VideoFrameTransform& transform) {
    if (!impl_ || !impl_->initialized) {
        return RenderFrameResult::kBackendNotInitialized;
    }
    Impl& s = *impl_;
    if (queueHandle == nullptr || s.device == VK_NULL_HANDLE ||
        s.commandPool == VK_NULL_HANDLE) {
        return RenderFrameResult::kVulkanFailure;
    }
    if (!swapchain.hasSurface()) {
        return RenderFrameResult::kNoSurface;
    }
    const VulkanHardwareBufferImage* srcImage = ahbImports.getImage(handle);
    if (!ahbImports.hasBuffer(handle) || srcImage == nullptr) {
        return RenderFrameResult::kInvalidBufferHandle;
    }
    if (srcImage->image == VK_NULL_HANDLE ||
        coreShaders.vertex.get() == VK_NULL_HANDLE ||
        coreShaders.fragment.get() == VK_NULL_HANDLE ||
        !s.frameSync || !s.frameSync->isInitialized()) {
        return RenderFrameResult::kVulkanFailure;
    }

    const uint32_t frameCount = s.frameSync->getFrameCount();
    if (frameCount == 0 || s.currentFrameIndex >= frameCount) {
        return RenderFrameResult::kVulkanFailure;
    }
    const VulkanFrameSyncResources* frame =
        s.frameSync->getFrame(s.currentFrameIndex);
    if (frame == nullptr || frame->commandBuffer == VK_NULL_HANDLE ||
        frame->imageAvailableSemaphore == VK_NULL_HANDLE ||
        frame->inFlightFence == VK_NULL_HANDLE) {
        return RenderFrameResult::kVulkanFailure;
    }

    const uint64_t renderPassHandle = swapchain.getRenderPassHandle();
    const uint32_t extentWidth = swapchain.getExtentWidth();
    const uint32_t extentHeight = swapchain.getExtentHeight();
    VkPipelineLayout pipelineLayout =
        srcImage->descriptorResources.pipelineLayout;
    VkDescriptorSet descriptorSet = srcImage->descriptorResources.descriptorSet;
    if (renderPassHandle == 0 || extentWidth == 0 || extentHeight == 0 ||
        pipelineLayout == VK_NULL_HANDLE || descriptorSet == VK_NULL_HANDLE) {
        return RenderFrameResult::kVulkanFailure;
    }
    const VkRenderPass renderPass =
        u64ToVkHandle<VkRenderPass>(renderPassHandle);

    const bool hasActivePipeline =
        s.graphicsPipeline && s.graphicsPipeline->isValid();
    const bool pipelineCompatibilityMismatch =
        hasActivePipeline &&
        (s.activePipelineLayout != pipelineLayout ||
         s.activeRenderPassHandle != renderPassHandle);
    const bool pipelineMismatch =
        !hasActivePipeline || pipelineCompatibilityMismatch;
    if (pipelineMismatch) {
        // A previous transition, green-screen or Duet layout pipeline may
        // still be in flight on the other frame slot; they are destroyed by
        // invalidatePipeline() below, so the device must be idle first in
        // that case too.
        if ((pipelineCompatibilityMismatch || s.hasTransitionPipelines() ||
             s.hasDuetLayoutPipelines() || s.greenScreenRenderer != nullptr) &&
            vkDeviceWaitIdle(s.device) != VK_SUCCESS) {
            return RenderFrameResult::kVulkanFailure;
        }
        s.invalidatePipeline();
        s.graphicsPipeline = std::make_unique<VulkanGraphicsPipeline>();
        if (!s.graphicsPipeline->create(
                s.device,
                pipelineLayout,
                renderPass,
                coreShaders.vertex.get(),
                coreShaders.fragment.get())) {
            s.invalidatePipeline();
            return RenderFrameResult::kVulkanFailure;
        }
        s.activePipelineLayout = pipelineLayout;
        s.activeRenderPassHandle = renderPassHandle;
    }

    if (!s.frameSync->waitForFrameFence(s.currentFrameIndex)) {
        return RenderFrameResult::kVulkanFailure;
    }
    ahbImports.drainRetiredForFrame(s.currentFrameIndex);

    uint32_t imageIndex = 0;
    const SwapchainResult acquireResult = swapchain.acquireNextImage(
        vkHandleToU64(frame->imageAvailableSemaphore),
        0,
        &imageIndex,
        UINT64_MAX);
    switch (acquireResult) {
        case SwapchainResult::kSuccess:
        case SwapchainResult::kSuboptimal:
            break;
        case SwapchainResult::kOutOfDate:
            return RenderFrameResult::kOutOfDate;
        case SwapchainResult::kSurfaceLost:
            return RenderFrameResult::kSurfaceLost;
        case SwapchainResult::kDeviceLost:
            return RenderFrameResult::kDeviceLost;
        case SwapchainResult::kError:
            return RenderFrameResult::kVulkanFailure;
    }

    const uint64_t framebufferHandle =
        swapchain.getFramebufferHandle(imageIndex);
    if (framebufferHandle == 0) {
        return s.failClosed(swapchain, ahbImports, RenderFrameResult::kVulkanFailure);
    }
    const VkFramebuffer framebuffer =
        u64ToVkHandle<VkFramebuffer>(framebufferHandle);

    const uint64_t presentReadySemaphoreHandle =
        swapchain.getPresentReadySemaphoreHandle(imageIndex);
    if (presentReadySemaphoreHandle == 0) {
        return s.failClosed(swapchain, ahbImports, RenderFrameResult::kVulkanFailure);
    }
    const VkSemaphore presentReadySemaphore =
        u64ToVkHandle<VkSemaphore>(presentReadySemaphoreHandle);

    if (!s.frameSync->resetCommandBuffer(s.currentFrameIndex)) {
        return s.failClosed(swapchain, ahbImports, RenderFrameResult::kVulkanFailure);
    }

    const VkImageLayout currentLayout =
        static_cast<VkImageLayout>(ahbImports.getImageLayout(handle));

    VulkanGraphicsPassParams passParams{};
    passParams.commandBuffer = frame->commandBuffer;
    passParams.renderPass = renderPass;
    passParams.framebuffer = framebuffer;
    passParams.extentWidth = extentWidth;
    passParams.extentHeight = extentHeight;
    passParams.pipelineLayout = pipelineLayout;
    passParams.descriptorSet = descriptorSet;
    passParams.pipeline = s.graphicsPipeline->get();
    passParams.sourceImage = srcImage;
    // Phase 10: build combined UV transform + color matrix push constants
    // from transform (identity color matrix when transform.colorMatrixEnabled
    // is false).
    passParams.pushConstants = makeVideoTransformFullPushConstants(transform);
    // Aspect-fit destination rect: copy through as-is. A default (all-zero)
    // rect leaves passParams.destination* at their own zero defaults, which
    // VulkanGraphicsCommandRecorder treats as "full extent" (pre-existing
    // behavior); a non-default rect is validated for non-emptiness and
    // extent bounds by the recorder before it is used.
    passParams.destinationX = transform.destinationRect.x;
    passParams.destinationY = transform.destinationRect.y;
    passParams.destinationWidth = static_cast<uint32_t>(transform.destinationRect.width);
    passParams.destinationHeight = static_cast<uint32_t>(transform.destinationRect.height);
    if (currentLayout == VK_IMAGE_LAYOUT_UNDEFINED) {
        passParams.transitionSourceImage = true;
        passParams.sourceOldLayout = VK_IMAGE_LAYOUT_UNDEFINED;
        passParams.sourceNewLayout = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
    } else {
        passParams.transitionSourceImage = false;
        passParams.sourceOldLayout = currentLayout;
        passParams.sourceNewLayout = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
    }
    if (!VulkanGraphicsCommandRecorder::recordCompletePass(passParams)) {
        return s.failClosed(swapchain, ahbImports, RenderFrameResult::kVulkanFailure);
    }

    if (!s.frameSync->resetFrameFence(s.currentFrameIndex)) {
        return s.failClosed(swapchain, ahbImports, RenderFrameResult::kVulkanFailure);
    }

    VkSemaphore waitSemaphores[2] = {
        frame->imageAvailableSemaphore,
        VK_NULL_HANDLE,
    };
    VkPipelineStageFlags waitStages[2] = {
        VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
        VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT,
    };
    uint32_t waitSemaphoreCount = 1;
    const uint64_t pendingAcquireSemaphoreHandle =
        ahbImports.getPendingAcquireSemaphoreHandle(handle);
    if (pendingAcquireSemaphoreHandle != 0) {
        waitSemaphores[waitSemaphoreCount++] =
            u64ToVkHandle<VkSemaphore>(pendingAcquireSemaphoreHandle);
    }

    const bool canExportRelease =
        (frame->releaseFenceSemaphore != VK_NULL_HANDLE) && (s.pfnGetSemaphoreFd != nullptr);

    VkSemaphore signalSemaphores[2] = {
        presentReadySemaphore,
        VK_NULL_HANDLE,
    };
    uint32_t signalSemaphoreCount = 1;
    if (canExportRelease) {
        signalSemaphores[signalSemaphoreCount++] = frame->releaseFenceSemaphore;
    }

    VkSubmitInfo submitInfo{};
    submitInfo.sType = VK_STRUCTURE_TYPE_SUBMIT_INFO;
    submitInfo.waitSemaphoreCount = waitSemaphoreCount;
    submitInfo.pWaitSemaphores = waitSemaphores;
    submitInfo.pWaitDstStageMask = waitStages;
    submitInfo.commandBufferCount = 1;
    submitInfo.pCommandBuffers = &frame->commandBuffer;
    submitInfo.signalSemaphoreCount = signalSemaphoreCount;
    submitInfo.pSignalSemaphores = signalSemaphores;

    const VkQueue queue = static_cast<VkQueue>(queueHandle);
    const VkResult submitResult =
        vkQueueSubmit(queue, 1, &submitInfo, frame->inFlightFence);
    if (submitResult != VK_SUCCESS) {
        const RenderFrameResult result =
            (submitResult == VK_ERROR_DEVICE_LOST)
                ? RenderFrameResult::kDeviceLost
                : RenderFrameResult::kVulkanFailure;
        return s.failClosed(swapchain, ahbImports, result);
    }

    // Phase 2P2: Record the frame slot for this submission so that
    // releaseBuffer() can tag the retired record for deferred destruction.
    // markBufferSubmitted updates lastSubmittedFrameSlot in the active record.
    // Failure here is fatal: fail closed so the record is not left with a
    // stale slot while resources may be in flight.
    if (!ahbImports.markBufferSubmitted(handle, s.currentFrameIndex)) {
        VGLOG_VFR("markBufferSubmitted failed for handle=%" PRIu64 "; failing closed",
                  static_cast<uint64_t>(handle));
        return s.failClosed(swapchain, ahbImports, RenderFrameResult::kVulkanFailure);
    }

    // Phase 2P1: Export diagnostic release sync-fd via the dedicated
    // releaseFenceSemaphore immediately after successful vkQueueSubmit.
    // VK_SUCCESS + fd>=0: app-owned fd transferred to import record.
    // VK_SUCCESS + fd==-1: valid empty sync-fd; clears any older stored FD.
    // Export failure after signaling: close any fd>=0, clear stored FD, log,
    // and failClosed so vkDeviceWaitIdle precedes semaphore teardown.
    // No releaseFenceSemaphore or no function pointer: clear stale stored FD
    // to -1. Never export/alter inFlightFence beyond wait/reset/submit tracking.
    {
        if (canExportRelease) {
            int exportedFd = -1;
            VkSemaphoreGetFdInfoKHR semGetFdInfo{};
            semGetFdInfo.sType      = VK_STRUCTURE_TYPE_SEMAPHORE_GET_FD_INFO_KHR;
            semGetFdInfo.pNext      = nullptr;
            semGetFdInfo.semaphore  = frame->releaseFenceSemaphore;
            semGetFdInfo.handleType = VK_EXTERNAL_SEMAPHORE_HANDLE_TYPE_SYNC_FD_BIT;
            const VkResult exportResult =
                s.pfnGetSemaphoreFd(s.device, &semGetFdInfo, &exportedFd);
            if (exportResult != VK_SUCCESS) {
                VGLOG_VFR("vkGetSemaphoreFdKHR failed: %d; clearing stored release fd",
                          static_cast<int>(exportResult));
                if (exportedFd >= 0) {
                    ::close(exportedFd);
                }
                // Clear stale stored FD and fail closed: vkDeviceWaitIdle
                // must precede semaphore teardown after a failed export.
                ahbImports.setLatestReleaseFenceFd(handle, -1);
                return s.failClosed(swapchain, ahbImports, RenderFrameResult::kVulkanFailure);
            }
            // Transfer ownership to import record (including -1 to clear stale).
            // setLatestReleaseFenceFd closes any prior valid FD on the record;
            // on invalid handle it closes exportedFd if >=0. Either way no leak.
            ahbImports.setLatestReleaseFenceFd(handle, exportedFd);
        } else {
            // releaseFenceSemaphore not available or function pointer not resolved:
            // clear any stale stored release FD so callers see a safe sentinel.
            ahbImports.setLatestReleaseFenceFd(handle, -1);
        }
    }

    if (pendingAcquireSemaphoreHandle != 0 &&
        !ahbImports.markAcquireSemaphoreSubmitted(handle)) {
        return s.failClosed(swapchain, ahbImports, RenderFrameResult::kVulkanFailure);
    }

    // Phase 2O2B4: Mark layout as SHADER_READ_ONLY_OPTIMAL only after vkQueueSubmit returns VK_SUCCESS.
    if (!ahbImports.setImageLayout(handle, static_cast<uint32_t>(VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL))) {
        return s.failClosed(swapchain, ahbImports, RenderFrameResult::kVulkanFailure);
    }

    const SwapchainResult presentResult = swapchain.presentImage(
        queueHandle,
        presentReadySemaphoreHandle,
        imageIndex);

    s.currentFrameIndex = (s.currentFrameIndex + 1) % frameCount;

    // Solo transform playback: GPU-to-decoder release synchronization is NOT
    // done here. Blocking on the just-submitted slot's inFlightFence after
    // present serialized every frame behind its own GPU completion and cost
    // playback cadence (periodic 60-200 ms gaps). Instead, the release sync-fd
    // exported from releaseFenceSemaphore above (stored on the import record
    // and handed out by releaseBuffer()) is the ownership boundary: the Android
    // caller must keep the decoded Image alive until that fd signals, and only
    // then return the buffer to MediaCodec. The normal frame-slot fence wait at
    // the top of this function still bounds CPU/GPU frames in flight.

    switch (presentResult) {
        case SwapchainResult::kSuccess:
            return acquireResult == SwapchainResult::kSuboptimal
                ? RenderFrameResult::kSuboptimal
                : RenderFrameResult::kSuccess;
        case SwapchainResult::kSuboptimal:
            return RenderFrameResult::kSuboptimal;
        case SwapchainResult::kOutOfDate:
            return RenderFrameResult::kOutOfDate;
        case SwapchainResult::kSurfaceLost:
            return RenderFrameResult::kSurfaceLost;
        case SwapchainResult::kDeviceLost:
            return s.failClosed(swapchain, ahbImports, RenderFrameResult::kDeviceLost);
        case SwapchainResult::kError:
            return s.failClosed(swapchain, ahbImports, RenderFrameResult::kVulkanFailure);
    }

    return s.failClosed(swapchain, ahbImports, RenderFrameResult::kVulkanFailure);
}

// ---------------------------------------------------------------------------
// P5-OVERLAYS-TRANS / P5-OVERLAYS-PRODUCTION-EXPORT-ROUTE-A native renderer
// integration sub-slice N2: renderFrame with an optional set of
// already-resolved overlay draws recorded into the SAME render pass as the
// base decoded frame, immediately after it. Mirrors the transform-only
// overload above's entire acquire / frame-fence / pending-AHB-semaphore /
// release-fence-export / present protocol exactly; the only difference is
// that the base frame draw and the render pass are recorded manually here
// (via recordBaseFramePassKeepOpen above) instead of through
// VulkanGraphicsCommandRecorder::recordCompletePass, because recordCompletePass
// ends the render pass itself before overlays could be appended. When
// overlayCount == 0 this delegates directly to the transform-only overload
// with zero additional Vulkan calls, so non-overlay behavior (including the
// solo pipeline cache in s.graphicsPipeline) is completely unaffected by this
// overload's existence.
// ---------------------------------------------------------------------------

RenderFrameResult VulkanFrameRenderer::renderFrame(
    void* queueHandle,
    VulkanSurfaceSwapchain& swapchain,
    VulkanHardwareBufferImports& ahbImports,
    VulkanCoreShaderModules& coreShaders,
    HardwareBufferHandle handle,
    const VideoFrameTransform& transform,
    const VulkanOverlayFrameDraw* overlayDraws,
    uint32_t overlayCount) {
    if (overlayCount == 0) {
        return renderFrame(queueHandle, swapchain, ahbImports, coreShaders, handle, transform);
    }
    if (overlayDraws == nullptr) {
        return RenderFrameResult::kVulkanFailure;
    }
    if (!impl_ || !impl_->initialized) {
        return RenderFrameResult::kBackendNotInitialized;
    }
    Impl& s = *impl_;
    if (queueHandle == nullptr || s.device == VK_NULL_HANDLE ||
        s.commandPool == VK_NULL_HANDLE) {
        return RenderFrameResult::kVulkanFailure;
    }
    if (!swapchain.hasSurface()) {
        return RenderFrameResult::kNoSurface;
    }
    const VulkanHardwareBufferImage* srcImage = ahbImports.getImage(handle);
    if (!ahbImports.hasBuffer(handle) || srcImage == nullptr) {
        return RenderFrameResult::kInvalidBufferHandle;
    }
    if (srcImage->image == VK_NULL_HANDLE ||
        coreShaders.vertex.get() == VK_NULL_HANDLE ||
        coreShaders.fragment.get() == VK_NULL_HANDLE ||
        !s.frameSync || !s.frameSync->isInitialized()) {
        return RenderFrameResult::kVulkanFailure;
    }

    const uint32_t frameCount = s.frameSync->getFrameCount();
    if (frameCount == 0 || s.currentFrameIndex >= frameCount) {
        return RenderFrameResult::kVulkanFailure;
    }
    const VulkanFrameSyncResources* frame =
        s.frameSync->getFrame(s.currentFrameIndex);
    if (frame == nullptr || frame->commandBuffer == VK_NULL_HANDLE ||
        frame->imageAvailableSemaphore == VK_NULL_HANDLE ||
        frame->inFlightFence == VK_NULL_HANDLE) {
        return RenderFrameResult::kVulkanFailure;
    }

    const uint64_t renderPassHandle = swapchain.getRenderPassHandle();
    const uint32_t extentWidth = swapchain.getExtentWidth();
    const uint32_t extentHeight = swapchain.getExtentHeight();
    VkPipelineLayout pipelineLayout =
        srcImage->descriptorResources.pipelineLayout;
    VkDescriptorSet descriptorSet = srcImage->descriptorResources.descriptorSet;
    if (renderPassHandle == 0 || extentWidth == 0 || extentHeight == 0 ||
        pipelineLayout == VK_NULL_HANDLE || descriptorSet == VK_NULL_HANDLE) {
        return RenderFrameResult::kVulkanFailure;
    }
    const VkRenderPass renderPass =
        u64ToVkHandle<VkRenderPass>(renderPassHandle);

    // Correction 1: validate every overlay draw against the canvas extent
    // now -- before the swapchain is acquired and before any Vulkan call
    // below (pipeline (re)creation, fence wait, acquire) -- so invalid
    // caller-supplied overlay data fails closed without ever opening the
    // base frame's render pass.
    if (!overlayFrameDrawsValid(overlayDraws, overlayCount, extentWidth, extentHeight)) {
        return RenderFrameResult::kVulkanFailure;
    }

    if (!s.overlayRenderer) {
        s.overlayRenderer = std::make_unique<VulkanOverlayFrameRenderer>();
    }

    const bool hasActivePipeline =
        s.graphicsPipeline && s.graphicsPipeline->isValid();
    const bool pipelineCompatibilityMismatch =
        hasActivePipeline &&
        (s.activePipelineLayout != pipelineLayout ||
         s.activeRenderPassHandle != renderPassHandle);
    const bool pipelineMismatch =
        !hasActivePipeline || pipelineCompatibilityMismatch;
    if (pipelineMismatch) {
        // A previous transition, green-screen or Duet layout pipeline may
        // still be in flight on the other frame slot; they are destroyed by
        // invalidatePipeline() below, so the device must be idle first in
        // that case too.
        if ((pipelineCompatibilityMismatch || s.hasTransitionPipelines() ||
             s.hasDuetLayoutPipelines() || s.greenScreenRenderer != nullptr) &&
            vkDeviceWaitIdle(s.device) != VK_SUCCESS) {
            return RenderFrameResult::kVulkanFailure;
        }
        s.invalidatePipeline();
        s.graphicsPipeline = std::make_unique<VulkanGraphicsPipeline>();
        if (!s.graphicsPipeline->create(
                s.device,
                pipelineLayout,
                renderPass,
                coreShaders.vertex.get(),
                coreShaders.fragment.get())) {
            s.invalidatePipeline();
            return RenderFrameResult::kVulkanFailure;
        }
        s.activePipelineLayout = pipelineLayout;
        s.activeRenderPassHandle = renderPassHandle;
    }

    if (!s.frameSync->waitForFrameFence(s.currentFrameIndex)) {
        return RenderFrameResult::kVulkanFailure;
    }
    ahbImports.drainRetiredForFrame(s.currentFrameIndex);

    uint32_t imageIndex = 0;
    const SwapchainResult acquireResult = swapchain.acquireNextImage(
        vkHandleToU64(frame->imageAvailableSemaphore),
        0,
        &imageIndex,
        UINT64_MAX);
    switch (acquireResult) {
        case SwapchainResult::kSuccess:
        case SwapchainResult::kSuboptimal:
            break;
        case SwapchainResult::kOutOfDate:
            return RenderFrameResult::kOutOfDate;
        case SwapchainResult::kSurfaceLost:
            return RenderFrameResult::kSurfaceLost;
        case SwapchainResult::kDeviceLost:
            return RenderFrameResult::kDeviceLost;
        case SwapchainResult::kError:
            return RenderFrameResult::kVulkanFailure;
    }

    const uint64_t framebufferHandle =
        swapchain.getFramebufferHandle(imageIndex);
    if (framebufferHandle == 0) {
        return s.failClosed(swapchain, ahbImports, RenderFrameResult::kVulkanFailure);
    }
    const VkFramebuffer framebuffer =
        u64ToVkHandle<VkFramebuffer>(framebufferHandle);

    const uint64_t presentReadySemaphoreHandle =
        swapchain.getPresentReadySemaphoreHandle(imageIndex);
    if (presentReadySemaphoreHandle == 0) {
        return s.failClosed(swapchain, ahbImports, RenderFrameResult::kVulkanFailure);
    }
    const VkSemaphore presentReadySemaphore =
        u64ToVkHandle<VkSemaphore>(presentReadySemaphoreHandle);

    if (!s.frameSync->resetCommandBuffer(s.currentFrameIndex)) {
        return s.failClosed(swapchain, ahbImports, RenderFrameResult::kVulkanFailure);
    }

    const VkImageLayout currentLayout =
        static_cast<VkImageLayout>(ahbImports.getImageLayout(handle));

    VulkanGraphicsPassParams passParams{};
    passParams.commandBuffer = frame->commandBuffer;
    passParams.renderPass = renderPass;
    passParams.framebuffer = framebuffer;
    passParams.extentWidth = extentWidth;
    passParams.extentHeight = extentHeight;
    passParams.pipelineLayout = pipelineLayout;
    passParams.descriptorSet = descriptorSet;
    passParams.pipeline = s.graphicsPipeline->get();
    passParams.sourceImage = srcImage;
    passParams.pushConstants = makeVideoTransformFullPushConstants(transform);
    passParams.destinationX = transform.destinationRect.x;
    passParams.destinationY = transform.destinationRect.y;
    passParams.destinationWidth = static_cast<uint32_t>(transform.destinationRect.width);
    passParams.destinationHeight = static_cast<uint32_t>(transform.destinationRect.height);
    if (currentLayout == VK_IMAGE_LAYOUT_UNDEFINED) {
        passParams.transitionSourceImage = true;
        passParams.sourceOldLayout = VK_IMAGE_LAYOUT_UNDEFINED;
        passParams.sourceNewLayout = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
    } else {
        passParams.transitionSourceImage = false;
        passParams.sourceOldLayout = currentLayout;
        passParams.sourceNewLayout = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
    }

    VkCommandBufferBeginInfo beginInfo{};
    beginInfo.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
    if (vkBeginCommandBuffer(frame->commandBuffer, &beginInfo) != VK_SUCCESS) {
        return s.failClosed(swapchain, ahbImports, RenderFrameResult::kVulkanFailure);
    }

    if (!recordBaseFramePassKeepOpen(passParams)) {
        // vkBeginCommandBuffer already succeeded above, but
        // recordBaseFramePassKeepOpen validates its params BEFORE opening the
        // render pass, so a false return here (e.g. an invalid destination
        // rect) leaves the command buffer recording with no render pass ever
        // opened. Close it best-effort before failClosed -- never
        // vkCmdEndRenderPass on this path since none was opened.
        abandonRecordingCommandBuffer(frame->commandBuffer);
        return s.failClosed(swapchain, ahbImports, RenderFrameResult::kVulkanFailure);
    }

    std::string overlayFailureReason;
    const bool overlayOk = s.overlayRenderer->recordOverlayDraws(
        static_cast<void*>(s.device),
        static_cast<void*>(frame->commandBuffer),
        reinterpret_cast<void*>(coreShaders.vertex.get()),
        reinterpret_cast<void*>(coreShaders.fragment.get()),
        renderPassHandle,
        extentWidth,
        extentHeight,
        overlayDraws,
        overlayCount,
        &overlayFailureReason);
    if (!overlayOk) {
        VGLOG_VFR("overlay recordOverlayDraws failed: %s", overlayFailureReason.c_str());
        // recordBaseFramePassKeepOpen already began the command buffer and
        // opened the render pass above; overlayFrameDrawsValid() already
        // ruled out invalid caller data before either happened, so this is a
        // genuine resource failure (e.g. descriptor pool allocation). Close
        // the open render pass / command buffer best-effort before
        // failClosed -- never submit or present on this path.
        abandonOpenRenderPass(frame->commandBuffer);
        return s.failClosed(swapchain, ahbImports, RenderFrameResult::kVulkanFailure);
    }

    vkCmdEndRenderPass(frame->commandBuffer);
    if (vkEndCommandBuffer(frame->commandBuffer) != VK_SUCCESS) {
        return s.failClosed(swapchain, ahbImports, RenderFrameResult::kVulkanFailure);
    }

    if (!s.frameSync->resetFrameFence(s.currentFrameIndex)) {
        return s.failClosed(swapchain, ahbImports, RenderFrameResult::kVulkanFailure);
    }

    VkSemaphore waitSemaphores[2] = {
        frame->imageAvailableSemaphore,
        VK_NULL_HANDLE,
    };
    VkPipelineStageFlags waitStages[2] = {
        VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
        VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT,
    };
    uint32_t waitSemaphoreCount = 1;
    const uint64_t pendingAcquireSemaphoreHandle =
        ahbImports.getPendingAcquireSemaphoreHandle(handle);
    if (pendingAcquireSemaphoreHandle != 0) {
        waitSemaphores[waitSemaphoreCount++] =
            u64ToVkHandle<VkSemaphore>(pendingAcquireSemaphoreHandle);
    }

    const bool canExportRelease =
        (frame->releaseFenceSemaphore != VK_NULL_HANDLE) && (s.pfnGetSemaphoreFd != nullptr);

    VkSemaphore signalSemaphores[2] = {
        presentReadySemaphore,
        VK_NULL_HANDLE,
    };
    uint32_t signalSemaphoreCount = 1;
    if (canExportRelease) {
        signalSemaphores[signalSemaphoreCount++] = frame->releaseFenceSemaphore;
    }

    VkSubmitInfo submitInfo{};
    submitInfo.sType = VK_STRUCTURE_TYPE_SUBMIT_INFO;
    submitInfo.waitSemaphoreCount = waitSemaphoreCount;
    submitInfo.pWaitSemaphores = waitSemaphores;
    submitInfo.pWaitDstStageMask = waitStages;
    submitInfo.commandBufferCount = 1;
    submitInfo.pCommandBuffers = &frame->commandBuffer;
    submitInfo.signalSemaphoreCount = signalSemaphoreCount;
    submitInfo.pSignalSemaphores = signalSemaphores;

    const VkQueue queue = static_cast<VkQueue>(queueHandle);
    const VkResult submitResult =
        vkQueueSubmit(queue, 1, &submitInfo, frame->inFlightFence);
    if (submitResult != VK_SUCCESS) {
        const RenderFrameResult result =
            (submitResult == VK_ERROR_DEVICE_LOST)
                ? RenderFrameResult::kDeviceLost
                : RenderFrameResult::kVulkanFailure;
        return s.failClosed(swapchain, ahbImports, result);
    }

    if (!ahbImports.markBufferSubmitted(handle, s.currentFrameIndex)) {
        VGLOG_VFR("overlay markBufferSubmitted failed for handle=%" PRIu64 "; failing closed",
                  static_cast<uint64_t>(handle));
        return s.failClosed(swapchain, ahbImports, RenderFrameResult::kVulkanFailure);
    }

    {
        if (canExportRelease) {
            int exportedFd = -1;
            VkSemaphoreGetFdInfoKHR semGetFdInfo{};
            semGetFdInfo.sType      = VK_STRUCTURE_TYPE_SEMAPHORE_GET_FD_INFO_KHR;
            semGetFdInfo.pNext      = nullptr;
            semGetFdInfo.semaphore  = frame->releaseFenceSemaphore;
            semGetFdInfo.handleType = VK_EXTERNAL_SEMAPHORE_HANDLE_TYPE_SYNC_FD_BIT;
            const VkResult exportResult =
                s.pfnGetSemaphoreFd(s.device, &semGetFdInfo, &exportedFd);
            if (exportResult != VK_SUCCESS) {
                VGLOG_VFR("overlay vkGetSemaphoreFdKHR failed: %d; clearing stored release fd",
                          static_cast<int>(exportResult));
                if (exportedFd >= 0) {
                    ::close(exportedFd);
                }
                ahbImports.setLatestReleaseFenceFd(handle, -1);
                return s.failClosed(swapchain, ahbImports, RenderFrameResult::kVulkanFailure);
            }
            ahbImports.setLatestReleaseFenceFd(handle, exportedFd);
        } else {
            ahbImports.setLatestReleaseFenceFd(handle, -1);
        }
    }

    if (pendingAcquireSemaphoreHandle != 0 &&
        !ahbImports.markAcquireSemaphoreSubmitted(handle)) {
        return s.failClosed(swapchain, ahbImports, RenderFrameResult::kVulkanFailure);
    }

    if (!ahbImports.setImageLayout(handle, static_cast<uint32_t>(VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL))) {
        return s.failClosed(swapchain, ahbImports, RenderFrameResult::kVulkanFailure);
    }

    const SwapchainResult presentResult = swapchain.presentImage(
        queueHandle,
        presentReadySemaphoreHandle,
        imageIndex);
    s.currentFrameIndex = (s.currentFrameIndex + 1) % frameCount;

    switch (presentResult) {
        case SwapchainResult::kSuccess:
            return acquireResult == SwapchainResult::kSuboptimal
                ? RenderFrameResult::kSuboptimal
                : RenderFrameResult::kSuccess;
        case SwapchainResult::kSuboptimal:
            return RenderFrameResult::kSuboptimal;
        case SwapchainResult::kOutOfDate:
            return RenderFrameResult::kOutOfDate;
        case SwapchainResult::kSurfaceLost:
            return RenderFrameResult::kSurfaceLost;
        case SwapchainResult::kDeviceLost:
            return s.failClosed(swapchain, ahbImports, RenderFrameResult::kDeviceLost);
        case SwapchainResult::kError:
            return s.failClosed(swapchain, ahbImports, RenderFrameResult::kVulkanFailure);
    }

    return s.failClosed(swapchain, ahbImports, RenderFrameResult::kVulkanFailure);
}

// ---------------------------------------------------------------------------
// P5-BEAUTY-V2-PRODUCTION-EXPORT-ROUTE-A: renderFrame with optional Vulkan-only
// Beauty V2 pre-composite. Mirrors the transform-only overload above's entire
// acquire / frame-fence / pending-AHB-semaphore / release-fence-export /
// present protocol; the only difference is what gets recorded into the
// frame's command buffer. When beauty.enabled is false this delegates
// directly to the transform-only overload with zero additional Vulkan calls,
// so non-beauty behavior (including the solo pipeline cache in
// s.graphicsPipeline) is completely unaffected by this overload's existence.
// The beauty-enabled path never touches s.graphicsPipeline / transition*
// pipelines: VulkanBeautyFrameRenderer owns an entirely separate crop/
// placement pipeline cache.
// ---------------------------------------------------------------------------

RenderFrameResult VulkanFrameRenderer::renderFrame(
    void* queueHandle,
    void* physicalDeviceHandle,
    VulkanSurfaceSwapchain& swapchain,
    VulkanHardwareBufferImports& ahbImports,
    VulkanCoreShaderModules& coreShaders,
    HardwareBufferHandle handle,
    const VideoFrameTransform& transform,
    const VideoBeautyV2RenderParams& beauty) {
    if (!beauty.enabled) {
        return renderFrame(queueHandle, swapchain, ahbImports, coreShaders, handle, transform);
    }
    if (!impl_ || !impl_->initialized) {
        return RenderFrameResult::kBackendNotInitialized;
    }
    Impl& s = *impl_;
    if (queueHandle == nullptr || physicalDeviceHandle == nullptr ||
        s.device == VK_NULL_HANDLE || s.commandPool == VK_NULL_HANDLE) {
        return RenderFrameResult::kVulkanFailure;
    }
    if (!swapchain.hasSurface()) {
        return RenderFrameResult::kNoSurface;
    }
    const VulkanHardwareBufferImage* srcImage = ahbImports.getImage(handle);
    if (!ahbImports.hasBuffer(handle) || srcImage == nullptr) {
        return RenderFrameResult::kInvalidBufferHandle;
    }
    if (srcImage->image == VK_NULL_HANDLE ||
        coreShaders.vertex.get() == VK_NULL_HANDLE ||
        coreShaders.fragment.get() == VK_NULL_HANDLE ||
        !s.frameSync || !s.frameSync->isInitialized()) {
        return RenderFrameResult::kVulkanFailure;
    }

    const uint32_t frameCount = s.frameSync->getFrameCount();
    if (frameCount == 0 || s.currentFrameIndex >= frameCount) {
        return RenderFrameResult::kVulkanFailure;
    }
    const VulkanFrameSyncResources* frame =
        s.frameSync->getFrame(s.currentFrameIndex);
    if (frame == nullptr || frame->commandBuffer == VK_NULL_HANDLE ||
        frame->imageAvailableSemaphore == VK_NULL_HANDLE ||
        frame->inFlightFence == VK_NULL_HANDLE) {
        return RenderFrameResult::kVulkanFailure;
    }

    const uint64_t renderPassHandle = swapchain.getRenderPassHandle();
    const uint32_t extentWidth = swapchain.getExtentWidth();
    const uint32_t extentHeight = swapchain.getExtentHeight();
    if (renderPassHandle == 0 || extentWidth == 0 || extentHeight == 0) {
        return RenderFrameResult::kVulkanFailure;
    }
    const VkRenderPass renderPass = u64ToVkHandle<VkRenderPass>(renderPassHandle);

    if (!s.beautyRenderer) {
        s.beautyRenderer = std::make_unique<VulkanBeautyFrameRenderer>();
    }

    if (!s.frameSync->waitForFrameFence(s.currentFrameIndex)) {
        return RenderFrameResult::kVulkanFailure;
    }
    ahbImports.drainRetiredForFrame(s.currentFrameIndex);

    uint32_t imageIndex = 0;
    const SwapchainResult acquireResult = swapchain.acquireNextImage(
        vkHandleToU64(frame->imageAvailableSemaphore),
        0,
        &imageIndex,
        UINT64_MAX);
    switch (acquireResult) {
        case SwapchainResult::kSuccess:
        case SwapchainResult::kSuboptimal:
            break;
        case SwapchainResult::kOutOfDate:
            return RenderFrameResult::kOutOfDate;
        case SwapchainResult::kSurfaceLost:
            return RenderFrameResult::kSurfaceLost;
        case SwapchainResult::kDeviceLost:
            return RenderFrameResult::kDeviceLost;
        case SwapchainResult::kError:
            return RenderFrameResult::kVulkanFailure;
    }

    const uint64_t framebufferHandle =
        swapchain.getFramebufferHandle(imageIndex);
    if (framebufferHandle == 0) {
        return s.failClosed(swapchain, ahbImports, RenderFrameResult::kVulkanFailure);
    }
    const VkFramebuffer framebuffer =
        u64ToVkHandle<VkFramebuffer>(framebufferHandle);

    const uint64_t presentReadySemaphoreHandle =
        swapchain.getPresentReadySemaphoreHandle(imageIndex);
    if (presentReadySemaphoreHandle == 0) {
        return s.failClosed(swapchain, ahbImports, RenderFrameResult::kVulkanFailure);
    }
    const VkSemaphore presentReadySemaphore =
        u64ToVkHandle<VkSemaphore>(presentReadySemaphoreHandle);

    if (!s.frameSync->resetCommandBuffer(s.currentFrameIndex)) {
        return s.failClosed(swapchain, ahbImports, RenderFrameResult::kVulkanFailure);
    }

    const VkImageLayout currentLayout =
        static_cast<VkImageLayout>(ahbImports.getImageLayout(handle));

    VkCommandBufferBeginInfo beginInfo{};
    beginInfo.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
    if (vkBeginCommandBuffer(frame->commandBuffer, &beginInfo) != VK_SUCCESS) {
        return s.failClosed(swapchain, ahbImports, RenderFrameResult::kVulkanFailure);
    }

    std::string beautyFailureReason;
    const bool beautyOk = s.beautyRenderer->recordBeauty(
        s.device,
        static_cast<VkPhysicalDevice>(physicalDeviceHandle),
        frame->commandBuffer,
        s.currentFrameIndex,
        frameCount,
        *srcImage,
        currentLayout,
        coreShaders.vertex.get(),
        coreShaders.fragment.get(),
        transform,
        beauty,
        renderPass,
        framebuffer,
        extentWidth,
        extentHeight,
        &beautyFailureReason);
    if (!beautyOk) {
        VGLOG_VFR("beauty recordBeauty failed: %s", beautyFailureReason.c_str());
        return s.failClosed(swapchain, ahbImports, RenderFrameResult::kVulkanFailure);
    }
    if (vkEndCommandBuffer(frame->commandBuffer) != VK_SUCCESS) {
        return s.failClosed(swapchain, ahbImports, RenderFrameResult::kVulkanFailure);
    }

    if (!s.frameSync->resetFrameFence(s.currentFrameIndex)) {
        return s.failClosed(swapchain, ahbImports, RenderFrameResult::kVulkanFailure);
    }

    VkSemaphore waitSemaphores[2] = {
        frame->imageAvailableSemaphore,
        VK_NULL_HANDLE,
    };
    VkPipelineStageFlags waitStages[2] = {
        VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
        VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT,
    };
    uint32_t waitSemaphoreCount = 1;
    const uint64_t pendingAcquireSemaphoreHandle =
        ahbImports.getPendingAcquireSemaphoreHandle(handle);
    if (pendingAcquireSemaphoreHandle != 0) {
        waitSemaphores[waitSemaphoreCount++] =
            u64ToVkHandle<VkSemaphore>(pendingAcquireSemaphoreHandle);
    }

    const bool canExportRelease =
        (frame->releaseFenceSemaphore != VK_NULL_HANDLE) && (s.pfnGetSemaphoreFd != nullptr);

    VkSemaphore signalSemaphores[2] = {
        presentReadySemaphore,
        VK_NULL_HANDLE,
    };
    uint32_t signalSemaphoreCount = 1;
    if (canExportRelease) {
        signalSemaphores[signalSemaphoreCount++] = frame->releaseFenceSemaphore;
    }

    VkSubmitInfo submitInfo{};
    submitInfo.sType = VK_STRUCTURE_TYPE_SUBMIT_INFO;
    submitInfo.waitSemaphoreCount = waitSemaphoreCount;
    submitInfo.pWaitSemaphores = waitSemaphores;
    submitInfo.pWaitDstStageMask = waitStages;
    submitInfo.commandBufferCount = 1;
    submitInfo.pCommandBuffers = &frame->commandBuffer;
    submitInfo.signalSemaphoreCount = signalSemaphoreCount;
    submitInfo.pSignalSemaphores = signalSemaphores;

    const VkQueue queue = static_cast<VkQueue>(queueHandle);
    const VkResult submitResult =
        vkQueueSubmit(queue, 1, &submitInfo, frame->inFlightFence);
    if (submitResult != VK_SUCCESS) {
        const RenderFrameResult result =
            (submitResult == VK_ERROR_DEVICE_LOST)
                ? RenderFrameResult::kDeviceLost
                : RenderFrameResult::kVulkanFailure;
        return s.failClosed(swapchain, ahbImports, result);
    }

    if (!ahbImports.markBufferSubmitted(handle, s.currentFrameIndex)) {
        VGLOG_VFR("beauty markBufferSubmitted failed for handle=%" PRIu64 "; failing closed",
                  static_cast<uint64_t>(handle));
        return s.failClosed(swapchain, ahbImports, RenderFrameResult::kVulkanFailure);
    }

    {
        if (canExportRelease) {
            int exportedFd = -1;
            VkSemaphoreGetFdInfoKHR semGetFdInfo{};
            semGetFdInfo.sType      = VK_STRUCTURE_TYPE_SEMAPHORE_GET_FD_INFO_KHR;
            semGetFdInfo.pNext      = nullptr;
            semGetFdInfo.semaphore  = frame->releaseFenceSemaphore;
            semGetFdInfo.handleType = VK_EXTERNAL_SEMAPHORE_HANDLE_TYPE_SYNC_FD_BIT;
            const VkResult exportResult =
                s.pfnGetSemaphoreFd(s.device, &semGetFdInfo, &exportedFd);
            if (exportResult != VK_SUCCESS) {
                VGLOG_VFR("beauty vkGetSemaphoreFdKHR failed: %d; clearing stored release fd",
                          static_cast<int>(exportResult));
                if (exportedFd >= 0) {
                    ::close(exportedFd);
                }
                ahbImports.setLatestReleaseFenceFd(handle, -1);
                return s.failClosed(swapchain, ahbImports, RenderFrameResult::kVulkanFailure);
            }
            ahbImports.setLatestReleaseFenceFd(handle, exportedFd);
        } else {
            ahbImports.setLatestReleaseFenceFd(handle, -1);
        }
    }

    if (pendingAcquireSemaphoreHandle != 0 &&
        !ahbImports.markAcquireSemaphoreSubmitted(handle)) {
        return s.failClosed(swapchain, ahbImports, RenderFrameResult::kVulkanFailure);
    }

    if (!ahbImports.setImageLayout(handle, static_cast<uint32_t>(VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL))) {
        return s.failClosed(swapchain, ahbImports, RenderFrameResult::kVulkanFailure);
    }

    const SwapchainResult presentResult = swapchain.presentImage(
        queueHandle,
        presentReadySemaphoreHandle,
        imageIndex);
    s.currentFrameIndex = (s.currentFrameIndex + 1) % frameCount;

    switch (presentResult) {
        case SwapchainResult::kSuccess:
            return acquireResult == SwapchainResult::kSuboptimal
                ? RenderFrameResult::kSuboptimal
                : RenderFrameResult::kSuccess;
        case SwapchainResult::kSuboptimal:
            return RenderFrameResult::kSuboptimal;
        case SwapchainResult::kOutOfDate:
            return RenderFrameResult::kOutOfDate;
        case SwapchainResult::kSurfaceLost:
            return RenderFrameResult::kSurfaceLost;
        case SwapchainResult::kDeviceLost:
            return s.failClosed(swapchain, ahbImports, RenderFrameResult::kDeviceLost);
        case SwapchainResult::kError:
            return s.failClosed(swapchain, ahbImports, RenderFrameResult::kVulkanFailure);
    }

    return s.failClosed(swapchain, ahbImports, RenderFrameResult::kVulkanFailure);
}

// ---------------------------------------------------------------------------
// P5-OVERLAYS-BEAUTY-SOLO: renderFrame with both Beauty V2 and overlay draws.
// Mirrors the beauty-only overload's entire acquire / frame-fence /
// pending-AHB-semaphore / release-fence-export / present protocol; the only
// difference is that the beauty pre-composite's placement pass is recorded
// via recordBeautyKeepOpen (left open) so the overlay draws can be recorded
// into the SAME render pass immediately afterward, then this method itself
// ends the render pass and the command buffer -- mirroring the overlay-only
// overload's own recordBaseFramePassKeepOpen + recordOverlayDraws +
// vkCmdEndRenderPass sequence.
// ---------------------------------------------------------------------------

RenderFrameResult VulkanFrameRenderer::renderFrame(
    void* queueHandle,
    void* physicalDeviceHandle,
    VulkanSurfaceSwapchain& swapchain,
    VulkanHardwareBufferImports& ahbImports,
    VulkanCoreShaderModules& coreShaders,
    HardwareBufferHandle handle,
    const VideoFrameTransform& transform,
    const VideoBeautyV2RenderParams& beauty,
    const VulkanOverlayFrameDraw* overlayDraws,
    uint32_t overlayCount) {
    if (!beauty.enabled) {
        return renderFrame(queueHandle, swapchain, ahbImports, coreShaders, handle, transform,
                            overlayDraws, overlayCount);
    }
    if (overlayCount == 0) {
        return renderFrame(queueHandle, physicalDeviceHandle, swapchain, ahbImports, coreShaders,
                            handle, transform, beauty);
    }
    if (overlayDraws == nullptr) {
        return RenderFrameResult::kVulkanFailure;
    }
    if (!impl_ || !impl_->initialized) {
        return RenderFrameResult::kBackendNotInitialized;
    }
    Impl& s = *impl_;
    if (queueHandle == nullptr || physicalDeviceHandle == nullptr ||
        s.device == VK_NULL_HANDLE || s.commandPool == VK_NULL_HANDLE) {
        return RenderFrameResult::kVulkanFailure;
    }
    if (!swapchain.hasSurface()) {
        return RenderFrameResult::kNoSurface;
    }
    const VulkanHardwareBufferImage* srcImage = ahbImports.getImage(handle);
    if (!ahbImports.hasBuffer(handle) || srcImage == nullptr) {
        return RenderFrameResult::kInvalidBufferHandle;
    }
    if (srcImage->image == VK_NULL_HANDLE ||
        coreShaders.vertex.get() == VK_NULL_HANDLE ||
        coreShaders.fragment.get() == VK_NULL_HANDLE ||
        !s.frameSync || !s.frameSync->isInitialized()) {
        return RenderFrameResult::kVulkanFailure;
    }

    const uint32_t frameCount = s.frameSync->getFrameCount();
    if (frameCount == 0 || s.currentFrameIndex >= frameCount) {
        return RenderFrameResult::kVulkanFailure;
    }
    const VulkanFrameSyncResources* frame =
        s.frameSync->getFrame(s.currentFrameIndex);
    if (frame == nullptr || frame->commandBuffer == VK_NULL_HANDLE ||
        frame->imageAvailableSemaphore == VK_NULL_HANDLE ||
        frame->inFlightFence == VK_NULL_HANDLE) {
        return RenderFrameResult::kVulkanFailure;
    }

    const uint64_t renderPassHandle = swapchain.getRenderPassHandle();
    const uint32_t extentWidth = swapchain.getExtentWidth();
    const uint32_t extentHeight = swapchain.getExtentHeight();
    if (renderPassHandle == 0 || extentWidth == 0 || extentHeight == 0) {
        return RenderFrameResult::kVulkanFailure;
    }
    const VkRenderPass renderPass = u64ToVkHandle<VkRenderPass>(renderPassHandle);

    // Mirrors the overlay-only overload's Correction 1: validate every
    // overlay draw against the canvas extent now, before the swapchain is
    // acquired and before any Vulkan call below, so invalid caller-supplied
    // overlay data fails closed without ever opening the beauty
    // pre-composite's render pass.
    if (!overlayFrameDrawsValid(overlayDraws, overlayCount, extentWidth, extentHeight)) {
        return RenderFrameResult::kVulkanFailure;
    }

    if (!s.beautyRenderer) {
        s.beautyRenderer = std::make_unique<VulkanBeautyFrameRenderer>();
    }
    if (!s.overlayRenderer) {
        s.overlayRenderer = std::make_unique<VulkanOverlayFrameRenderer>();
    }

    if (!s.frameSync->waitForFrameFence(s.currentFrameIndex)) {
        return RenderFrameResult::kVulkanFailure;
    }
    ahbImports.drainRetiredForFrame(s.currentFrameIndex);

    uint32_t imageIndex = 0;
    const SwapchainResult acquireResult = swapchain.acquireNextImage(
        vkHandleToU64(frame->imageAvailableSemaphore),
        0,
        &imageIndex,
        UINT64_MAX);
    switch (acquireResult) {
        case SwapchainResult::kSuccess:
        case SwapchainResult::kSuboptimal:
            break;
        case SwapchainResult::kOutOfDate:
            return RenderFrameResult::kOutOfDate;
        case SwapchainResult::kSurfaceLost:
            return RenderFrameResult::kSurfaceLost;
        case SwapchainResult::kDeviceLost:
            return RenderFrameResult::kDeviceLost;
        case SwapchainResult::kError:
            return RenderFrameResult::kVulkanFailure;
    }

    const uint64_t framebufferHandle =
        swapchain.getFramebufferHandle(imageIndex);
    if (framebufferHandle == 0) {
        return s.failClosed(swapchain, ahbImports, RenderFrameResult::kVulkanFailure);
    }
    const VkFramebuffer framebuffer =
        u64ToVkHandle<VkFramebuffer>(framebufferHandle);

    const uint64_t presentReadySemaphoreHandle =
        swapchain.getPresentReadySemaphoreHandle(imageIndex);
    if (presentReadySemaphoreHandle == 0) {
        return s.failClosed(swapchain, ahbImports, RenderFrameResult::kVulkanFailure);
    }
    const VkSemaphore presentReadySemaphore =
        u64ToVkHandle<VkSemaphore>(presentReadySemaphoreHandle);

    if (!s.frameSync->resetCommandBuffer(s.currentFrameIndex)) {
        return s.failClosed(swapchain, ahbImports, RenderFrameResult::kVulkanFailure);
    }

    const VkImageLayout currentLayout =
        static_cast<VkImageLayout>(ahbImports.getImageLayout(handle));

    VkCommandBufferBeginInfo beginInfo{};
    beginInfo.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
    if (vkBeginCommandBuffer(frame->commandBuffer, &beginInfo) != VK_SUCCESS) {
        return s.failClosed(swapchain, ahbImports, RenderFrameResult::kVulkanFailure);
    }

    std::string beautyFailureReason;
    const bool beautyOk = s.beautyRenderer->recordBeautyKeepOpen(
        s.device,
        static_cast<VkPhysicalDevice>(physicalDeviceHandle),
        frame->commandBuffer,
        s.currentFrameIndex,
        frameCount,
        *srcImage,
        currentLayout,
        coreShaders.vertex.get(),
        coreShaders.fragment.get(),
        transform,
        beauty,
        renderPass,
        framebuffer,
        extentWidth,
        extentHeight,
        &beautyFailureReason);
    if (!beautyOk) {
        VGLOG_VFR("beauty+overlay recordBeautyKeepOpen failed: %s", beautyFailureReason.c_str());
        // recordBeautyKeepOpen validates every failure path BEFORE it ever
        // calls vkCmdBeginRenderPass (mirrors recordBeauty's own pass-5
        // validation order), so a false return here leaves the command
        // buffer recording with no render pass ever opened -- never
        // vkCmdEndRenderPass on this path.
        abandonRecordingCommandBuffer(frame->commandBuffer);
        return s.failClosed(swapchain, ahbImports, RenderFrameResult::kVulkanFailure);
    }

    std::string overlayFailureReason;
    const bool overlayOk = s.overlayRenderer->recordOverlayDraws(
        static_cast<void*>(s.device),
        static_cast<void*>(frame->commandBuffer),
        reinterpret_cast<void*>(coreShaders.vertex.get()),
        reinterpret_cast<void*>(coreShaders.fragment.get()),
        renderPassHandle,
        extentWidth,
        extentHeight,
        overlayDraws,
        overlayCount,
        &overlayFailureReason);
    if (!overlayOk) {
        VGLOG_VFR("beauty+overlay recordOverlayDraws failed: %s", overlayFailureReason.c_str());
        // recordBeautyKeepOpen already opened the render pass above;
        // overlayFrameDrawsValid() already ruled out invalid caller data
        // before that happened, so this is a genuine resource failure (e.g. a
        // descriptor pool allocation). Close the open render pass / command
        // buffer best-effort before failClosed -- never submit or present on
        // this path.
        abandonOpenRenderPass(frame->commandBuffer);
        return s.failClosed(swapchain, ahbImports, RenderFrameResult::kVulkanFailure);
    }

    vkCmdEndRenderPass(frame->commandBuffer);
    if (vkEndCommandBuffer(frame->commandBuffer) != VK_SUCCESS) {
        return s.failClosed(swapchain, ahbImports, RenderFrameResult::kVulkanFailure);
    }

    if (!s.frameSync->resetFrameFence(s.currentFrameIndex)) {
        return s.failClosed(swapchain, ahbImports, RenderFrameResult::kVulkanFailure);
    }

    VkSemaphore waitSemaphores[2] = {
        frame->imageAvailableSemaphore,
        VK_NULL_HANDLE,
    };
    VkPipelineStageFlags waitStages[2] = {
        VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
        VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT,
    };
    uint32_t waitSemaphoreCount = 1;
    const uint64_t pendingAcquireSemaphoreHandle =
        ahbImports.getPendingAcquireSemaphoreHandle(handle);
    if (pendingAcquireSemaphoreHandle != 0) {
        waitSemaphores[waitSemaphoreCount++] =
            u64ToVkHandle<VkSemaphore>(pendingAcquireSemaphoreHandle);
    }

    const bool canExportRelease =
        (frame->releaseFenceSemaphore != VK_NULL_HANDLE) && (s.pfnGetSemaphoreFd != nullptr);

    VkSemaphore signalSemaphores[2] = {
        presentReadySemaphore,
        VK_NULL_HANDLE,
    };
    uint32_t signalSemaphoreCount = 1;
    if (canExportRelease) {
        signalSemaphores[signalSemaphoreCount++] = frame->releaseFenceSemaphore;
    }

    VkSubmitInfo submitInfo{};
    submitInfo.sType = VK_STRUCTURE_TYPE_SUBMIT_INFO;
    submitInfo.waitSemaphoreCount = waitSemaphoreCount;
    submitInfo.pWaitSemaphores = waitSemaphores;
    submitInfo.pWaitDstStageMask = waitStages;
    submitInfo.commandBufferCount = 1;
    submitInfo.pCommandBuffers = &frame->commandBuffer;
    submitInfo.signalSemaphoreCount = signalSemaphoreCount;
    submitInfo.pSignalSemaphores = signalSemaphores;

    const VkQueue queue = static_cast<VkQueue>(queueHandle);
    const VkResult submitResult =
        vkQueueSubmit(queue, 1, &submitInfo, frame->inFlightFence);
    if (submitResult != VK_SUCCESS) {
        const RenderFrameResult result =
            (submitResult == VK_ERROR_DEVICE_LOST)
                ? RenderFrameResult::kDeviceLost
                : RenderFrameResult::kVulkanFailure;
        return s.failClosed(swapchain, ahbImports, result);
    }

    if (!ahbImports.markBufferSubmitted(handle, s.currentFrameIndex)) {
        VGLOG_VFR("beauty+overlay markBufferSubmitted failed for handle=%" PRIu64 "; failing closed",
                  static_cast<uint64_t>(handle));
        return s.failClosed(swapchain, ahbImports, RenderFrameResult::kVulkanFailure);
    }

    {
        if (canExportRelease) {
            int exportedFd = -1;
            VkSemaphoreGetFdInfoKHR semGetFdInfo{};
            semGetFdInfo.sType      = VK_STRUCTURE_TYPE_SEMAPHORE_GET_FD_INFO_KHR;
            semGetFdInfo.pNext      = nullptr;
            semGetFdInfo.semaphore  = frame->releaseFenceSemaphore;
            semGetFdInfo.handleType = VK_EXTERNAL_SEMAPHORE_HANDLE_TYPE_SYNC_FD_BIT;
            const VkResult exportResult =
                s.pfnGetSemaphoreFd(s.device, &semGetFdInfo, &exportedFd);
            if (exportResult != VK_SUCCESS) {
                VGLOG_VFR("beauty+overlay vkGetSemaphoreFdKHR failed: %d; clearing stored release fd",
                          static_cast<int>(exportResult));
                if (exportedFd >= 0) {
                    ::close(exportedFd);
                }
                ahbImports.setLatestReleaseFenceFd(handle, -1);
                return s.failClosed(swapchain, ahbImports, RenderFrameResult::kVulkanFailure);
            }
            ahbImports.setLatestReleaseFenceFd(handle, exportedFd);
        } else {
            ahbImports.setLatestReleaseFenceFd(handle, -1);
        }
    }

    if (pendingAcquireSemaphoreHandle != 0 &&
        !ahbImports.markAcquireSemaphoreSubmitted(handle)) {
        return s.failClosed(swapchain, ahbImports, RenderFrameResult::kVulkanFailure);
    }

    if (!ahbImports.setImageLayout(handle, static_cast<uint32_t>(VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL))) {
        return s.failClosed(swapchain, ahbImports, RenderFrameResult::kVulkanFailure);
    }

    const SwapchainResult presentResult = swapchain.presentImage(
        queueHandle,
        presentReadySemaphoreHandle,
        imageIndex);
    s.currentFrameIndex = (s.currentFrameIndex + 1) % frameCount;

    switch (presentResult) {
        case SwapchainResult::kSuccess:
            return acquireResult == SwapchainResult::kSuboptimal
                ? RenderFrameResult::kSuboptimal
                : RenderFrameResult::kSuccess;
        case SwapchainResult::kSuboptimal:
            return RenderFrameResult::kSuboptimal;
        case SwapchainResult::kOutOfDate:
            return RenderFrameResult::kOutOfDate;
        case SwapchainResult::kSurfaceLost:
            return RenderFrameResult::kSurfaceLost;
        case SwapchainResult::kDeviceLost:
            return s.failClosed(swapchain, ahbImports, RenderFrameResult::kDeviceLost);
        case SwapchainResult::kError:
            return s.failClosed(swapchain, ahbImports, RenderFrameResult::kVulkanFailure);
    }

    return s.failClosed(swapchain, ahbImports, RenderFrameResult::kVulkanFailure);
}

// ---------------------------------------------------------------------------
// P5-COMPOSITOR-TRANS: two-source clip overlap transition frame.
// Draw-model resolution, placement math, draw-list construction and the
// crossfade blend pipeline live in vulkan_transition_frame_renderer.{h,cpp};
// this method owns only the per-frame swapchain / fence / semaphore protocol.
// ---------------------------------------------------------------------------

RenderFrameResult VulkanFrameRenderer::renderTransitionFrame(
    void* queueHandle,
    void* physicalDeviceHandle,
    VulkanSurfaceSwapchain& swapchain,
    VulkanHardwareBufferImports& ahbImports,
    VulkanCoreShaderModules& coreShaders,
    HardwareBufferHandle fromHandle,
    HardwareBufferHandle toHandle,
    const VideoTransitionFrameTransform& transition,
    const VideoBeautyV2RenderParams& fromBeauty,
    const VideoBeautyV2RenderParams& toBeauty) {
    if (!impl_ || !impl_->initialized) {
        return RenderFrameResult::kBackendNotInitialized;
    }
    Impl& s = *impl_;
    if (queueHandle == nullptr || s.device == VK_NULL_HANDLE ||
        s.commandPool == VK_NULL_HANDLE) {
        return RenderFrameResult::kVulkanFailure;
    }
    const bool anyBeauty = fromBeauty.enabled || toBeauty.enabled;
    if (anyBeauty && physicalDeviceHandle == nullptr) {
        return RenderFrameResult::kVulkanFailure;
    }
    if (!swapchain.hasSurface()) {
        return RenderFrameResult::kNoSurface;
    }
    if (fromHandle == toHandle) {
        return RenderFrameResult::kInvalidBufferHandle;
    }
    const VulkanHardwareBufferImage* fromImage = ahbImports.getImage(fromHandle);
    const VulkanHardwareBufferImage* toImage = ahbImports.getImage(toHandle);
    if (!ahbImports.hasBuffer(fromHandle) || fromImage == nullptr ||
        !ahbImports.hasBuffer(toHandle) || toImage == nullptr) {
        return RenderFrameResult::kInvalidBufferHandle;
    }
    if (fromImage->image == VK_NULL_HANDLE || toImage->image == VK_NULL_HANDLE ||
        coreShaders.vertex.get() == VK_NULL_HANDLE ||
        coreShaders.fragment.get() == VK_NULL_HANDLE ||
        !s.frameSync || !s.frameSync->isInitialized()) {
        return RenderFrameResult::kVulkanFailure;
    }

    // Draw model from the weights (see render_transform.h). Validated before
    // any Vulkan state is touched so an invalid descriptor never reaches the
    // swapchain.
    VulkanTransitionDrawMode mode;
    if (!ResolveVulkanTransitionDrawMode(transition, &mode)) {
        VGLOG_VFR("renderTransitionFrame: non-finite weights/progress or non-identity "
                  "crossfade geometry; failing closed");
        return RenderFrameResult::kVulkanFailure;
    }

    const uint32_t frameCount = s.frameSync->getFrameCount();
    if (frameCount == 0 || s.currentFrameIndex >= frameCount) {
        return RenderFrameResult::kVulkanFailure;
    }
    const VulkanFrameSyncResources* frame =
        s.frameSync->getFrame(s.currentFrameIndex);
    if (frame == nullptr || frame->commandBuffer == VK_NULL_HANDLE ||
        frame->imageAvailableSemaphore == VK_NULL_HANDLE ||
        frame->inFlightFence == VK_NULL_HANDLE) {
        return RenderFrameResult::kVulkanFailure;
    }

    const uint64_t renderPassHandle = swapchain.getRenderPassHandle();
    const uint32_t extentWidth = swapchain.getExtentWidth();
    const uint32_t extentHeight = swapchain.getExtentHeight();
    const VkPipelineLayout fromLayout = fromImage->descriptorResources.pipelineLayout;
    const VkDescriptorSet fromSet = fromImage->descriptorResources.descriptorSet;
    const VkPipelineLayout toLayout = toImage->descriptorResources.pipelineLayout;
    const VkDescriptorSet toSet = toImage->descriptorResources.descriptorSet;
    if (renderPassHandle == 0 || extentWidth == 0 || extentHeight == 0 ||
        fromLayout == VK_NULL_HANDLE || fromSet == VK_NULL_HANDLE ||
        toLayout == VK_NULL_HANDLE || toSet == VK_NULL_HANDLE) {
        return RenderFrameResult::kVulkanFailure;
    }
    const VkRenderPass renderPass = u64ToVkHandle<VkRenderPass>(renderPassHandle);

    // Placement is pure math; resolve it before creating any pipeline.
    VulkanTransitionLayerPlacement fromPlacement;
    VulkanTransitionLayerPlacement toPlacement;
    if (!ResolveVulkanTransitionLayerPlacement(transition.from, transition.fromViewport,
                                               transition.fromCrop, extentWidth, extentHeight,
                                               &fromPlacement) ||
        !ResolveVulkanTransitionLayerPlacement(transition.to, transition.toViewport,
                                               transition.toCrop, extentWidth, extentHeight,
                                               &toPlacement)) {
        VGLOG_VFR("renderTransitionFrame: invalid layer geometry; failing closed");
        return RenderFrameResult::kVulkanFailure;
    }

    // Pipelines are per import layout, so every transition frame rebuilds
    // them. Any cached pipeline (solo or previous transition) may still be in
    // flight on the other frame slot: idle the device before destroying.
    if (vkDeviceWaitIdle(s.device) != VK_SUCCESS) {
        return RenderFrameResult::kVulkanFailure;
    }
    s.invalidatePipeline();

    const bool needFrom = mode != VulkanTransitionDrawMode::kToOnly;
    const bool needToOpaque =
        mode == VulkanTransitionDrawMode::kToOnly || mode == VulkanTransitionDrawMode::kPaintOver;
    const bool needToBlend = mode == VulkanTransitionDrawMode::kCrossfade;
    // P5-BEAUTY-V2-TRANSITION-COMP: a beautified layer is drawn through its
    // own VulkanBeautyFrameRenderer placement pipeline (built later, after
    // prepareTransitionLayer runs), never through an AHB-import-layout
    // pipeline built here.
    if (needFrom && !fromBeauty.enabled) {
        s.transitionFromPipeline = std::make_unique<VulkanGraphicsPipeline>();
        if (!s.transitionFromPipeline->create(s.device, fromLayout, renderPass,
                                              coreShaders.vertex.get(),
                                              coreShaders.fragment.get())) {
            s.invalidatePipeline();
            return RenderFrameResult::kVulkanFailure;
        }
    }
    if (needToOpaque && !toBeauty.enabled) {
        s.transitionToOpaquePipeline = std::make_unique<VulkanGraphicsPipeline>();
        if (!s.transitionToOpaquePipeline->create(s.device, toLayout, renderPass,
                                                  coreShaders.vertex.get(),
                                                  coreShaders.fragment.get())) {
            s.invalidatePipeline();
            return RenderFrameResult::kVulkanFailure;
        }
    }
    if (needToBlend && !toBeauty.enabled) {
        if (!CreateVulkanTransitionBlendPipeline(s.device, toLayout, renderPass,
                                                 coreShaders.vertex.get(),
                                                 coreShaders.fragment.get(),
                                                 &s.transitionToBlendPipeline)) {
            s.invalidatePipeline();
            return RenderFrameResult::kVulkanFailure;
        }
    }

    if (!s.frameSync->waitForFrameFence(s.currentFrameIndex)) {
        return RenderFrameResult::kVulkanFailure;
    }
    ahbImports.drainRetiredForFrame(s.currentFrameIndex);

    uint32_t imageIndex = 0;
    const SwapchainResult acquireResult = swapchain.acquireNextImage(
        vkHandleToU64(frame->imageAvailableSemaphore),
        0,
        &imageIndex,
        UINT64_MAX);
    switch (acquireResult) {
        case SwapchainResult::kSuccess:
        case SwapchainResult::kSuboptimal:
            break;
        case SwapchainResult::kOutOfDate:
            return RenderFrameResult::kOutOfDate;
        case SwapchainResult::kSurfaceLost:
            return RenderFrameResult::kSurfaceLost;
        case SwapchainResult::kDeviceLost:
            return RenderFrameResult::kDeviceLost;
        case SwapchainResult::kError:
            return RenderFrameResult::kVulkanFailure;
    }

    const uint64_t framebufferHandle = swapchain.getFramebufferHandle(imageIndex);
    if (framebufferHandle == 0) {
        return s.failClosed(swapchain, ahbImports, RenderFrameResult::kVulkanFailure);
    }
    const VkFramebuffer framebuffer = u64ToVkHandle<VkFramebuffer>(framebufferHandle);

    const uint64_t presentReadySemaphoreHandle =
        swapchain.getPresentReadySemaphoreHandle(imageIndex);
    if (presentReadySemaphoreHandle == 0) {
        return s.failClosed(swapchain, ahbImports, RenderFrameResult::kVulkanFailure);
    }
    const VkSemaphore presentReadySemaphore =
        u64ToVkHandle<VkSemaphore>(presentReadySemaphoreHandle);

    if (!s.frameSync->resetCommandBuffer(s.currentFrameIndex)) {
        return s.failClosed(swapchain, ahbImports, RenderFrameResult::kVulkanFailure);
    }

    VulkanTransitionPassParams passParams{};
    passParams.commandBuffer = frame->commandBuffer;
    passParams.renderPass = renderPass;
    passParams.framebuffer = framebuffer;
    passParams.extentWidth = extentWidth;
    passParams.extentHeight = extentHeight;
    const VkImageLayout fromLayoutState =
        static_cast<VkImageLayout>(ahbImports.getImageLayout(fromHandle));
    const VkImageLayout toLayoutState =
        static_cast<VkImageLayout>(ahbImports.getImageLayout(toHandle));
    passParams.fromImage = fromImage;
    passParams.fromOldLayout = VK_IMAGE_LAYOUT_UNDEFINED;
    // P5-BEAUTY-V2-TRANSITION-COMP: a beautified layer's own crop pass (run
    // by prepareTransitionLayer below) already performs the AHB layout
    // transition when its current layout is undefined, so this pass must not
    // transition it again.
    passParams.transitionFromImage =
        fromBeauty.enabled ? false : (fromLayoutState == VK_IMAGE_LAYOUT_UNDEFINED);
    passParams.toImage = toImage;
    passParams.toOldLayout = VK_IMAGE_LAYOUT_UNDEFINED;
    passParams.transitionToImage =
        toBeauty.enabled ? false : (toLayoutState == VK_IMAGE_LAYOUT_UNDEFINED);

    VulkanTransitionLayerResources fromRes;
    VulkanTransitionLayerResources toRes;

    if (!anyBeauty) {
        // Byte-identical to the pre-existing non-beauty transition path.
        fromRes.pipeline = s.transitionFromPipeline ? s.transitionFromPipeline->get() : VK_NULL_HANDLE;
        fromRes.pipelineLayout = fromLayout;
        fromRes.descriptorSet = fromSet;
        fromRes.pushConstants = makeVideoTransformFullPushConstants(transition.from);

        toRes.pipelineLayout = toLayout;
        toRes.descriptorSet = toSet;
        toRes.pushConstants = makeVideoTransformFullPushConstants(transition.to);
        if (needToBlend) {
            toRes.pipeline = s.transitionToBlendPipeline;
            toRes.useBlendConstants = true;
            toRes.blendConstant =
                static_cast<float>(std::max(0.0, std::min(1.0, transition.blendWeightTo)));
        } else if (s.transitionToOpaquePipeline) {
            toRes.pipeline = s.transitionToOpaquePipeline->get();
        }

        bool planOk = true;
        switch (mode) {
            case VulkanTransitionDrawMode::kFromOnly:
                planOk = AppendVulkanTransitionLayer(&passParams, fromRes, fromPlacement, false);
                break;
            case VulkanTransitionDrawMode::kToOnly:
                planOk = AppendVulkanTransitionLayer(&passParams, toRes, toPlacement, false);
                break;
            case VulkanTransitionDrawMode::kPaintOver:
            case VulkanTransitionDrawMode::kCrossfade:
                planOk = AppendVulkanTransitionLayer(&passParams, fromRes, fromPlacement, false) &&
                         AppendVulkanTransitionLayer(&passParams, toRes, toPlacement, true);
                break;
        }
        if (!planOk) {
            return s.failClosed(swapchain, ahbImports, RenderFrameResult::kVulkanFailure);
        }

        if (!VulkanGraphicsCommandRecorder::recordTransitionPass(passParams)) {
            return s.failClosed(swapchain, ahbImports, RenderFrameResult::kVulkanFailure);
        }
    } else {
        // P5-BEAUTY-V2-TRANSITION-COMP: beauty transition path. Validation
        // (mode, placement) already happened above, before any recording;
        // now: vkBeginCommandBuffer -> optional beauty prepasses -> the
        // (separately validated) transition pass body -> vkEndCommandBuffer.
        if (!s.beautyRendererFrom) {
            s.beautyRendererFrom = std::make_unique<VulkanBeautyFrameRenderer>();
        }
        if (!s.beautyRendererTo) {
            s.beautyRendererTo = std::make_unique<VulkanBeautyFrameRenderer>();
        }

        VkCommandBufferBeginInfo beginInfo{};
        beginInfo.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
        if (vkBeginCommandBuffer(frame->commandBuffer, &beginInfo) != VK_SUCCESS) {
            return s.failClosed(swapchain, ahbImports, RenderFrameResult::kVulkanFailure);
        }

        VulkanBeautyTransitionLayerResources fromBeautyRes;
        VulkanBeautyTransitionLayerResources toBeautyRes;
        std::string beautyFailureReason;
        const auto physDev = static_cast<VkPhysicalDevice>(physicalDeviceHandle);

        if (fromBeauty.enabled) {
            if (!s.beautyRendererFrom->prepareTransitionLayer(
                    s.device, physDev, frame->commandBuffer, s.currentFrameIndex, frameCount,
                    *fromImage, fromLayoutState, coreShaders.vertex.get(), coreShaders.fragment.get(),
                    transition.from, fromBeauty, renderPass, &fromBeautyRes, &beautyFailureReason)) {
                VGLOG_VFR("transition beauty prepareTransitionLayer(from) failed: %s",
                          beautyFailureReason.c_str());
                return s.failClosed(swapchain, ahbImports, RenderFrameResult::kVulkanFailure);
            }
        }
        if (toBeauty.enabled) {
            if (!s.beautyRendererTo->prepareTransitionLayer(
                    s.device, physDev, frame->commandBuffer, s.currentFrameIndex, frameCount,
                    *toImage, toLayoutState, coreShaders.vertex.get(), coreShaders.fragment.get(),
                    transition.to, toBeauty, renderPass, &toBeautyRes, &beautyFailureReason)) {
                VGLOG_VFR("transition beauty prepareTransitionLayer(to) failed: %s",
                          beautyFailureReason.c_str());
                return s.failClosed(swapchain, ahbImports, RenderFrameResult::kVulkanFailure);
            }
        }

        // Pipeline-layout correctness: a beautified "to" layer blended for
        // crossfade needs a blend pipeline built with Beauty's placement
        // pipeline layout, never the AHB import layout.
        if (needToBlend && toBeauty.enabled) {
            if (!CreateVulkanTransitionBlendPipeline(s.device, toBeautyRes.pipelineLayout, renderPass,
                                                     coreShaders.vertex.get(), coreShaders.fragment.get(),
                                                     &s.transitionToBlendPipeline)) {
                return s.failClosed(swapchain, ahbImports, RenderFrameResult::kVulkanFailure);
            }
        }

        if (fromBeauty.enabled) {
            fromRes.pipeline = fromBeautyRes.pipeline;
            fromRes.pipelineLayout = fromBeautyRes.pipelineLayout;
            fromRes.descriptorSet = fromBeautyRes.descriptorSet;
            fromRes.pushConstants = makeVideoTransformFullPushConstants(fromBeautyRes.placementTransform);
        } else {
            fromRes.pipeline = s.transitionFromPipeline ? s.transitionFromPipeline->get() : VK_NULL_HANDLE;
            fromRes.pipelineLayout = fromLayout;
            fromRes.descriptorSet = fromSet;
            fromRes.pushConstants = makeVideoTransformFullPushConstants(transition.from);
        }

        if (toBeauty.enabled) {
            toRes.pipelineLayout = toBeautyRes.pipelineLayout;
            toRes.descriptorSet = toBeautyRes.descriptorSet;
            toRes.pushConstants = makeVideoTransformFullPushConstants(toBeautyRes.placementTransform);
        } else {
            toRes.pipelineLayout = toLayout;
            toRes.descriptorSet = toSet;
            toRes.pushConstants = makeVideoTransformFullPushConstants(transition.to);
        }
        if (needToBlend) {
            toRes.pipeline = s.transitionToBlendPipeline;
            toRes.useBlendConstants = true;
            toRes.blendConstant =
                static_cast<float>(std::max(0.0, std::min(1.0, transition.blendWeightTo)));
        } else if (toBeauty.enabled) {
            toRes.pipeline = toBeautyRes.pipeline;
        } else if (s.transitionToOpaquePipeline) {
            toRes.pipeline = s.transitionToOpaquePipeline->get();
        }

        bool planOk = true;
        switch (mode) {
            case VulkanTransitionDrawMode::kFromOnly:
                planOk = AppendVulkanTransitionLayer(&passParams, fromRes, fromPlacement, false);
                break;
            case VulkanTransitionDrawMode::kToOnly:
                planOk = AppendVulkanTransitionLayer(&passParams, toRes, toPlacement, false);
                break;
            case VulkanTransitionDrawMode::kPaintOver:
            case VulkanTransitionDrawMode::kCrossfade:
                planOk = AppendVulkanTransitionLayer(&passParams, fromRes, fromPlacement, false) &&
                         AppendVulkanTransitionLayer(&passParams, toRes, toPlacement, true);
                break;
        }
        if (!planOk) {
            return s.failClosed(swapchain, ahbImports, RenderFrameResult::kVulkanFailure);
        }

        if (!VulkanGraphicsCommandRecorder::recordTransitionPassBody(passParams)) {
            return s.failClosed(swapchain, ahbImports, RenderFrameResult::kVulkanFailure);
        }

        if (vkEndCommandBuffer(frame->commandBuffer) != VK_SUCCESS) {
            return s.failClosed(swapchain, ahbImports, RenderFrameResult::kVulkanFailure);
        }
    }

    if (!s.frameSync->resetFrameFence(s.currentFrameIndex)) {
        return s.failClosed(swapchain, ahbImports, RenderFrameResult::kVulkanFailure);
    }

    VkSemaphore waitSemaphores[3] = {
        frame->imageAvailableSemaphore,
        VK_NULL_HANDLE,
        VK_NULL_HANDLE,
    };
    VkPipelineStageFlags waitStages[3] = {
        VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
        VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT,
        VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT,
    };
    uint32_t waitSemaphoreCount = 1;
    const uint64_t fromPendingAcquire = ahbImports.getPendingAcquireSemaphoreHandle(fromHandle);
    const uint64_t toPendingAcquire = ahbImports.getPendingAcquireSemaphoreHandle(toHandle);
    if (fromPendingAcquire != 0) {
        waitSemaphores[waitSemaphoreCount++] = u64ToVkHandle<VkSemaphore>(fromPendingAcquire);
    }
    if (toPendingAcquire != 0 && toPendingAcquire != fromPendingAcquire) {
        waitSemaphores[waitSemaphoreCount++] = u64ToVkHandle<VkSemaphore>(toPendingAcquire);
    }

    const bool canExportRelease =
        (frame->releaseFenceSemaphore != VK_NULL_HANDLE) && (s.pfnGetSemaphoreFd != nullptr);

    VkSemaphore signalSemaphores[2] = {
        presentReadySemaphore,
        VK_NULL_HANDLE,
    };
    uint32_t signalSemaphoreCount = 1;
    if (canExportRelease) {
        signalSemaphores[signalSemaphoreCount++] = frame->releaseFenceSemaphore;
    }

    VkSubmitInfo submitInfo{};
    submitInfo.sType = VK_STRUCTURE_TYPE_SUBMIT_INFO;
    submitInfo.waitSemaphoreCount = waitSemaphoreCount;
    submitInfo.pWaitSemaphores = waitSemaphores;
    submitInfo.pWaitDstStageMask = waitStages;
    submitInfo.commandBufferCount = 1;
    submitInfo.pCommandBuffers = &frame->commandBuffer;
    submitInfo.signalSemaphoreCount = signalSemaphoreCount;
    submitInfo.pSignalSemaphores = signalSemaphores;

    const VkQueue queue = static_cast<VkQueue>(queueHandle);
    const VkResult submitResult =
        vkQueueSubmit(queue, 1, &submitInfo, frame->inFlightFence);
    if (submitResult != VK_SUCCESS) {
        const RenderFrameResult result =
            (submitResult == VK_ERROR_DEVICE_LOST)
                ? RenderFrameResult::kDeviceLost
                : RenderFrameResult::kVulkanFailure;
        return s.failClosed(swapchain, ahbImports, result);
    }

    // Both imports were consumed by this submission: tag both records with
    // the frame slot so their deferred retirement waits for this fence.
    if (!ahbImports.markBufferSubmitted(fromHandle, s.currentFrameIndex) ||
        !ahbImports.markBufferSubmitted(toHandle, s.currentFrameIndex)) {
        VGLOG_VFR("markBufferSubmitted failed for transition handles %" PRIu64 "/%" PRIu64
                  "; failing closed",
                  static_cast<uint64_t>(fromHandle), static_cast<uint64_t>(toHandle));
        return s.failClosed(swapchain, ahbImports, RenderFrameResult::kVulkanFailure);
    }

    // Release-fence export (see renderFrame): a sync-fd export has wait
    // semantics on the semaphore payload, so export exactly once and hand the
    // "to" record a dup() of the same fd (or -1 when no fd was produced).
    {
        if (canExportRelease) {
            int exportedFd = -1;
            VkSemaphoreGetFdInfoKHR semGetFdInfo{};
            semGetFdInfo.sType      = VK_STRUCTURE_TYPE_SEMAPHORE_GET_FD_INFO_KHR;
            semGetFdInfo.pNext      = nullptr;
            semGetFdInfo.semaphore  = frame->releaseFenceSemaphore;
            semGetFdInfo.handleType = VK_EXTERNAL_SEMAPHORE_HANDLE_TYPE_SYNC_FD_BIT;
            const VkResult exportResult =
                s.pfnGetSemaphoreFd(s.device, &semGetFdInfo, &exportedFd);
            if (exportResult != VK_SUCCESS) {
                VGLOG_VFR("transition vkGetSemaphoreFdKHR failed: %d; clearing stored release fds",
                          static_cast<int>(exportResult));
                if (exportedFd >= 0) {
                    ::close(exportedFd);
                }
                ahbImports.setLatestReleaseFenceFd(fromHandle, -1);
                ahbImports.setLatestReleaseFenceFd(toHandle, -1);
                return s.failClosed(swapchain, ahbImports, RenderFrameResult::kVulkanFailure);
            }
            int dupFd = -1;
            if (exportedFd >= 0) {
                dupFd = ::dup(exportedFd);
                if (dupFd < 0) dupFd = -1;
            }
            ahbImports.setLatestReleaseFenceFd(fromHandle, exportedFd);
            ahbImports.setLatestReleaseFenceFd(toHandle, dupFd);
        } else {
            ahbImports.setLatestReleaseFenceFd(fromHandle, -1);
            ahbImports.setLatestReleaseFenceFd(toHandle, -1);
        }
    }

    if ((fromPendingAcquire != 0 && !ahbImports.markAcquireSemaphoreSubmitted(fromHandle)) ||
        (toPendingAcquire != 0 && !ahbImports.markAcquireSemaphoreSubmitted(toHandle))) {
        return s.failClosed(swapchain, ahbImports, RenderFrameResult::kVulkanFailure);
    }

    if (!ahbImports.setImageLayout(
            fromHandle, static_cast<uint32_t>(VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL)) ||
        !ahbImports.setImageLayout(
            toHandle, static_cast<uint32_t>(VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL))) {
        return s.failClosed(swapchain, ahbImports, RenderFrameResult::kVulkanFailure);
    }

    const SwapchainResult presentResult = swapchain.presentImage(
        queueHandle,
        presentReadySemaphoreHandle,
        imageIndex);
    s.currentFrameIndex = (s.currentFrameIndex + 1) % frameCount;

    switch (presentResult) {
        case SwapchainResult::kSuccess:
            return acquireResult == SwapchainResult::kSuboptimal
                ? RenderFrameResult::kSuboptimal
                : RenderFrameResult::kSuccess;
        case SwapchainResult::kSuboptimal:
            return RenderFrameResult::kSuboptimal;
        case SwapchainResult::kOutOfDate:
            return RenderFrameResult::kOutOfDate;
        case SwapchainResult::kSurfaceLost:
            return RenderFrameResult::kSurfaceLost;
        case SwapchainResult::kDeviceLost:
            return s.failClosed(swapchain, ahbImports, RenderFrameResult::kDeviceLost);
        case SwapchainResult::kError:
            return s.failClosed(swapchain, ahbImports, RenderFrameResult::kVulkanFailure);
    }

    return s.failClosed(swapchain, ahbImports, RenderFrameResult::kVulkanFailure);
}

// ---------------------------------------------------------------------------
// P5-OVERLAYS-TRANSITION-COMP-N1 native-only seam: renderTransitionFrame with
// an optional set of already-resolved overlay draws recorded into the SAME
// final swapchain render pass, immediately after the transition layer draws.
// Mirrors renderTransitionFrame above's entire acquire / frame-fence /
// pending-AHB-semaphore / release-fence-export / present protocol; the only
// differences are (1) overlay caller-data validation right after placement
// resolution and strictly before any Vulkan mutation, and (2) the command
// buffer is always begun explicitly here (rather than via
// VulkanGraphicsCommandRecorder::recordTransitionPass, which cannot leave
// the render pass open for overlay draws) and closed via
// recordTransitionPassBodyKeepOpen + VulkanOverlayFrameRenderer::
// recordOverlayDraws + vkCmdEndRenderPass + vkEndCommandBuffer. When
// overlayCount == 0 this delegates directly to the overload above with zero
// additional Vulkan calls, so non-overlay transition behavior (including
// that overload's exact command stream) is completely unaffected by this
// overload's existence.
//
// N1 is native-only: no JNI/Kotlin route calls this yet.
// ---------------------------------------------------------------------------

RenderFrameResult VulkanFrameRenderer::renderTransitionFrame(
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
    const VideoBeautyV2RenderParams& fromBeauty,
    const VideoBeautyV2RenderParams& toBeauty) {
    if (overlayCount == 0) {
        return renderTransitionFrame(queueHandle, physicalDeviceHandle, swapchain, ahbImports,
                                     coreShaders, fromHandle, toHandle, transition, fromBeauty,
                                     toBeauty);
    }
    if (!impl_ || !impl_->initialized) {
        return RenderFrameResult::kBackendNotInitialized;
    }
    Impl& s = *impl_;
    if (queueHandle == nullptr || s.device == VK_NULL_HANDLE ||
        s.commandPool == VK_NULL_HANDLE) {
        return RenderFrameResult::kVulkanFailure;
    }
    const bool anyBeauty = fromBeauty.enabled || toBeauty.enabled;
    if (anyBeauty && physicalDeviceHandle == nullptr) {
        return RenderFrameResult::kVulkanFailure;
    }
    if (!swapchain.hasSurface()) {
        return RenderFrameResult::kNoSurface;
    }
    if (fromHandle == toHandle) {
        return RenderFrameResult::kInvalidBufferHandle;
    }
    const VulkanHardwareBufferImage* fromImage = ahbImports.getImage(fromHandle);
    const VulkanHardwareBufferImage* toImage = ahbImports.getImage(toHandle);
    if (!ahbImports.hasBuffer(fromHandle) || fromImage == nullptr ||
        !ahbImports.hasBuffer(toHandle) || toImage == nullptr) {
        return RenderFrameResult::kInvalidBufferHandle;
    }
    if (fromImage->image == VK_NULL_HANDLE || toImage->image == VK_NULL_HANDLE ||
        coreShaders.vertex.get() == VK_NULL_HANDLE ||
        coreShaders.fragment.get() == VK_NULL_HANDLE ||
        !s.frameSync || !s.frameSync->isInitialized()) {
        return RenderFrameResult::kVulkanFailure;
    }

    VulkanTransitionDrawMode mode;
    if (!ResolveVulkanTransitionDrawMode(transition, &mode)) {
        VGLOG_VFR("renderTransitionFrame(overlay): non-finite weights/progress or non-identity "
                  "crossfade geometry; failing closed");
        return RenderFrameResult::kVulkanFailure;
    }

    const uint32_t frameCount = s.frameSync->getFrameCount();
    if (frameCount == 0 || s.currentFrameIndex >= frameCount) {
        return RenderFrameResult::kVulkanFailure;
    }
    const VulkanFrameSyncResources* frame =
        s.frameSync->getFrame(s.currentFrameIndex);
    if (frame == nullptr || frame->commandBuffer == VK_NULL_HANDLE ||
        frame->imageAvailableSemaphore == VK_NULL_HANDLE ||
        frame->inFlightFence == VK_NULL_HANDLE) {
        return RenderFrameResult::kVulkanFailure;
    }

    const uint64_t renderPassHandle = swapchain.getRenderPassHandle();
    const uint32_t extentWidth = swapchain.getExtentWidth();
    const uint32_t extentHeight = swapchain.getExtentHeight();
    const VkPipelineLayout fromLayout = fromImage->descriptorResources.pipelineLayout;
    const VkDescriptorSet fromSet = fromImage->descriptorResources.descriptorSet;
    const VkPipelineLayout toLayout = toImage->descriptorResources.pipelineLayout;
    const VkDescriptorSet toSet = toImage->descriptorResources.descriptorSet;
    if (renderPassHandle == 0 || extentWidth == 0 || extentHeight == 0 ||
        fromLayout == VK_NULL_HANDLE || fromSet == VK_NULL_HANDLE ||
        toLayout == VK_NULL_HANDLE || toSet == VK_NULL_HANDLE) {
        return RenderFrameResult::kVulkanFailure;
    }
    const VkRenderPass renderPass = u64ToVkHandle<VkRenderPass>(renderPassHandle);

    // Placement is pure math; resolve it before creating any pipeline.
    VulkanTransitionLayerPlacement fromPlacement;
    VulkanTransitionLayerPlacement toPlacement;
    if (!ResolveVulkanTransitionLayerPlacement(transition.from, transition.fromViewport,
                                               transition.fromCrop, extentWidth, extentHeight,
                                               &fromPlacement) ||
        !ResolveVulkanTransitionLayerPlacement(transition.to, transition.toViewport,
                                               transition.toCrop, extentWidth, extentHeight,
                                               &toPlacement)) {
        VGLOG_VFR("renderTransitionFrame(overlay): invalid layer geometry; failing closed");
        return RenderFrameResult::kVulkanFailure;
    }

    // N1: validate overlay caller data now -- immediately after placement
    // resolution and strictly before any Vulkan mutation below (device idle
    // wait, pipeline (re)creation, fence wait, swapchain acquire) -- so
    // invalid caller-supplied overlay data fails closed without ever
    // touching Vulkan state.
    if (overlayDraws == nullptr) {
        return RenderFrameResult::kVulkanFailure;
    }
    if (!overlayFrameDrawsValid(overlayDraws, overlayCount, extentWidth, extentHeight)) {
        return RenderFrameResult::kVulkanFailure;
    }

    // Pipelines are per import layout, so every transition frame rebuilds
    // them. Any cached pipeline (solo or previous transition) may still be in
    // flight on the other frame slot: idle the device before destroying.
    if (vkDeviceWaitIdle(s.device) != VK_SUCCESS) {
        return RenderFrameResult::kVulkanFailure;
    }
    s.invalidatePipeline();

    const bool needFrom = mode != VulkanTransitionDrawMode::kToOnly;
    const bool needToOpaque =
        mode == VulkanTransitionDrawMode::kToOnly || mode == VulkanTransitionDrawMode::kPaintOver;
    const bool needToBlend = mode == VulkanTransitionDrawMode::kCrossfade;
    // A beautified layer is drawn through its own VulkanBeautyFrameRenderer
    // placement pipeline (built later, after prepareTransitionLayer runs),
    // never through an AHB-import-layout pipeline built here.
    if (needFrom && !fromBeauty.enabled) {
        s.transitionFromPipeline = std::make_unique<VulkanGraphicsPipeline>();
        if (!s.transitionFromPipeline->create(s.device, fromLayout, renderPass,
                                              coreShaders.vertex.get(),
                                              coreShaders.fragment.get())) {
            s.invalidatePipeline();
            return RenderFrameResult::kVulkanFailure;
        }
    }
    if (needToOpaque && !toBeauty.enabled) {
        s.transitionToOpaquePipeline = std::make_unique<VulkanGraphicsPipeline>();
        if (!s.transitionToOpaquePipeline->create(s.device, toLayout, renderPass,
                                                  coreShaders.vertex.get(),
                                                  coreShaders.fragment.get())) {
            s.invalidatePipeline();
            return RenderFrameResult::kVulkanFailure;
        }
    }
    if (needToBlend && !toBeauty.enabled) {
        if (!CreateVulkanTransitionBlendPipeline(s.device, toLayout, renderPass,
                                                 coreShaders.vertex.get(),
                                                 coreShaders.fragment.get(),
                                                 &s.transitionToBlendPipeline)) {
            s.invalidatePipeline();
            return RenderFrameResult::kVulkanFailure;
        }
    }

    if (!s.frameSync->waitForFrameFence(s.currentFrameIndex)) {
        return RenderFrameResult::kVulkanFailure;
    }
    ahbImports.drainRetiredForFrame(s.currentFrameIndex);

    uint32_t imageIndex = 0;
    const SwapchainResult acquireResult = swapchain.acquireNextImage(
        vkHandleToU64(frame->imageAvailableSemaphore),
        0,
        &imageIndex,
        UINT64_MAX);
    switch (acquireResult) {
        case SwapchainResult::kSuccess:
        case SwapchainResult::kSuboptimal:
            break;
        case SwapchainResult::kOutOfDate:
            return RenderFrameResult::kOutOfDate;
        case SwapchainResult::kSurfaceLost:
            return RenderFrameResult::kSurfaceLost;
        case SwapchainResult::kDeviceLost:
            return RenderFrameResult::kDeviceLost;
        case SwapchainResult::kError:
            return RenderFrameResult::kVulkanFailure;
    }

    const uint64_t framebufferHandle = swapchain.getFramebufferHandle(imageIndex);
    if (framebufferHandle == 0) {
        return s.failClosed(swapchain, ahbImports, RenderFrameResult::kVulkanFailure);
    }
    const VkFramebuffer framebuffer = u64ToVkHandle<VkFramebuffer>(framebufferHandle);

    const uint64_t presentReadySemaphoreHandle =
        swapchain.getPresentReadySemaphoreHandle(imageIndex);
    if (presentReadySemaphoreHandle == 0) {
        return s.failClosed(swapchain, ahbImports, RenderFrameResult::kVulkanFailure);
    }
    const VkSemaphore presentReadySemaphore =
        u64ToVkHandle<VkSemaphore>(presentReadySemaphoreHandle);

    if (!s.frameSync->resetCommandBuffer(s.currentFrameIndex)) {
        return s.failClosed(swapchain, ahbImports, RenderFrameResult::kVulkanFailure);
    }

    VulkanTransitionPassParams passParams{};
    passParams.commandBuffer = frame->commandBuffer;
    passParams.renderPass = renderPass;
    passParams.framebuffer = framebuffer;
    passParams.extentWidth = extentWidth;
    passParams.extentHeight = extentHeight;
    const VkImageLayout fromLayoutState =
        static_cast<VkImageLayout>(ahbImports.getImageLayout(fromHandle));
    const VkImageLayout toLayoutState =
        static_cast<VkImageLayout>(ahbImports.getImageLayout(toHandle));
    passParams.fromImage = fromImage;
    passParams.fromOldLayout = VK_IMAGE_LAYOUT_UNDEFINED;
    // A beautified layer's own crop pass (run by prepareTransitionLayer
    // below) already performs the AHB layout transition when its current
    // layout is undefined, so this pass must not transition it again.
    passParams.transitionFromImage =
        fromBeauty.enabled ? false : (fromLayoutState == VK_IMAGE_LAYOUT_UNDEFINED);
    passParams.toImage = toImage;
    passParams.toOldLayout = VK_IMAGE_LAYOUT_UNDEFINED;
    passParams.transitionToImage =
        toBeauty.enabled ? false : (toLayoutState == VK_IMAGE_LAYOUT_UNDEFINED);

    // Unlike the non-overlay overload above (which uses
    // VulkanGraphicsCommandRecorder::recordTransitionPass /
    // recordTransitionPassBody to begin/end the command buffer itself), this
    // overlay path always begins the command buffer explicitly so overlay
    // draws can be appended into the same open render pass afterward.
    VkCommandBufferBeginInfo beginInfo{};
    beginInfo.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
    if (vkBeginCommandBuffer(frame->commandBuffer, &beginInfo) != VK_SUCCESS) {
        return s.failClosed(swapchain, ahbImports, RenderFrameResult::kVulkanFailure);
    }

    VulkanTransitionLayerResources fromRes;
    VulkanTransitionLayerResources toRes;

    if (!anyBeauty) {
        // Byte-identical construction to the pre-existing non-beauty
        // transition path's fromRes/toRes.
        fromRes.pipeline = s.transitionFromPipeline ? s.transitionFromPipeline->get() : VK_NULL_HANDLE;
        fromRes.pipelineLayout = fromLayout;
        fromRes.descriptorSet = fromSet;
        fromRes.pushConstants = makeVideoTransformFullPushConstants(transition.from);

        toRes.pipelineLayout = toLayout;
        toRes.descriptorSet = toSet;
        toRes.pushConstants = makeVideoTransformFullPushConstants(transition.to);
        if (needToBlend) {
            toRes.pipeline = s.transitionToBlendPipeline;
            toRes.useBlendConstants = true;
            toRes.blendConstant =
                static_cast<float>(std::max(0.0, std::min(1.0, transition.blendWeightTo)));
        } else if (s.transitionToOpaquePipeline) {
            toRes.pipeline = s.transitionToOpaquePipeline->get();
        }
    } else {
        // Beauty transition path: vkBeginCommandBuffer already happened
        // above; run the beauty prepasses and resource construction exactly
        // as the existing beauty branch, including the blend pipeline built
        // with Beauty's placement pipeline layout for a beautified "to"
        // crossfade.
        if (!s.beautyRendererFrom) {
            s.beautyRendererFrom = std::make_unique<VulkanBeautyFrameRenderer>();
        }
        if (!s.beautyRendererTo) {
            s.beautyRendererTo = std::make_unique<VulkanBeautyFrameRenderer>();
        }

        VulkanBeautyTransitionLayerResources fromBeautyRes;
        VulkanBeautyTransitionLayerResources toBeautyRes;
        std::string beautyFailureReason;
        const auto physDev = static_cast<VkPhysicalDevice>(physicalDeviceHandle);

        if (fromBeauty.enabled) {
            if (!s.beautyRendererFrom->prepareTransitionLayer(
                    s.device, physDev, frame->commandBuffer, s.currentFrameIndex, frameCount,
                    *fromImage, fromLayoutState, coreShaders.vertex.get(), coreShaders.fragment.get(),
                    transition.from, fromBeauty, renderPass, &fromBeautyRes, &beautyFailureReason)) {
                VGLOG_VFR("transition overlay beauty prepareTransitionLayer(from) failed: %s",
                          beautyFailureReason.c_str());
                abandonRecordingCommandBuffer(frame->commandBuffer);
                return s.failClosed(swapchain, ahbImports, RenderFrameResult::kVulkanFailure);
            }
        }
        if (toBeauty.enabled) {
            if (!s.beautyRendererTo->prepareTransitionLayer(
                    s.device, physDev, frame->commandBuffer, s.currentFrameIndex, frameCount,
                    *toImage, toLayoutState, coreShaders.vertex.get(), coreShaders.fragment.get(),
                    transition.to, toBeauty, renderPass, &toBeautyRes, &beautyFailureReason)) {
                VGLOG_VFR("transition overlay beauty prepareTransitionLayer(to) failed: %s",
                          beautyFailureReason.c_str());
                abandonRecordingCommandBuffer(frame->commandBuffer);
                return s.failClosed(swapchain, ahbImports, RenderFrameResult::kVulkanFailure);
            }
        }

        // Pipeline-layout correctness: a beautified "to" layer blended for
        // crossfade needs a blend pipeline built with Beauty's placement
        // pipeline layout, never the AHB import layout.
        if (needToBlend && toBeauty.enabled) {
            if (!CreateVulkanTransitionBlendPipeline(s.device, toBeautyRes.pipelineLayout, renderPass,
                                                     coreShaders.vertex.get(), coreShaders.fragment.get(),
                                                     &s.transitionToBlendPipeline)) {
                abandonRecordingCommandBuffer(frame->commandBuffer);
                return s.failClosed(swapchain, ahbImports, RenderFrameResult::kVulkanFailure);
            }
        }

        if (fromBeauty.enabled) {
            fromRes.pipeline = fromBeautyRes.pipeline;
            fromRes.pipelineLayout = fromBeautyRes.pipelineLayout;
            fromRes.descriptorSet = fromBeautyRes.descriptorSet;
            fromRes.pushConstants = makeVideoTransformFullPushConstants(fromBeautyRes.placementTransform);
        } else {
            fromRes.pipeline = s.transitionFromPipeline ? s.transitionFromPipeline->get() : VK_NULL_HANDLE;
            fromRes.pipelineLayout = fromLayout;
            fromRes.descriptorSet = fromSet;
            fromRes.pushConstants = makeVideoTransformFullPushConstants(transition.from);
        }

        if (toBeauty.enabled) {
            toRes.pipelineLayout = toBeautyRes.pipelineLayout;
            toRes.descriptorSet = toBeautyRes.descriptorSet;
            toRes.pushConstants = makeVideoTransformFullPushConstants(toBeautyRes.placementTransform);
        } else {
            toRes.pipelineLayout = toLayout;
            toRes.descriptorSet = toSet;
            toRes.pushConstants = makeVideoTransformFullPushConstants(transition.to);
        }
        if (needToBlend) {
            toRes.pipeline = s.transitionToBlendPipeline;
            toRes.useBlendConstants = true;
            toRes.blendConstant =
                static_cast<float>(std::max(0.0, std::min(1.0, transition.blendWeightTo)));
        } else if (toBeauty.enabled) {
            toRes.pipeline = toBeautyRes.pipeline;
        } else if (s.transitionToOpaquePipeline) {
            toRes.pipeline = s.transitionToOpaquePipeline->get();
        }
    }

    // Shared transition mode plan switch: identical to the non-beauty and
    // beauty branches above, appending each layer's draws to passParams.
    bool planOk = true;
    switch (mode) {
        case VulkanTransitionDrawMode::kFromOnly:
            planOk = AppendVulkanTransitionLayer(&passParams, fromRes, fromPlacement, false);
            break;
        case VulkanTransitionDrawMode::kToOnly:
            planOk = AppendVulkanTransitionLayer(&passParams, toRes, toPlacement, false);
            break;
        case VulkanTransitionDrawMode::kPaintOver:
        case VulkanTransitionDrawMode::kCrossfade:
            planOk = AppendVulkanTransitionLayer(&passParams, fromRes, fromPlacement, false) &&
                     AppendVulkanTransitionLayer(&passParams, toRes, toPlacement, true);
            break;
    }
    if (!planOk) {
        // The command buffer is recording but no render pass has been opened
        // yet: close it best-effort before failClosed, never
        // vkCmdEndRenderPass on this path.
        abandonRecordingCommandBuffer(frame->commandBuffer);
        return s.failClosed(swapchain, ahbImports, RenderFrameResult::kVulkanFailure);
    }

    if (!VulkanGraphicsCommandRecorder::recordTransitionPassBodyKeepOpen(passParams)) {
        // recordTransitionPassBodyKeepOpen validates its params BEFORE
        // opening the render pass, so a false return here leaves the command
        // buffer recording with no render pass ever opened.
        abandonRecordingCommandBuffer(frame->commandBuffer);
        return s.failClosed(swapchain, ahbImports, RenderFrameResult::kVulkanFailure);
    }

    if (!s.overlayRenderer) {
        s.overlayRenderer = std::make_unique<VulkanOverlayFrameRenderer>();
    }
    std::string overlayFailureReason;
    const bool overlayOk = s.overlayRenderer->recordOverlayDraws(
        static_cast<void*>(s.device),
        static_cast<void*>(frame->commandBuffer),
        reinterpret_cast<void*>(coreShaders.vertex.get()),
        reinterpret_cast<void*>(coreShaders.fragment.get()),
        renderPassHandle,
        extentWidth,
        extentHeight,
        overlayDraws,
        overlayCount,
        &overlayFailureReason);
    if (!overlayOk) {
        VGLOG_VFR("transition overlay recordOverlayDraws failed: %s", overlayFailureReason.c_str());
        // recordTransitionPassBodyKeepOpen already opened the render pass
        // above; overlayFrameDrawsValid() already ruled out invalid caller
        // data before either happened, so this is a genuine resource
        // failure. Close the open render pass / command buffer best-effort
        // before failClosed -- never submit or present on this path.
        abandonOpenRenderPass(frame->commandBuffer);
        return s.failClosed(swapchain, ahbImports, RenderFrameResult::kVulkanFailure);
    }

    vkCmdEndRenderPass(frame->commandBuffer);
    if (vkEndCommandBuffer(frame->commandBuffer) != VK_SUCCESS) {
        return s.failClosed(swapchain, ahbImports, RenderFrameResult::kVulkanFailure);
    }

    if (!s.frameSync->resetFrameFence(s.currentFrameIndex)) {
        return s.failClosed(swapchain, ahbImports, RenderFrameResult::kVulkanFailure);
    }

    VkSemaphore waitSemaphores[3] = {
        frame->imageAvailableSemaphore,
        VK_NULL_HANDLE,
        VK_NULL_HANDLE,
    };
    VkPipelineStageFlags waitStages[3] = {
        VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
        VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT,
        VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT,
    };
    uint32_t waitSemaphoreCount = 1;
    const uint64_t fromPendingAcquire = ahbImports.getPendingAcquireSemaphoreHandle(fromHandle);
    const uint64_t toPendingAcquire = ahbImports.getPendingAcquireSemaphoreHandle(toHandle);
    if (fromPendingAcquire != 0) {
        waitSemaphores[waitSemaphoreCount++] = u64ToVkHandle<VkSemaphore>(fromPendingAcquire);
    }
    if (toPendingAcquire != 0 && toPendingAcquire != fromPendingAcquire) {
        waitSemaphores[waitSemaphoreCount++] = u64ToVkHandle<VkSemaphore>(toPendingAcquire);
    }

    const bool canExportRelease =
        (frame->releaseFenceSemaphore != VK_NULL_HANDLE) && (s.pfnGetSemaphoreFd != nullptr);

    VkSemaphore signalSemaphores[2] = {
        presentReadySemaphore,
        VK_NULL_HANDLE,
    };
    uint32_t signalSemaphoreCount = 1;
    if (canExportRelease) {
        signalSemaphores[signalSemaphoreCount++] = frame->releaseFenceSemaphore;
    }

    VkSubmitInfo submitInfo{};
    submitInfo.sType = VK_STRUCTURE_TYPE_SUBMIT_INFO;
    submitInfo.waitSemaphoreCount = waitSemaphoreCount;
    submitInfo.pWaitSemaphores = waitSemaphores;
    submitInfo.pWaitDstStageMask = waitStages;
    submitInfo.commandBufferCount = 1;
    submitInfo.pCommandBuffers = &frame->commandBuffer;
    submitInfo.signalSemaphoreCount = signalSemaphoreCount;
    submitInfo.pSignalSemaphores = signalSemaphores;

    const VkQueue queue = static_cast<VkQueue>(queueHandle);
    const VkResult submitResult =
        vkQueueSubmit(queue, 1, &submitInfo, frame->inFlightFence);
    if (submitResult != VK_SUCCESS) {
        const RenderFrameResult result =
            (submitResult == VK_ERROR_DEVICE_LOST)
                ? RenderFrameResult::kDeviceLost
                : RenderFrameResult::kVulkanFailure;
        return s.failClosed(swapchain, ahbImports, result);
    }

    // Both imports were consumed by this submission: tag both records with
    // the frame slot so their deferred retirement waits for this fence.
    if (!ahbImports.markBufferSubmitted(fromHandle, s.currentFrameIndex) ||
        !ahbImports.markBufferSubmitted(toHandle, s.currentFrameIndex)) {
        VGLOG_VFR("transition overlay markBufferSubmitted failed for handles %" PRIu64 "/%" PRIu64
                  "; failing closed",
                  static_cast<uint64_t>(fromHandle), static_cast<uint64_t>(toHandle));
        return s.failClosed(swapchain, ahbImports, RenderFrameResult::kVulkanFailure);
    }

    // Release-fence export (see renderFrame): a sync-fd export has wait
    // semantics on the semaphore payload, so export exactly once and hand the
    // "to" record a dup() of the same fd (or -1 when no fd was produced).
    {
        if (canExportRelease) {
            int exportedFd = -1;
            VkSemaphoreGetFdInfoKHR semGetFdInfo{};
            semGetFdInfo.sType      = VK_STRUCTURE_TYPE_SEMAPHORE_GET_FD_INFO_KHR;
            semGetFdInfo.pNext      = nullptr;
            semGetFdInfo.semaphore  = frame->releaseFenceSemaphore;
            semGetFdInfo.handleType = VK_EXTERNAL_SEMAPHORE_HANDLE_TYPE_SYNC_FD_BIT;
            const VkResult exportResult =
                s.pfnGetSemaphoreFd(s.device, &semGetFdInfo, &exportedFd);
            if (exportResult != VK_SUCCESS) {
                VGLOG_VFR("transition overlay vkGetSemaphoreFdKHR failed: %d; clearing stored release fds",
                          static_cast<int>(exportResult));
                if (exportedFd >= 0) {
                    ::close(exportedFd);
                }
                ahbImports.setLatestReleaseFenceFd(fromHandle, -1);
                ahbImports.setLatestReleaseFenceFd(toHandle, -1);
                return s.failClosed(swapchain, ahbImports, RenderFrameResult::kVulkanFailure);
            }
            int dupFd = -1;
            if (exportedFd >= 0) {
                dupFd = ::dup(exportedFd);
                if (dupFd < 0) dupFd = -1;
            }
            ahbImports.setLatestReleaseFenceFd(fromHandle, exportedFd);
            ahbImports.setLatestReleaseFenceFd(toHandle, dupFd);
        } else {
            ahbImports.setLatestReleaseFenceFd(fromHandle, -1);
            ahbImports.setLatestReleaseFenceFd(toHandle, -1);
        }
    }

    if ((fromPendingAcquire != 0 && !ahbImports.markAcquireSemaphoreSubmitted(fromHandle)) ||
        (toPendingAcquire != 0 && !ahbImports.markAcquireSemaphoreSubmitted(toHandle))) {
        return s.failClosed(swapchain, ahbImports, RenderFrameResult::kVulkanFailure);
    }

    if (!ahbImports.setImageLayout(
            fromHandle, static_cast<uint32_t>(VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL)) ||
        !ahbImports.setImageLayout(
            toHandle, static_cast<uint32_t>(VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL))) {
        return s.failClosed(swapchain, ahbImports, RenderFrameResult::kVulkanFailure);
    }

    const SwapchainResult presentResult = swapchain.presentImage(
        queueHandle,
        presentReadySemaphoreHandle,
        imageIndex);
    s.currentFrameIndex = (s.currentFrameIndex + 1) % frameCount;

    switch (presentResult) {
        case SwapchainResult::kSuccess:
            return acquireResult == SwapchainResult::kSuboptimal
                ? RenderFrameResult::kSuboptimal
                : RenderFrameResult::kSuccess;
        case SwapchainResult::kSuboptimal:
            return RenderFrameResult::kSuboptimal;
        case SwapchainResult::kOutOfDate:
            return RenderFrameResult::kOutOfDate;
        case SwapchainResult::kSurfaceLost:
            return RenderFrameResult::kSurfaceLost;
        case SwapchainResult::kDeviceLost:
            return s.failClosed(swapchain, ahbImports, RenderFrameResult::kDeviceLost);
        case SwapchainResult::kError:
            return s.failClosed(swapchain, ahbImports, RenderFrameResult::kVulkanFailure);
    }

    return s.failClosed(swapchain, ahbImports, RenderFrameResult::kVulkanFailure);
}

// ANDROID-DUET-VULKAN-GREENSCREEN-VISUAL: Duet green-screen frame. Mirrors
// renderDuetLayoutFrame below's entire acquire / frame-fence / imageAvailable
// + presentReady semaphore / pending AHB acquire semaphore wait /
// release-fence export (one export, dup'd to the second import) / present
// protocol and its post-submit bookkeeping for both layer imports, and
// records the frame as:
//   1. (outside the render pass) the GPU mask import's first-use layout
//      transition, when a GPU mask is in use and still UNDEFINED;
//   2. VulkanGraphicsCommandRecorder::recordTransitionPassBodyKeepOpen with
//      the optional source / camera layout transitions, one clear render
//      pass, and the SOURCE layer draw only (opaque, aspect-filled into its
//      rect through its import's own descriptor resources + core passthrough
//      shaders, i.e. the same cached pipeline the layout path uses), leaving
//      the render pass OPEN;
//   3. VulkanGreenScreenFrameRenderer::recordCameraDraw appended into that
//      same render pass: the camera import's own external-format descriptor
//      set (set 0) alpha-masked by the mask (set 1), viewport / scissor / UV
//      crop from the SAME ResolveVulkanDuetLayoutLayerPlacement resolution
//      the layout path uses for the camera layer, straight-alpha blended
//      over the source layer;
//   4. vkCmdEndRenderPass / vkEndCommandBuffer here.
// The GPU mask import (held across frames by the session) additionally has
// its pending acquire semaphore waited and is marked submitted / transitioned
// after a successful submit; it is never released and never has a release
// sync-fd stored on it.
RenderFrameResult VulkanFrameRenderer::renderDuetGreenScreenFrame(
    void* queueHandle,
    VulkanSurfaceSwapchain& swapchain,
    VulkanHardwareBufferImports& ahbImports,
    VulkanCoreShaderModules& coreShaders,
    const DuetLayoutLayer& source,
    const DuetLayoutLayer& camera,
    const VulkanGreenScreenMaskInfo& maskInfo) {
    if (!impl_ || !impl_->initialized) {
        return RenderFrameResult::kBackendNotInitialized;
    }
    Impl& s = *impl_;
    if (queueHandle == nullptr || s.device == VK_NULL_HANDLE ||
        s.commandPool == VK_NULL_HANDLE) {
        return RenderFrameResult::kVulkanFailure;
    }
    if (!swapchain.hasSurface()) {
        return RenderFrameResult::kNoSurface;
    }
    if (source.handle == camera.handle) {
        return RenderFrameResult::kInvalidBufferHandle;
    }
    const VulkanHardwareBufferImage* sourceImage = ahbImports.getImage(source.handle);
    const VulkanHardwareBufferImage* cameraImage = ahbImports.getImage(camera.handle);
    if (!ahbImports.hasBuffer(source.handle) || sourceImage == nullptr ||
        !ahbImports.hasBuffer(camera.handle) || cameraImage == nullptr) {
        return RenderFrameResult::kInvalidBufferHandle;
    }
    if (sourceImage->image == VK_NULL_HANDLE || cameraImage->image == VK_NULL_HANDLE ||
        coreShaders.vertex.get() == VK_NULL_HANDLE ||
        coreShaders.fragment.get() == VK_NULL_HANDLE ||
        maskInfo.imageViewHandle == 0 || maskInfo.width == 0 || maskInfo.height == 0 ||
        !s.frameSync || !s.frameSync->isInitialized()) {
        return RenderFrameResult::kVulkanFailure;
    }

    // GPU mask import (held across frames by the session): must be an active
    // import distinct from both layers, non-external-format (it is sampled
    // through the green-screen helper's own mutable sampler, not an
    // immutable YCbCr one), and the view being sampled must be its own.
    const bool hasGpuMask = maskInfo.gpuMaskHandle != kInvalidHardwareBufferHandle;
    const VulkanHardwareBufferImage* gpuMaskImage = nullptr;
    if (hasGpuMask) {
        if (maskInfo.gpuMaskHandle == source.handle || maskInfo.gpuMaskHandle == camera.handle ||
            !ahbImports.hasBuffer(maskInfo.gpuMaskHandle)) {
            return RenderFrameResult::kInvalidBufferHandle;
        }
        gpuMaskImage = ahbImports.getImage(maskInfo.gpuMaskHandle);
        if (gpuMaskImage == nullptr || gpuMaskImage->image == VK_NULL_HANDLE ||
            gpuMaskImage->imageView == VK_NULL_HANDLE || gpuMaskImage->isExternalFormat() ||
            vkHandleToU64(gpuMaskImage->imageView) != maskInfo.imageViewHandle) {
            return RenderFrameResult::kVulkanFailure;
        }
    }

    const uint32_t frameCount = s.frameSync->getFrameCount();
    if (frameCount == 0 || s.currentFrameIndex >= frameCount) {
        return RenderFrameResult::kVulkanFailure;
    }
    const VulkanFrameSyncResources* frame = s.frameSync->getFrame(s.currentFrameIndex);
    if (frame == nullptr || frame->commandBuffer == VK_NULL_HANDLE ||
        frame->imageAvailableSemaphore == VK_NULL_HANDLE ||
        frame->inFlightFence == VK_NULL_HANDLE) {
        return RenderFrameResult::kVulkanFailure;
    }

    const uint64_t renderPassHandle = swapchain.getRenderPassHandle();
    const uint32_t extentWidth = swapchain.getExtentWidth();
    const uint32_t extentHeight = swapchain.getExtentHeight();
    const VkPipelineLayout sourceLayout = sourceImage->descriptorResources.pipelineLayout;
    const VkDescriptorSet sourceSet = sourceImage->descriptorResources.descriptorSet;
    const VkPipelineLayout cameraLayout = cameraImage->descriptorResources.pipelineLayout;
    const VkDescriptorSetLayout cameraSetLayout = cameraImage->descriptorResources.descriptorSetLayout;
    const VkDescriptorSet cameraSet = cameraImage->descriptorResources.descriptorSet;
    if (renderPassHandle == 0 || extentWidth == 0 || extentHeight == 0 ||
        sourceLayout == VK_NULL_HANDLE || sourceSet == VK_NULL_HANDLE ||
        cameraLayout == VK_NULL_HANDLE || cameraSetLayout == VK_NULL_HANDLE ||
        cameraSet == VK_NULL_HANDLE) {
        return RenderFrameResult::kVulkanFailure;
    }
    const VkRenderPass renderPass = u64ToVkHandle<VkRenderPass>(renderPassHandle);

    // Geometry is pure math; resolve (and fail closed) before any Vulkan
    // state is touched so an invalid rect never reaches the swapchain. Both
    // layers go through the SAME placement helper as the layout path, which
    // is the single source of truth for rect / aspect-fill crop.
    VulkanDuetLayoutLayerGeometry sourceGeometry;
    sourceGeometry.rect = source.rect;
    sourceGeometry.bufferWidth = source.bufferWidth;
    sourceGeometry.bufferHeight = source.bufferHeight;
    sourceGeometry.rotationDegrees = source.rotationDegrees;
    sourceGeometry.mirrorHorizontal = source.mirrorHorizontal;
    VulkanDuetLayoutLayerGeometry cameraGeometry;
    cameraGeometry.rect = camera.rect;
    cameraGeometry.bufferWidth = camera.bufferWidth;
    cameraGeometry.bufferHeight = camera.bufferHeight;
    cameraGeometry.rotationDegrees = camera.rotationDegrees;
    cameraGeometry.mirrorHorizontal = camera.mirrorHorizontal;
    VulkanDuetLayoutLayerPlacement sourcePlacement;
    VulkanDuetLayoutLayerPlacement cameraPlacement;
    if (!ResolveVulkanDuetLayoutLayerPlacement(sourceGeometry, extentWidth, extentHeight,
                                               &sourcePlacement) ||
        !ResolveVulkanDuetLayoutLayerPlacement(cameraGeometry, extentWidth, extentHeight,
                                               &cameraPlacement)) {
        VGLOG_VFR("renderDuetGreenScreenFrame: invalid layer rect (source %d,%d %dx%d camera "
                  "%d,%d %dx%d extent %ux%u); failing closed",
                  source.rect.x, source.rect.y, source.rect.width, source.rect.height,
                  camera.rect.x, camera.rect.y, camera.rect.width, camera.rect.height,
                  extentWidth, extentHeight);
        return RenderFrameResult::kVulkanFailure;
    }

    // Source layer: the layout path's cached opaque per-layer pipeline pair
    // (one key for both paths, see Impl::ensureDuetLayoutPipelines).
    if (!s.ensureDuetLayoutPipelines(sourceLayout, cameraLayout, renderPassHandle, renderPass,
                                     coreShaders)) {
        return RenderFrameResult::kVulkanFailure;
    }

    // Camera layer: the green-screen helper's pipeline is keyed by the camera
    // import's descriptor set layout (immutable external-format sampler) and
    // the render pass. Like the pair above, a stale pipeline may still be in
    // flight on the other frame slot, so idle before invalidating.
    if (!s.greenScreenRenderer) {
        s.greenScreenRenderer = std::make_unique<VulkanGreenScreenFrameRenderer>();
    }
    const uint64_t cameraSetLayoutHandle = vkHandleToU64(cameraSetLayout);
    if (s.greenScreenRenderer->needsPipelineRebuild(cameraSetLayoutHandle, renderPassHandle)) {
        if (vkDeviceWaitIdle(s.device) != VK_SUCCESS) {
            return RenderFrameResult::kVulkanFailure;
        }
        s.greenScreenRenderer->invalidate(s.device);
    }

    if (!s.frameSync->waitForFrameFence(s.currentFrameIndex)) {
        return RenderFrameResult::kVulkanFailure;
    }
    ahbImports.drainRetiredForFrame(s.currentFrameIndex);

    uint32_t imageIndex = 0;
    const SwapchainResult acquireResult = swapchain.acquireNextImage(
        vkHandleToU64(frame->imageAvailableSemaphore), 0, &imageIndex, UINT64_MAX);
    switch (acquireResult) {
        case SwapchainResult::kSuccess:
        case SwapchainResult::kSuboptimal:
            break;
        case SwapchainResult::kOutOfDate:
            return RenderFrameResult::kOutOfDate;
        case SwapchainResult::kSurfaceLost:
            return RenderFrameResult::kSurfaceLost;
        case SwapchainResult::kDeviceLost:
            return RenderFrameResult::kDeviceLost;
        case SwapchainResult::kError:
            return RenderFrameResult::kVulkanFailure;
    }

    const uint64_t framebufferHandle = swapchain.getFramebufferHandle(imageIndex);
    const uint64_t presentReadySemaphoreHandle =
        swapchain.getPresentReadySemaphoreHandle(imageIndex);
    if (framebufferHandle == 0 || presentReadySemaphoreHandle == 0) {
        return s.failClosed(swapchain, ahbImports, RenderFrameResult::kVulkanFailure);
    }
    const VkFramebuffer framebuffer = u64ToVkHandle<VkFramebuffer>(framebufferHandle);
    const VkSemaphore presentReadySemaphore =
        u64ToVkHandle<VkSemaphore>(presentReadySemaphoreHandle);

    if (!s.frameSync->resetCommandBuffer(s.currentFrameIndex)) {
        return s.failClosed(swapchain, ahbImports, RenderFrameResult::kVulkanFailure);
    }
    VkCommandBufferBeginInfo beginInfo{};
    beginInfo.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
    if (vkBeginCommandBuffer(frame->commandBuffer, &beginInfo) != VK_SUCCESS) {
        return s.failClosed(swapchain, ahbImports, RenderFrameResult::kVulkanFailure);
    }

    // 1. GPU mask first-use layout transition (outside the render pass, same
    //    stage / access masks as the layer imports' transitions).
    if (gpuMaskImage != nullptr &&
        ahbImports.getImageLayout(maskInfo.gpuMaskHandle) ==
            static_cast<uint32_t>(VK_IMAGE_LAYOUT_UNDEFINED)) {
        gpuMaskImage->recordLayoutTransition(
            frame->commandBuffer,
            VK_IMAGE_LAYOUT_UNDEFINED,
            VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
            VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT,
            VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT,
            0,
            VK_ACCESS_SHADER_READ_BIT);
    }

    // 2. Source / camera transitions, clear render pass, source layer draw;
    //    render pass left open.
    VulkanTransitionPassParams passParams{};
    passParams.commandBuffer = frame->commandBuffer;
    passParams.renderPass = renderPass;
    passParams.framebuffer = framebuffer;
    passParams.extentWidth = extentWidth;
    passParams.extentHeight = extentHeight;
    passParams.fromImage = sourceImage;
    passParams.fromOldLayout = VK_IMAGE_LAYOUT_UNDEFINED;
    passParams.transitionFromImage =
        ahbImports.getImageLayout(source.handle) ==
        static_cast<uint32_t>(VK_IMAGE_LAYOUT_UNDEFINED);
    passParams.toImage = cameraImage;
    passParams.toOldLayout = VK_IMAGE_LAYOUT_UNDEFINED;
    passParams.transitionToImage =
        ahbImports.getImageLayout(camera.handle) ==
        static_cast<uint32_t>(VK_IMAGE_LAYOUT_UNDEFINED);

    VulkanTransitionLayerResources sourceRes;
    sourceRes.pipeline = s.duetLayoutSourcePipeline->get();
    sourceRes.pipelineLayout = sourceLayout;
    sourceRes.descriptorSet = sourceSet;
    if (!AppendVulkanDuetLayoutLayer(&passParams, sourceRes, sourcePlacement)) {
        abandonRecordingCommandBuffer(frame->commandBuffer);
        return s.failClosed(swapchain, ahbImports, RenderFrameResult::kVulkanFailure);
    }
    // Validates every handle / extent / scissor before recording anything
    // (nothing is recorded on a validation failure, so no render pass is
    // open on that path).
    if (!VulkanGraphicsCommandRecorder::recordTransitionPassBodyKeepOpen(passParams)) {
        abandonRecordingCommandBuffer(frame->commandBuffer);
        return s.failClosed(swapchain, ahbImports, RenderFrameResult::kVulkanFailure);
    }

    // 3. Camera layer, alpha-masked, into the same open render pass.
    VulkanGreenScreenCameraDraw cameraDraw{};
    cameraDraw.cameraDescriptorSetLayout = cameraSetLayoutHandle;
    cameraDraw.cameraDescriptorSet = vkHandleToU64(cameraSet);
    cameraDraw.maskImageView = maskInfo.imageViewHandle;
    cameraDraw.maskWidth = maskInfo.width;
    cameraDraw.maskHeight = maskInfo.height;
    cameraDraw.debugMode = maskInfo.debugMode;
    cameraDraw.viewportX = cameraPlacement.viewport.x;
    cameraDraw.viewportY = cameraPlacement.viewport.y;
    cameraDraw.viewportWidth = cameraPlacement.viewport.width();
    cameraDraw.viewportHeight = cameraPlacement.viewport.height();
    cameraDraw.scissorX = cameraPlacement.scissor.x;
    cameraDraw.scissorY = cameraPlacement.scissor.y;
    cameraDraw.scissorWidth = cameraPlacement.scissor.width();
    cameraDraw.scissorHeight = cameraPlacement.scissor.height();
    cameraDraw.pushConstants = cameraPlacement.pushConstants;
    std::string failureReason;
    if (!s.greenScreenRenderer->recordCameraDraw(
            s.device, frame->commandBuffer, renderPassHandle,
            extentWidth, extentHeight, cameraDraw, &failureReason)) {
        VGLOG_VFR("renderDuetGreenScreenFrame camera draw failed: %s", failureReason.c_str());
        abandonOpenRenderPass(frame->commandBuffer);
        return s.failClosed(swapchain, ahbImports, RenderFrameResult::kVulkanFailure);
    }

    // 4. Close the pass and the command buffer.
    vkCmdEndRenderPass(frame->commandBuffer);
    if (vkEndCommandBuffer(frame->commandBuffer) != VK_SUCCESS) {
        return s.failClosed(swapchain, ahbImports, RenderFrameResult::kVulkanFailure);
    }
    if (!s.frameSync->resetFrameFence(s.currentFrameIndex)) {
        return s.failClosed(swapchain, ahbImports, RenderFrameResult::kVulkanFailure);
    }

    // imageAvailable + up to three distinct pending AHB acquire semaphores
    // (source, camera, GPU mask).
    VkSemaphore waitSemaphores[4] = {
        frame->imageAvailableSemaphore, VK_NULL_HANDLE, VK_NULL_HANDLE, VK_NULL_HANDLE,
    };
    VkPipelineStageFlags waitStages[4] = {
        VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
        VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT,
        VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT,
        VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT,
    };
    uint32_t waitSemaphoreCount = 1;
    const uint64_t sourcePendingAcquire =
        ahbImports.getPendingAcquireSemaphoreHandle(source.handle);
    const uint64_t cameraPendingAcquire =
        ahbImports.getPendingAcquireSemaphoreHandle(camera.handle);
    const uint64_t maskPendingAcquire =
        hasGpuMask ? ahbImports.getPendingAcquireSemaphoreHandle(maskInfo.gpuMaskHandle) : 0;
    if (sourcePendingAcquire != 0) {
        waitSemaphores[waitSemaphoreCount++] = u64ToVkHandle<VkSemaphore>(sourcePendingAcquire);
    }
    if (cameraPendingAcquire != 0 && cameraPendingAcquire != sourcePendingAcquire) {
        waitSemaphores[waitSemaphoreCount++] = u64ToVkHandle<VkSemaphore>(cameraPendingAcquire);
    }
    if (maskPendingAcquire != 0 && maskPendingAcquire != sourcePendingAcquire &&
        maskPendingAcquire != cameraPendingAcquire) {
        waitSemaphores[waitSemaphoreCount++] = u64ToVkHandle<VkSemaphore>(maskPendingAcquire);
    }

    const bool canExportRelease =
        frame->releaseFenceSemaphore != VK_NULL_HANDLE && s.pfnGetSemaphoreFd != nullptr;
    VkSemaphore signalSemaphores[2] = {presentReadySemaphore, VK_NULL_HANDLE};
    uint32_t signalSemaphoreCount = 1;
    if (canExportRelease) {
        signalSemaphores[signalSemaphoreCount++] = frame->releaseFenceSemaphore;
    }

    VkSubmitInfo submitInfo{};
    submitInfo.sType = VK_STRUCTURE_TYPE_SUBMIT_INFO;
    submitInfo.waitSemaphoreCount = waitSemaphoreCount;
    submitInfo.pWaitSemaphores = waitSemaphores;
    submitInfo.pWaitDstStageMask = waitStages;
    submitInfo.commandBufferCount = 1;
    submitInfo.pCommandBuffers = &frame->commandBuffer;
    submitInfo.signalSemaphoreCount = signalSemaphoreCount;
    submitInfo.pSignalSemaphores = signalSemaphores;
    const VkResult submitResult = vkQueueSubmit(
        static_cast<VkQueue>(queueHandle), 1, &submitInfo, frame->inFlightFence);
    if (submitResult != VK_SUCCESS) {
        return s.failClosed(swapchain, ahbImports,
            submitResult == VK_ERROR_DEVICE_LOST
                ? RenderFrameResult::kDeviceLost : RenderFrameResult::kVulkanFailure);
    }

    // All three imports now belong to this submission, even if later
    // bookkeeping fails. The GPU mask is marked submitted so a later release
    // (UpdateGpuMask replacing it, or session teardown) retires it behind
    // this frame's fence instead of destroying an image the GPU may still be
    // sampling.
    const bool sourceAcquireMarked = sourcePendingAcquire == 0 ||
        ahbImports.markAcquireSemaphoreSubmitted(source.handle);
    const bool cameraAcquireMarked = cameraPendingAcquire == 0 ||
        ahbImports.markAcquireSemaphoreSubmitted(camera.handle);
    const bool maskAcquireMarked = maskPendingAcquire == 0 ||
        ahbImports.markAcquireSemaphoreSubmitted(maskInfo.gpuMaskHandle);
    const bool sourceSubmitted = ahbImports.markBufferSubmitted(source.handle, s.currentFrameIndex);
    const bool cameraSubmitted = ahbImports.markBufferSubmitted(camera.handle, s.currentFrameIndex);
    const bool maskSubmitted = !hasGpuMask ||
        ahbImports.markBufferSubmitted(maskInfo.gpuMaskHandle, s.currentFrameIndex);
    const bool sourceLayoutSet = ahbImports.setImageLayout(
        source.handle, static_cast<uint32_t>(VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL));
    const bool cameraLayoutSet = ahbImports.setImageLayout(
        camera.handle, static_cast<uint32_t>(VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL));
    const bool maskLayoutSet = !hasGpuMask || ahbImports.setImageLayout(
        maskInfo.gpuMaskHandle, static_cast<uint32_t>(VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL));
    if (!sourceAcquireMarked || !cameraAcquireMarked || !maskAcquireMarked ||
        !sourceSubmitted || !cameraSubmitted || !maskSubmitted ||
        !sourceLayoutSet || !cameraLayoutSet || !maskLayoutSet) {
        return s.failClosed(swapchain, ahbImports, RenderFrameResult::kVulkanFailure);
    }

    int sourceReleaseFd = -1;
    int cameraReleaseFd = -1;
    if (canExportRelease) {
        VkSemaphoreGetFdInfoKHR semGetFdInfo{};
        semGetFdInfo.sType = VK_STRUCTURE_TYPE_SEMAPHORE_GET_FD_INFO_KHR;
        semGetFdInfo.semaphore = frame->releaseFenceSemaphore;
        semGetFdInfo.handleType = VK_EXTERNAL_SEMAPHORE_HANDLE_TYPE_SYNC_FD_BIT;
        const VkResult exportResult =
            s.pfnGetSemaphoreFd(s.device, &semGetFdInfo, &sourceReleaseFd);
        if (exportResult != VK_SUCCESS) {
            VGLOG_VFR("duet green-screen vkGetSemaphoreFdKHR failed: %d",
                      static_cast<int>(exportResult));
            if (sourceReleaseFd >= 0) ::close(sourceReleaseFd);
            ahbImports.setLatestReleaseFenceFd(source.handle, -1);
            ahbImports.setLatestReleaseFenceFd(camera.handle, -1);
            return s.failClosed(swapchain, ahbImports, RenderFrameResult::kVulkanFailure);
        }
        // Export consumes the semaphore payload: share that single sync-fd with both inputs.
        if (sourceReleaseFd >= 0) {
            cameraReleaseFd = ::dup(sourceReleaseFd);
            if (cameraReleaseFd < 0) {
                VGLOG_VFR("duet green-screen release sync-fd dup failed; failing closed");
                ::close(sourceReleaseFd);
                ahbImports.setLatestReleaseFenceFd(source.handle, -1);
                ahbImports.setLatestReleaseFenceFd(camera.handle, -1);
                return s.failClosed(swapchain, ahbImports, RenderFrameResult::kVulkanFailure);
            }
        }
    }
    // Each setter consumes its fd even on failure; attempt both without short-circuiting.
    // With no export support (or an empty sync-fd), -1 clears both stale stored fds.
    const bool sourceReleaseStored =
        ahbImports.setLatestReleaseFenceFd(source.handle, sourceReleaseFd);
    const bool cameraReleaseStored =
        ahbImports.setLatestReleaseFenceFd(camera.handle, cameraReleaseFd);
    if (!sourceReleaseStored || !cameraReleaseStored) {
        ahbImports.setLatestReleaseFenceFd(source.handle, -1);
        ahbImports.setLatestReleaseFenceFd(camera.handle, -1);
        return s.failClosed(swapchain, ahbImports, RenderFrameResult::kVulkanFailure);
    }

    if (!s.greenScreenFirstFrameLogged) {
        s.greenScreenFirstFrameLogged = true;
        // maskUv reports the actual GLSL matte-sampling policy selected by
        // maskInfo.debugMode (see glsl/greenscreen_blend.frag): normal mode
        // (0) samples the RAW camera-rect UV with Y flipped, eroded by one
        // mask texel and shaped with smoothstep (raw_flip_y_eroded); modes
        // 1..4 are the RND direct/mapped/mirror/flip diagnostics and report
        // their own shader-side name verbatim.
        const char* maskUvLabel = "raw_flip_y_eroded";
        switch (maskInfo.debugMode) {
            case 1: maskUvLabel = "mask_direct"; break;
            case 2: maskUvLabel = "mask_mapped"; break;
            case 3: maskUvLabel = "mask_direct_mirror_x"; break;
            case 4: maskUvLabel = "mask_direct_flip_y"; break;
            default: break;
        }
        VGLOG_VFR("ANDROID_DUET_VULKAN_GREENSCREEN_VISUAL_FIRST canvas=%ux%u "
                  "source=%d,%d %dx%d buf=%ux%u camera=%d,%d %dx%d buf=%ux%u "
                  "mask=%ux%u maskSource=%s debugMode=%d maskUv=%s "
                  "sourceRot=%u sourceMirror=%d cameraRot=%u cameraMirror=%d",
                  extentWidth, extentHeight,
                  source.rect.x, source.rect.y, source.rect.width, source.rect.height,
                  source.bufferWidth, source.bufferHeight,
                  camera.rect.x, camera.rect.y, camera.rect.width, camera.rect.height,
                  camera.bufferWidth, camera.bufferHeight,
                  maskInfo.width, maskInfo.height,
                  hasGpuMask ? "gpu_import" : "cpu_upload",
                  maskInfo.debugMode, maskUvLabel,
                  source.rotationDegrees, source.mirrorHorizontal ? 1 : 0,
                  camera.rotationDegrees, camera.mirrorHorizontal ? 1 : 0);
    }

    const SwapchainResult presentResult = swapchain.presentImage(
        queueHandle, presentReadySemaphoreHandle, imageIndex);
    s.currentFrameIndex = (s.currentFrameIndex + 1) % frameCount;
    switch (presentResult) {
        case SwapchainResult::kSuccess:
            return acquireResult == SwapchainResult::kSuboptimal
                ? RenderFrameResult::kSuboptimal : RenderFrameResult::kSuccess;
        case SwapchainResult::kSuboptimal:
            return RenderFrameResult::kSuboptimal;
        case SwapchainResult::kOutOfDate:
            return RenderFrameResult::kOutOfDate;
        case SwapchainResult::kSurfaceLost:
            return RenderFrameResult::kSurfaceLost;
        case SwapchainResult::kDeviceLost:
            return s.failClosed(swapchain, ahbImports, RenderFrameResult::kDeviceLost);
        case SwapchainResult::kError:
            return s.failClosed(swapchain, ahbImports, RenderFrameResult::kVulkanFailure);
    }
    return s.failClosed(swapchain, ahbImports, RenderFrameResult::kVulkanFailure);
}

// ANDROID-DUET-VULKAN-GREENSCREEN-STATIC-BACKGROUND (RND diagnostic only):
// camera-only Duet green-screen frame over a static clear-colour background.
// Mirrors renderDuetGreenScreenFrame above's acquire / frame-fence /
// imageAvailable + presentReady semaphore / pending AHB acquire semaphore
// wait / release-fence export / present protocol and its GPU-mask
// bookkeeping, but with NO source / decoder layer:
//   1. (outside the render pass) the GPU mask import's first-use layout
//      transition, when a GPU mask is in use and still UNDEFINED;
//   2. VulkanGraphicsCommandRecorder::recordTransitionPassBodyKeepOpen with
//      the optional camera layout transition, one render pass cleared to
//      background.clearRgba and ZERO layer draws (the recorder explicitly
//      supports a clear-only pass), leaving the render pass OPEN;
//   3. VulkanGreenScreenFrameRenderer::recordCameraDraw appended into that
//      same render pass, with the camera placement / mask / debugMode
//      resolved exactly as the production path resolves them;
//   4. vkCmdEndRenderPass / vkEndCommandBuffer here.
// Post-submit bookkeeping covers the single camera import (marked submitted,
// layout set, one release sync-fd stored -- no dup, there is no second
// import) plus the held GPU mask import exactly as in the production path.
RenderFrameResult VulkanFrameRenderer::renderDuetGreenScreenStaticBackgroundFrame(
    void* queueHandle,
    VulkanSurfaceSwapchain& swapchain,
    VulkanHardwareBufferImports& ahbImports,
    const DuetLayoutLayer& camera,
    const VulkanGreenScreenMaskInfo& maskInfo,
    const DuetStaticBackground& background) {
    if (!impl_ || !impl_->initialized) {
        return RenderFrameResult::kBackendNotInitialized;
    }
    Impl& s = *impl_;
    if (queueHandle == nullptr || s.device == VK_NULL_HANDLE ||
        s.commandPool == VK_NULL_HANDLE) {
        return RenderFrameResult::kVulkanFailure;
    }
    if (!swapchain.hasSurface()) {
        return RenderFrameResult::kNoSurface;
    }
    const VulkanHardwareBufferImage* cameraImage = ahbImports.getImage(camera.handle);
    if (!ahbImports.hasBuffer(camera.handle) || cameraImage == nullptr) {
        return RenderFrameResult::kInvalidBufferHandle;
    }
    if (cameraImage->image == VK_NULL_HANDLE ||
        maskInfo.imageViewHandle == 0 || maskInfo.width == 0 || maskInfo.height == 0 ||
        background.modeLabel == nullptr ||
        !s.frameSync || !s.frameSync->isInitialized()) {
        return RenderFrameResult::kVulkanFailure;
    }

    // GPU mask import: same validation as the production path (active,
    // distinct from the camera layer, non-external-format, own view).
    const bool hasGpuMask = maskInfo.gpuMaskHandle != kInvalidHardwareBufferHandle;
    const VulkanHardwareBufferImage* gpuMaskImage = nullptr;
    if (hasGpuMask) {
        if (maskInfo.gpuMaskHandle == camera.handle ||
            !ahbImports.hasBuffer(maskInfo.gpuMaskHandle)) {
            return RenderFrameResult::kInvalidBufferHandle;
        }
        gpuMaskImage = ahbImports.getImage(maskInfo.gpuMaskHandle);
        if (gpuMaskImage == nullptr || gpuMaskImage->image == VK_NULL_HANDLE ||
            gpuMaskImage->imageView == VK_NULL_HANDLE || gpuMaskImage->isExternalFormat() ||
            vkHandleToU64(gpuMaskImage->imageView) != maskInfo.imageViewHandle) {
            return RenderFrameResult::kVulkanFailure;
        }
    }

    const uint32_t frameCount = s.frameSync->getFrameCount();
    if (frameCount == 0 || s.currentFrameIndex >= frameCount) {
        return RenderFrameResult::kVulkanFailure;
    }
    const VulkanFrameSyncResources* frame = s.frameSync->getFrame(s.currentFrameIndex);
    if (frame == nullptr || frame->commandBuffer == VK_NULL_HANDLE ||
        frame->imageAvailableSemaphore == VK_NULL_HANDLE ||
        frame->inFlightFence == VK_NULL_HANDLE) {
        return RenderFrameResult::kVulkanFailure;
    }

    const uint64_t renderPassHandle = swapchain.getRenderPassHandle();
    const uint32_t extentWidth = swapchain.getExtentWidth();
    const uint32_t extentHeight = swapchain.getExtentHeight();
    const VkDescriptorSetLayout cameraSetLayout = cameraImage->descriptorResources.descriptorSetLayout;
    const VkDescriptorSet cameraSet = cameraImage->descriptorResources.descriptorSet;
    if (renderPassHandle == 0 || extentWidth == 0 || extentHeight == 0 ||
        cameraSetLayout == VK_NULL_HANDLE || cameraSet == VK_NULL_HANDLE) {
        return RenderFrameResult::kVulkanFailure;
    }
    const VkRenderPass renderPass = u64ToVkHandle<VkRenderPass>(renderPassHandle);

    // Camera placement through the SAME helper as the production green-screen
    // and layout paths (single source of truth for rect / aspect-fill crop /
    // rotation / mirror); resolved before any Vulkan state is touched.
    VulkanDuetLayoutLayerGeometry cameraGeometry;
    cameraGeometry.rect = camera.rect;
    cameraGeometry.bufferWidth = camera.bufferWidth;
    cameraGeometry.bufferHeight = camera.bufferHeight;
    cameraGeometry.rotationDegrees = camera.rotationDegrees;
    cameraGeometry.mirrorHorizontal = camera.mirrorHorizontal;
    VulkanDuetLayoutLayerPlacement cameraPlacement;
    if (!ResolveVulkanDuetLayoutLayerPlacement(cameraGeometry, extentWidth, extentHeight,
                                               &cameraPlacement)) {
        VGLOG_VFR("renderDuetGreenScreenStaticBackgroundFrame: invalid camera rect "
                  "(%d,%d %dx%d extent %ux%u); failing closed",
                  camera.rect.x, camera.rect.y, camera.rect.width, camera.rect.height,
                  extentWidth, extentHeight);
        return RenderFrameResult::kVulkanFailure;
    }

    // Camera layer: same green-screen helper pipeline cache / rebuild
    // protocol as the production path (keyed by the camera import's
    // descriptor set layout and the render pass; idle before invalidating).
    if (!s.greenScreenRenderer) {
        s.greenScreenRenderer = std::make_unique<VulkanGreenScreenFrameRenderer>();
    }
    const uint64_t cameraSetLayoutHandle = vkHandleToU64(cameraSetLayout);
    if (s.greenScreenRenderer->needsPipelineRebuild(cameraSetLayoutHandle, renderPassHandle)) {
        if (vkDeviceWaitIdle(s.device) != VK_SUCCESS) {
            return RenderFrameResult::kVulkanFailure;
        }
        s.greenScreenRenderer->invalidate(s.device);
    }

    if (!s.frameSync->waitForFrameFence(s.currentFrameIndex)) {
        return RenderFrameResult::kVulkanFailure;
    }
    ahbImports.drainRetiredForFrame(s.currentFrameIndex);

    uint32_t imageIndex = 0;
    const SwapchainResult acquireResult = swapchain.acquireNextImage(
        vkHandleToU64(frame->imageAvailableSemaphore), 0, &imageIndex, UINT64_MAX);
    switch (acquireResult) {
        case SwapchainResult::kSuccess:
        case SwapchainResult::kSuboptimal:
            break;
        case SwapchainResult::kOutOfDate:
            return RenderFrameResult::kOutOfDate;
        case SwapchainResult::kSurfaceLost:
            return RenderFrameResult::kSurfaceLost;
        case SwapchainResult::kDeviceLost:
            return RenderFrameResult::kDeviceLost;
        case SwapchainResult::kError:
            return RenderFrameResult::kVulkanFailure;
    }

    const uint64_t framebufferHandle = swapchain.getFramebufferHandle(imageIndex);
    const uint64_t presentReadySemaphoreHandle =
        swapchain.getPresentReadySemaphoreHandle(imageIndex);
    if (framebufferHandle == 0 || presentReadySemaphoreHandle == 0) {
        return s.failClosed(swapchain, ahbImports, RenderFrameResult::kVulkanFailure);
    }
    const VkFramebuffer framebuffer = u64ToVkHandle<VkFramebuffer>(framebufferHandle);
    const VkSemaphore presentReadySemaphore =
        u64ToVkHandle<VkSemaphore>(presentReadySemaphoreHandle);

    if (!s.frameSync->resetCommandBuffer(s.currentFrameIndex)) {
        return s.failClosed(swapchain, ahbImports, RenderFrameResult::kVulkanFailure);
    }
    VkCommandBufferBeginInfo beginInfo{};
    beginInfo.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
    if (vkBeginCommandBuffer(frame->commandBuffer, &beginInfo) != VK_SUCCESS) {
        return s.failClosed(swapchain, ahbImports, RenderFrameResult::kVulkanFailure);
    }

    // 1. GPU mask first-use layout transition (outside the render pass).
    if (gpuMaskImage != nullptr &&
        ahbImports.getImageLayout(maskInfo.gpuMaskHandle) ==
            static_cast<uint32_t>(VK_IMAGE_LAYOUT_UNDEFINED)) {
        gpuMaskImage->recordLayoutTransition(
            frame->commandBuffer,
            VK_IMAGE_LAYOUT_UNDEFINED,
            VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
            VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT,
            VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT,
            0,
            VK_ACCESS_SHADER_READ_BIT);
    }

    // 2. Optional camera transition, then a clear-only render pass filled
    //    with the static background colour (zero layer draws -- no source
    //    layer exists on this path); render pass left open.
    VulkanTransitionPassParams passParams{};
    passParams.commandBuffer = frame->commandBuffer;
    passParams.renderPass = renderPass;
    passParams.framebuffer = framebuffer;
    passParams.extentWidth = extentWidth;
    passParams.extentHeight = extentHeight;
    passParams.clearColor.float32[0] = background.clearRgba[0];
    passParams.clearColor.float32[1] = background.clearRgba[1];
    passParams.clearColor.float32[2] = background.clearRgba[2];
    passParams.clearColor.float32[3] = background.clearRgba[3];
    passParams.fromImage = cameraImage;
    passParams.fromOldLayout = VK_IMAGE_LAYOUT_UNDEFINED;
    passParams.transitionFromImage =
        ahbImports.getImageLayout(camera.handle) ==
        static_cast<uint32_t>(VK_IMAGE_LAYOUT_UNDEFINED);
    passParams.drawCount = 0;
    // Validates every handle / extent before recording anything (nothing is
    // recorded on a validation failure, so no render pass is open there).
    if (!VulkanGraphicsCommandRecorder::recordTransitionPassBodyKeepOpen(passParams)) {
        abandonRecordingCommandBuffer(frame->commandBuffer);
        return s.failClosed(swapchain, ahbImports, RenderFrameResult::kVulkanFailure);
    }

    // 3. Camera layer, alpha-masked, into the same open render pass -- the
    //    exact camera draw the production path records.
    VulkanGreenScreenCameraDraw cameraDraw{};
    cameraDraw.cameraDescriptorSetLayout = cameraSetLayoutHandle;
    cameraDraw.cameraDescriptorSet = vkHandleToU64(cameraSet);
    cameraDraw.maskImageView = maskInfo.imageViewHandle;
    cameraDraw.maskWidth = maskInfo.width;
    cameraDraw.maskHeight = maskInfo.height;
    cameraDraw.debugMode = maskInfo.debugMode;
    cameraDraw.viewportX = cameraPlacement.viewport.x;
    cameraDraw.viewportY = cameraPlacement.viewport.y;
    cameraDraw.viewportWidth = cameraPlacement.viewport.width();
    cameraDraw.viewportHeight = cameraPlacement.viewport.height();
    cameraDraw.scissorX = cameraPlacement.scissor.x;
    cameraDraw.scissorY = cameraPlacement.scissor.y;
    cameraDraw.scissorWidth = cameraPlacement.scissor.width();
    cameraDraw.scissorHeight = cameraPlacement.scissor.height();
    cameraDraw.pushConstants = cameraPlacement.pushConstants;
    std::string failureReason;
    if (!s.greenScreenRenderer->recordCameraDraw(
            s.device, frame->commandBuffer, renderPassHandle,
            extentWidth, extentHeight, cameraDraw, &failureReason)) {
        VGLOG_VFR("renderDuetGreenScreenStaticBackgroundFrame camera draw failed: %s",
                  failureReason.c_str());
        abandonOpenRenderPass(frame->commandBuffer);
        return s.failClosed(swapchain, ahbImports, RenderFrameResult::kVulkanFailure);
    }

    // 4. Close the pass and the command buffer.
    vkCmdEndRenderPass(frame->commandBuffer);
    if (vkEndCommandBuffer(frame->commandBuffer) != VK_SUCCESS) {
        return s.failClosed(swapchain, ahbImports, RenderFrameResult::kVulkanFailure);
    }
    if (!s.frameSync->resetFrameFence(s.currentFrameIndex)) {
        return s.failClosed(swapchain, ahbImports, RenderFrameResult::kVulkanFailure);
    }

    // imageAvailable + up to two distinct pending AHB acquire semaphores
    // (camera, GPU mask).
    VkSemaphore waitSemaphores[3] = {
        frame->imageAvailableSemaphore, VK_NULL_HANDLE, VK_NULL_HANDLE,
    };
    VkPipelineStageFlags waitStages[3] = {
        VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
        VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT,
        VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT,
    };
    uint32_t waitSemaphoreCount = 1;
    const uint64_t cameraPendingAcquire =
        ahbImports.getPendingAcquireSemaphoreHandle(camera.handle);
    const uint64_t maskPendingAcquire =
        hasGpuMask ? ahbImports.getPendingAcquireSemaphoreHandle(maskInfo.gpuMaskHandle) : 0;
    if (cameraPendingAcquire != 0) {
        waitSemaphores[waitSemaphoreCount++] = u64ToVkHandle<VkSemaphore>(cameraPendingAcquire);
    }
    if (maskPendingAcquire != 0 && maskPendingAcquire != cameraPendingAcquire) {
        waitSemaphores[waitSemaphoreCount++] = u64ToVkHandle<VkSemaphore>(maskPendingAcquire);
    }

    const bool canExportRelease =
        frame->releaseFenceSemaphore != VK_NULL_HANDLE && s.pfnGetSemaphoreFd != nullptr;
    VkSemaphore signalSemaphores[2] = {presentReadySemaphore, VK_NULL_HANDLE};
    uint32_t signalSemaphoreCount = 1;
    if (canExportRelease) {
        signalSemaphores[signalSemaphoreCount++] = frame->releaseFenceSemaphore;
    }

    VkSubmitInfo submitInfo{};
    submitInfo.sType = VK_STRUCTURE_TYPE_SUBMIT_INFO;
    submitInfo.waitSemaphoreCount = waitSemaphoreCount;
    submitInfo.pWaitSemaphores = waitSemaphores;
    submitInfo.pWaitDstStageMask = waitStages;
    submitInfo.commandBufferCount = 1;
    submitInfo.pCommandBuffers = &frame->commandBuffer;
    submitInfo.signalSemaphoreCount = signalSemaphoreCount;
    submitInfo.pSignalSemaphores = signalSemaphores;
    const VkResult submitResult = vkQueueSubmit(
        static_cast<VkQueue>(queueHandle), 1, &submitInfo, frame->inFlightFence);
    if (submitResult != VK_SUCCESS) {
        return s.failClosed(swapchain, ahbImports,
            submitResult == VK_ERROR_DEVICE_LOST
                ? RenderFrameResult::kDeviceLost : RenderFrameResult::kVulkanFailure);
    }

    // Both imports now belong to this submission, even if later bookkeeping
    // fails; the GPU mask is marked submitted so a later release retires it
    // behind this frame's fence (never released here).
    const bool cameraAcquireMarked = cameraPendingAcquire == 0 ||
        ahbImports.markAcquireSemaphoreSubmitted(camera.handle);
    const bool maskAcquireMarked = maskPendingAcquire == 0 ||
        ahbImports.markAcquireSemaphoreSubmitted(maskInfo.gpuMaskHandle);
    const bool cameraSubmitted = ahbImports.markBufferSubmitted(camera.handle, s.currentFrameIndex);
    const bool maskSubmitted = !hasGpuMask ||
        ahbImports.markBufferSubmitted(maskInfo.gpuMaskHandle, s.currentFrameIndex);
    const bool cameraLayoutSet = ahbImports.setImageLayout(
        camera.handle, static_cast<uint32_t>(VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL));
    const bool maskLayoutSet = !hasGpuMask || ahbImports.setImageLayout(
        maskInfo.gpuMaskHandle, static_cast<uint32_t>(VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL));
    if (!cameraAcquireMarked || !maskAcquireMarked || !cameraSubmitted || !maskSubmitted ||
        !cameraLayoutSet || !maskLayoutSet) {
        return s.failClosed(swapchain, ahbImports, RenderFrameResult::kVulkanFailure);
    }

    int cameraReleaseFd = -1;
    if (canExportRelease) {
        VkSemaphoreGetFdInfoKHR semGetFdInfo{};
        semGetFdInfo.sType = VK_STRUCTURE_TYPE_SEMAPHORE_GET_FD_INFO_KHR;
        semGetFdInfo.semaphore = frame->releaseFenceSemaphore;
        semGetFdInfo.handleType = VK_EXTERNAL_SEMAPHORE_HANDLE_TYPE_SYNC_FD_BIT;
        const VkResult exportResult =
            s.pfnGetSemaphoreFd(s.device, &semGetFdInfo, &cameraReleaseFd);
        if (exportResult != VK_SUCCESS) {
            VGLOG_VFR("duet static-background vkGetSemaphoreFdKHR failed: %d",
                      static_cast<int>(exportResult));
            if (cameraReleaseFd >= 0) ::close(cameraReleaseFd);
            ahbImports.setLatestReleaseFenceFd(camera.handle, -1);
            return s.failClosed(swapchain, ahbImports, RenderFrameResult::kVulkanFailure);
        }
    }
    // The setter consumes the fd even on failure; with no export support (or
    // an empty sync-fd), -1 clears any stale stored fd.
    if (!ahbImports.setLatestReleaseFenceFd(camera.handle, cameraReleaseFd)) {
        ahbImports.setLatestReleaseFenceFd(camera.handle, -1);
        return s.failClosed(swapchain, ahbImports, RenderFrameResult::kVulkanFailure);
    }

    if (!s.greenScreenStaticBackgroundFirstFrameLogged) {
        s.greenScreenStaticBackgroundFirstFrameLogged = true;
        VGLOG_VFR("ANDROID_DUET_VULKAN_GREENSCREEN_STATIC_FIRST canvas=%ux%u "
                  "camera=%d,%d %dx%d buf=%ux%u mask=%ux%u maskSource=%s "
                  "backgroundMode=%s debugMode=%d cameraRot=%u cameraMirror=%d",
                  extentWidth, extentHeight,
                  camera.rect.x, camera.rect.y, camera.rect.width, camera.rect.height,
                  camera.bufferWidth, camera.bufferHeight,
                  maskInfo.width, maskInfo.height,
                  hasGpuMask ? "gpu_import" : "cpu_upload",
                  background.modeLabel, maskInfo.debugMode,
                  camera.rotationDegrees, camera.mirrorHorizontal ? 1 : 0);
    }

    const SwapchainResult presentResult = swapchain.presentImage(
        queueHandle, presentReadySemaphoreHandle, imageIndex);
    s.currentFrameIndex = (s.currentFrameIndex + 1) % frameCount;
    switch (presentResult) {
        case SwapchainResult::kSuccess:
            return acquireResult == SwapchainResult::kSuboptimal
                ? RenderFrameResult::kSuboptimal : RenderFrameResult::kSuccess;
        case SwapchainResult::kSuboptimal:
            return RenderFrameResult::kSuboptimal;
        case SwapchainResult::kOutOfDate:
            return RenderFrameResult::kOutOfDate;
        case SwapchainResult::kSurfaceLost:
            return RenderFrameResult::kSurfaceLost;
        case SwapchainResult::kDeviceLost:
            return s.failClosed(swapchain, ahbImports, RenderFrameResult::kDeviceLost);
        case SwapchainResult::kError:
            return s.failClosed(swapchain, ahbImports, RenderFrameResult::kVulkanFailure);
    }
    return s.failClosed(swapchain, ahbImports, RenderFrameResult::kVulkanFailure);
}

// ANDROID-DUET-VULKAN-LAYOUT: two-layer opaque Duet layout frame. Mirrors
// renderDuetGreenScreenFrame above's entire acquire / frame-fence /
// imageAvailable + presentReady semaphore / pending AHB acquire semaphore
// wait / release-fence export (one export, dup'd to the second import) /
// present protocol and its post-submit bookkeeping for both imports, but
// records the frame through VulkanGraphicsCommandRecorder::recordTransitionPass
// (optional source layout transitions, one clear render pass, the source
// draw then the camera draw) with each layer's viewport / scissor / UV crop
// resolved by the private vulkan_duet_layout_frame_renderer helper, using
// each import's own descriptor resources and the core passthrough shaders
// exactly like a solo / transition frame.
RenderFrameResult VulkanFrameRenderer::renderDuetLayoutFrame(
    void* queueHandle,
    VulkanSurfaceSwapchain& swapchain,
    VulkanHardwareBufferImports& ahbImports,
    VulkanCoreShaderModules& coreShaders,
    const DuetLayoutLayer& source,
    const DuetLayoutLayer& camera) {
    if (!impl_ || !impl_->initialized) {
        return RenderFrameResult::kBackendNotInitialized;
    }
    Impl& s = *impl_;
    if (queueHandle == nullptr || s.device == VK_NULL_HANDLE ||
        s.commandPool == VK_NULL_HANDLE) {
        return RenderFrameResult::kVulkanFailure;
    }
    if (!swapchain.hasSurface()) {
        return RenderFrameResult::kNoSurface;
    }
    if (source.handle == camera.handle) {
        return RenderFrameResult::kInvalidBufferHandle;
    }
    const VulkanHardwareBufferImage* sourceImage = ahbImports.getImage(source.handle);
    const VulkanHardwareBufferImage* cameraImage = ahbImports.getImage(camera.handle);
    if (!ahbImports.hasBuffer(source.handle) || sourceImage == nullptr ||
        !ahbImports.hasBuffer(camera.handle) || cameraImage == nullptr) {
        return RenderFrameResult::kInvalidBufferHandle;
    }
    if (sourceImage->image == VK_NULL_HANDLE || cameraImage->image == VK_NULL_HANDLE ||
        coreShaders.vertex.get() == VK_NULL_HANDLE ||
        coreShaders.fragment.get() == VK_NULL_HANDLE ||
        !s.frameSync || !s.frameSync->isInitialized()) {
        return RenderFrameResult::kVulkanFailure;
    }

    const uint32_t frameCount = s.frameSync->getFrameCount();
    if (frameCount == 0 || s.currentFrameIndex >= frameCount) {
        return RenderFrameResult::kVulkanFailure;
    }
    const VulkanFrameSyncResources* frame = s.frameSync->getFrame(s.currentFrameIndex);
    if (frame == nullptr || frame->commandBuffer == VK_NULL_HANDLE ||
        frame->imageAvailableSemaphore == VK_NULL_HANDLE ||
        frame->inFlightFence == VK_NULL_HANDLE) {
        return RenderFrameResult::kVulkanFailure;
    }

    const uint64_t renderPassHandle = swapchain.getRenderPassHandle();
    const uint32_t extentWidth = swapchain.getExtentWidth();
    const uint32_t extentHeight = swapchain.getExtentHeight();
    const VkPipelineLayout sourceLayout = sourceImage->descriptorResources.pipelineLayout;
    const VkDescriptorSet sourceSet = sourceImage->descriptorResources.descriptorSet;
    const VkPipelineLayout cameraLayout = cameraImage->descriptorResources.pipelineLayout;
    const VkDescriptorSet cameraSet = cameraImage->descriptorResources.descriptorSet;
    if (renderPassHandle == 0 || extentWidth == 0 || extentHeight == 0 ||
        sourceLayout == VK_NULL_HANDLE || sourceSet == VK_NULL_HANDLE ||
        cameraLayout == VK_NULL_HANDLE || cameraSet == VK_NULL_HANDLE) {
        return RenderFrameResult::kVulkanFailure;
    }
    const VkRenderPass renderPass = u64ToVkHandle<VkRenderPass>(renderPassHandle);

    // Geometry is pure math; resolve (and fail closed) before any Vulkan
    // state is touched so an invalid rect never reaches the swapchain.
    VulkanDuetLayoutLayerGeometry sourceGeometry;
    sourceGeometry.rect = source.rect;
    sourceGeometry.bufferWidth = source.bufferWidth;
    sourceGeometry.bufferHeight = source.bufferHeight;
    sourceGeometry.rotationDegrees = source.rotationDegrees;
    sourceGeometry.mirrorHorizontal = source.mirrorHorizontal;
    sourceGeometry.cornerRadiusPx = source.cornerRadiusPx;
    VulkanDuetLayoutLayerGeometry cameraGeometry;
    cameraGeometry.rect = camera.rect;
    cameraGeometry.bufferWidth = camera.bufferWidth;
    cameraGeometry.bufferHeight = camera.bufferHeight;
    cameraGeometry.rotationDegrees = camera.rotationDegrees;
    cameraGeometry.mirrorHorizontal = camera.mirrorHorizontal;
    cameraGeometry.cornerRadiusPx = camera.cornerRadiusPx;
    VulkanDuetLayoutLayerPlacement sourcePlacement;
    VulkanDuetLayoutLayerPlacement cameraPlacement;
    if (!ResolveVulkanDuetLayoutLayerPlacement(sourceGeometry, extentWidth, extentHeight,
                                               &sourcePlacement) ||
        !ResolveVulkanDuetLayoutLayerPlacement(cameraGeometry, extentWidth, extentHeight,
                                               &cameraPlacement)) {
        VGLOG_VFR("renderDuetLayoutFrame: invalid layer rect (source %d,%d %dx%d camera "
                  "%d,%d %dx%d extent %ux%u); failing closed",
                  source.rect.x, source.rect.y, source.rect.width, source.rect.height,
                  camera.rect.x, camera.rect.y, camera.rect.width, camera.rect.height,
                  extentWidth, extentHeight);
        return RenderFrameResult::kVulkanFailure;
    }

    // Pipelines are per import pipeline layout (the external-format YCbCr
    // sampler is an immutable sampler baked into the import's descriptor set
    // layout) and per render pass; both are cached and rebuilt only when
    // either changes (see Impl::ensureDuetLayoutPipelines, shared with the
    // green-screen path). Only this pair is touched: the green-screen
    // helper's cached pipeline is left intact so a green-screen <-> layout
    // toggle never churns it.
    if (!s.ensureDuetLayoutPipelines(sourceLayout, cameraLayout, renderPassHandle, renderPass,
                                     coreShaders)) {
        return RenderFrameResult::kVulkanFailure;
    }

    if (!s.frameSync->waitForFrameFence(s.currentFrameIndex)) {
        return RenderFrameResult::kVulkanFailure;
    }
    ahbImports.drainRetiredForFrame(s.currentFrameIndex);

    uint32_t imageIndex = 0;
    const SwapchainResult acquireResult = swapchain.acquireNextImage(
        vkHandleToU64(frame->imageAvailableSemaphore), 0, &imageIndex, UINT64_MAX);
    switch (acquireResult) {
        case SwapchainResult::kSuccess:
        case SwapchainResult::kSuboptimal:
            break;
        case SwapchainResult::kOutOfDate:
            return RenderFrameResult::kOutOfDate;
        case SwapchainResult::kSurfaceLost:
            return RenderFrameResult::kSurfaceLost;
        case SwapchainResult::kDeviceLost:
            return RenderFrameResult::kDeviceLost;
        case SwapchainResult::kError:
            return RenderFrameResult::kVulkanFailure;
    }

    const uint64_t framebufferHandle = swapchain.getFramebufferHandle(imageIndex);
    const uint64_t presentReadySemaphoreHandle =
        swapchain.getPresentReadySemaphoreHandle(imageIndex);
    if (framebufferHandle == 0 || presentReadySemaphoreHandle == 0) {
        return s.failClosed(swapchain, ahbImports, RenderFrameResult::kVulkanFailure);
    }
    const VkFramebuffer framebuffer = u64ToVkHandle<VkFramebuffer>(framebufferHandle);
    const VkSemaphore presentReadySemaphore =
        u64ToVkHandle<VkSemaphore>(presentReadySemaphoreHandle);

    if (!s.frameSync->resetCommandBuffer(s.currentFrameIndex)) {
        return s.failClosed(swapchain, ahbImports, RenderFrameResult::kVulkanFailure);
    }

    VulkanTransitionPassParams passParams{};
    passParams.commandBuffer = frame->commandBuffer;
    passParams.renderPass = renderPass;
    passParams.framebuffer = framebuffer;
    passParams.extentWidth = extentWidth;
    passParams.extentHeight = extentHeight;
    passParams.fromImage = sourceImage;
    passParams.fromOldLayout = VK_IMAGE_LAYOUT_UNDEFINED;
    passParams.transitionFromImage =
        ahbImports.getImageLayout(source.handle) ==
        static_cast<uint32_t>(VK_IMAGE_LAYOUT_UNDEFINED);
    passParams.toImage = cameraImage;
    passParams.toOldLayout = VK_IMAGE_LAYOUT_UNDEFINED;
    passParams.transitionToImage =
        ahbImports.getImageLayout(camera.handle) ==
        static_cast<uint32_t>(VK_IMAGE_LAYOUT_UNDEFINED);

    VulkanTransitionLayerResources sourceRes;
    sourceRes.pipeline = s.duetLayoutSourcePipeline->get();
    sourceRes.pipelineLayout = sourceLayout;
    sourceRes.descriptorSet = sourceSet;
    VulkanTransitionLayerResources cameraRes;
    cameraRes.pipeline = s.duetLayoutCameraPipeline->get();
    cameraRes.pipelineLayout = cameraLayout;
    cameraRes.descriptorSet = cameraSet;
    if (!AppendVulkanDuetLayoutLayer(&passParams, sourceRes, sourcePlacement) ||
        !AppendVulkanDuetLayoutLayer(&passParams, cameraRes, cameraPlacement)) {
        return s.failClosed(swapchain, ahbImports, RenderFrameResult::kVulkanFailure);
    }
    // recordTransitionPass validates every handle / extent / scissor before
    // recording anything (nothing is recorded on a validation failure) and
    // begins / ends the command buffer itself.
    if (!VulkanGraphicsCommandRecorder::recordTransitionPass(passParams)) {
        return s.failClosed(swapchain, ahbImports, RenderFrameResult::kVulkanFailure);
    }
    if (!s.frameSync->resetFrameFence(s.currentFrameIndex)) {
        return s.failClosed(swapchain, ahbImports, RenderFrameResult::kVulkanFailure);
    }

    VkSemaphore waitSemaphores[3] = {
        frame->imageAvailableSemaphore, VK_NULL_HANDLE, VK_NULL_HANDLE,
    };
    VkPipelineStageFlags waitStages[3] = {
        VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
        VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT,
        VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT,
    };
    uint32_t waitSemaphoreCount = 1;
    const uint64_t sourcePendingAcquire =
        ahbImports.getPendingAcquireSemaphoreHandle(source.handle);
    const uint64_t cameraPendingAcquire =
        ahbImports.getPendingAcquireSemaphoreHandle(camera.handle);
    if (sourcePendingAcquire != 0) {
        waitSemaphores[waitSemaphoreCount++] = u64ToVkHandle<VkSemaphore>(sourcePendingAcquire);
    }
    if (cameraPendingAcquire != 0 && cameraPendingAcquire != sourcePendingAcquire) {
        waitSemaphores[waitSemaphoreCount++] = u64ToVkHandle<VkSemaphore>(cameraPendingAcquire);
    }

    const bool canExportRelease =
        frame->releaseFenceSemaphore != VK_NULL_HANDLE && s.pfnGetSemaphoreFd != nullptr;
    VkSemaphore signalSemaphores[2] = {presentReadySemaphore, VK_NULL_HANDLE};
    uint32_t signalSemaphoreCount = 1;
    if (canExportRelease) {
        signalSemaphores[signalSemaphoreCount++] = frame->releaseFenceSemaphore;
    }

    VkSubmitInfo submitInfo{};
    submitInfo.sType = VK_STRUCTURE_TYPE_SUBMIT_INFO;
    submitInfo.waitSemaphoreCount = waitSemaphoreCount;
    submitInfo.pWaitSemaphores = waitSemaphores;
    submitInfo.pWaitDstStageMask = waitStages;
    submitInfo.commandBufferCount = 1;
    submitInfo.pCommandBuffers = &frame->commandBuffer;
    submitInfo.signalSemaphoreCount = signalSemaphoreCount;
    submitInfo.pSignalSemaphores = signalSemaphores;
    const VkResult submitResult = vkQueueSubmit(
        static_cast<VkQueue>(queueHandle), 1, &submitInfo, frame->inFlightFence);
    if (submitResult != VK_SUCCESS) {
        return s.failClosed(swapchain, ahbImports,
            submitResult == VK_ERROR_DEVICE_LOST
                ? RenderFrameResult::kDeviceLost : RenderFrameResult::kVulkanFailure);
    }

    // Both imports now belong to this submission, even if later bookkeeping fails.
    const bool sourceAcquireMarked = sourcePendingAcquire == 0 ||
        ahbImports.markAcquireSemaphoreSubmitted(source.handle);
    const bool cameraAcquireMarked = cameraPendingAcquire == 0 ||
        ahbImports.markAcquireSemaphoreSubmitted(camera.handle);
    const bool sourceSubmitted = ahbImports.markBufferSubmitted(source.handle, s.currentFrameIndex);
    const bool cameraSubmitted = ahbImports.markBufferSubmitted(camera.handle, s.currentFrameIndex);
    const bool sourceLayoutSet = ahbImports.setImageLayout(
        source.handle, static_cast<uint32_t>(VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL));
    const bool cameraLayoutSet = ahbImports.setImageLayout(
        camera.handle, static_cast<uint32_t>(VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL));
    if (!sourceAcquireMarked || !cameraAcquireMarked ||
        !sourceSubmitted || !cameraSubmitted ||
        !sourceLayoutSet || !cameraLayoutSet) {
        return s.failClosed(swapchain, ahbImports, RenderFrameResult::kVulkanFailure);
    }

    int sourceReleaseFd = -1;
    int cameraReleaseFd = -1;
    if (canExportRelease) {
        VkSemaphoreGetFdInfoKHR semGetFdInfo{};
        semGetFdInfo.sType = VK_STRUCTURE_TYPE_SEMAPHORE_GET_FD_INFO_KHR;
        semGetFdInfo.semaphore = frame->releaseFenceSemaphore;
        semGetFdInfo.handleType = VK_EXTERNAL_SEMAPHORE_HANDLE_TYPE_SYNC_FD_BIT;
        const VkResult exportResult =
            s.pfnGetSemaphoreFd(s.device, &semGetFdInfo, &sourceReleaseFd);
        if (exportResult != VK_SUCCESS) {
            VGLOG_VFR("duet layout vkGetSemaphoreFdKHR failed: %d", static_cast<int>(exportResult));
            if (sourceReleaseFd >= 0) ::close(sourceReleaseFd);
            ahbImports.setLatestReleaseFenceFd(source.handle, -1);
            ahbImports.setLatestReleaseFenceFd(camera.handle, -1);
            return s.failClosed(swapchain, ahbImports, RenderFrameResult::kVulkanFailure);
        }
        // Export consumes the semaphore payload: share that single sync-fd with both inputs.
        if (sourceReleaseFd >= 0) {
            cameraReleaseFd = ::dup(sourceReleaseFd);
            if (cameraReleaseFd < 0) {
                VGLOG_VFR("duet layout release sync-fd dup failed; failing closed");
                ::close(sourceReleaseFd);
                ahbImports.setLatestReleaseFenceFd(source.handle, -1);
                ahbImports.setLatestReleaseFenceFd(camera.handle, -1);
                return s.failClosed(swapchain, ahbImports, RenderFrameResult::kVulkanFailure);
            }
        }
    }
    // Each setter consumes its fd even on failure; attempt both without short-circuiting.
    // With no export support (or an empty sync-fd), -1 clears both stale stored fds.
    const bool sourceReleaseStored =
        ahbImports.setLatestReleaseFenceFd(source.handle, sourceReleaseFd);
    const bool cameraReleaseStored =
        ahbImports.setLatestReleaseFenceFd(camera.handle, cameraReleaseFd);
    if (!sourceReleaseStored || !cameraReleaseStored) {
        ahbImports.setLatestReleaseFenceFd(source.handle, -1);
        ahbImports.setLatestReleaseFenceFd(camera.handle, -1);
        return s.failClosed(swapchain, ahbImports, RenderFrameResult::kVulkanFailure);
    }

    const SwapchainResult presentResult = swapchain.presentImage(
        queueHandle, presentReadySemaphoreHandle, imageIndex);
    s.currentFrameIndex = (s.currentFrameIndex + 1) % frameCount;
    switch (presentResult) {
        case SwapchainResult::kSuccess:
            return acquireResult == SwapchainResult::kSuboptimal
                ? RenderFrameResult::kSuboptimal : RenderFrameResult::kSuccess;
        case SwapchainResult::kSuboptimal:
            return RenderFrameResult::kSuboptimal;
        case SwapchainResult::kOutOfDate:
            return RenderFrameResult::kOutOfDate;
        case SwapchainResult::kSurfaceLost:
            return RenderFrameResult::kSurfaceLost;
        case SwapchainResult::kDeviceLost:
            return s.failClosed(swapchain, ahbImports, RenderFrameResult::kDeviceLost);
        case SwapchainResult::kError:
            return s.failClosed(swapchain, ahbImports, RenderFrameResult::kVulkanFailure);
    }
    return s.failClosed(swapchain, ahbImports, RenderFrameResult::kVulkanFailure);
}

} // namespace render
} // namespace vanguard


#else // !defined(__ANDROID__) - Host build

namespace vanguard {
namespace render {

struct VulkanFrameRenderer::Impl {
    bool initialized = false;
};

VulkanFrameRenderer::VulkanFrameRenderer()
    : impl_(std::make_unique<Impl>()) {}

VulkanFrameRenderer::~VulkanFrameRenderer() = default;

bool VulkanFrameRenderer::initialize(void* /*deviceHandle*/,
                                     uint64_t /*commandPoolHandle*/,
                                     uint32_t /*frameCount*/) {
    return false;
}

void VulkanFrameRenderer::shutdown() {
    if (impl_) {
        impl_->initialized = false;
    }
}

bool VulkanFrameRenderer::isInitialized() const {
    return false;
}

void VulkanFrameRenderer::invalidatePipeline() {
    // no-op on host
}

void VulkanFrameRenderer::waitAllFramesIdle() {
    // no-op on host
}

RenderFrameResult VulkanFrameRenderer::renderFrame(
    void* /*queueHandle*/,
    VulkanSurfaceSwapchain& swapchain,
    VulkanHardwareBufferImports& ahbImports,
    VulkanCoreShaderModules& /*coreShaders*/,
    HardwareBufferHandle handle) {
    if (!impl_ || !impl_->initialized) {
        return RenderFrameResult::kBackendNotInitialized;
    }
    if (!swapchain.hasSurface()) {
        return RenderFrameResult::kNoSurface;
    }
    if (!ahbImports.hasBuffer(handle) || ahbImports.getImage(handle) == nullptr) {
        return RenderFrameResult::kInvalidBufferHandle;
    }
    return RenderFrameResult::kUnavailable;
}

// Phase 4B2C: host-build stub for renderFrame with transform.
RenderFrameResult VulkanFrameRenderer::renderFrame(
    void* /*queueHandle*/,
    VulkanSurfaceSwapchain& swapchain,
    VulkanHardwareBufferImports& ahbImports,
    VulkanCoreShaderModules& /*coreShaders*/,
    HardwareBufferHandle handle,
    const VideoFrameTransform& /*transform*/) {
    if (!impl_ || !impl_->initialized) {
        return RenderFrameResult::kBackendNotInitialized;
    }
    if (!swapchain.hasSurface()) {
        return RenderFrameResult::kNoSurface;
    }
    if (!ahbImports.hasBuffer(handle) || ahbImports.getImage(handle) == nullptr) {
        return RenderFrameResult::kInvalidBufferHandle;
    }
    return RenderFrameResult::kUnavailable;
}

// P5-OVERLAYS-TRANS / P5-OVERLAYS-PRODUCTION-EXPORT-ROUTE-A native renderer
// integration sub-slice N2: host-build stub for renderFrame with optional
// overlay draws. Matches the existing host renderFrame overloads' pattern:
// no Vulkan is available on host, so this always reports unavailable once
// past the same argument validation as the Android overload above.
RenderFrameResult VulkanFrameRenderer::renderFrame(
    void* /*queueHandle*/,
    VulkanSurfaceSwapchain& swapchain,
    VulkanHardwareBufferImports& ahbImports,
    VulkanCoreShaderModules& /*coreShaders*/,
    HardwareBufferHandle handle,
    const VideoFrameTransform& /*transform*/,
    const VulkanOverlayFrameDraw* overlayDraws,
    uint32_t overlayCount) {
    if (!impl_ || !impl_->initialized) {
        return RenderFrameResult::kBackendNotInitialized;
    }
    if (!swapchain.hasSurface()) {
        return RenderFrameResult::kNoSurface;
    }
    if (!ahbImports.hasBuffer(handle) || ahbImports.getImage(handle) == nullptr) {
        return RenderFrameResult::kInvalidBufferHandle;
    }
    if (overlayCount > 0 && overlayDraws == nullptr) {
        return RenderFrameResult::kVulkanFailure;
    }
    return RenderFrameResult::kUnavailable;
}

// P5-BEAUTY-V2-PRODUCTION-EXPORT-ROUTE-A: host-build stub for renderFrame
// with an optional Beauty V2 pre-composite. Beauty is a Vulkan-only,
// Android-only production route; host builds report unavailable exactly
// like every other Vulkan render seam.
RenderFrameResult VulkanFrameRenderer::renderFrame(
    void* /*queueHandle*/,
    void* /*physicalDeviceHandle*/,
    VulkanSurfaceSwapchain& swapchain,
    VulkanHardwareBufferImports& ahbImports,
    VulkanCoreShaderModules& /*coreShaders*/,
    HardwareBufferHandle handle,
    const VideoFrameTransform& /*transform*/,
    const VideoBeautyV2RenderParams& /*beauty*/) {
    if (!impl_ || !impl_->initialized) {
        return RenderFrameResult::kBackendNotInitialized;
    }
    if (!swapchain.hasSurface()) {
        return RenderFrameResult::kNoSurface;
    }
    if (!ahbImports.hasBuffer(handle) || ahbImports.getImage(handle) == nullptr) {
        return RenderFrameResult::kInvalidBufferHandle;
    }
    return RenderFrameResult::kUnavailable;
}

// P5-OVERLAYS-BEAUTY-SOLO: host-build stub for renderFrame with both Beauty
// V2 and overlay draws. Matches the existing host renderFrame overloads'
// pattern: no Vulkan is available on host, so this always reports
// unavailable once past the same argument validation as the Android overload
// above.
RenderFrameResult VulkanFrameRenderer::renderFrame(
    void* /*queueHandle*/,
    void* /*physicalDeviceHandle*/,
    VulkanSurfaceSwapchain& swapchain,
    VulkanHardwareBufferImports& ahbImports,
    VulkanCoreShaderModules& /*coreShaders*/,
    HardwareBufferHandle handle,
    const VideoFrameTransform& /*transform*/,
    const VideoBeautyV2RenderParams& /*beauty*/,
    const VulkanOverlayFrameDraw* overlayDraws,
    uint32_t overlayCount) {
    if (!impl_ || !impl_->initialized) {
        return RenderFrameResult::kBackendNotInitialized;
    }
    if (!swapchain.hasSurface()) {
        return RenderFrameResult::kNoSurface;
    }
    if (!ahbImports.hasBuffer(handle) || ahbImports.getImage(handle) == nullptr) {
        return RenderFrameResult::kInvalidBufferHandle;
    }
    if (overlayCount > 0 && overlayDraws == nullptr) {
        return RenderFrameResult::kVulkanFailure;
    }
    return RenderFrameResult::kUnavailable;
}

// P5-COMPOSITOR-TRANS: host-build stub for the two-source transition frame.
RenderFrameResult VulkanFrameRenderer::renderTransitionFrame(
    void* /*queueHandle*/,
    void* /*physicalDeviceHandle*/,
    VulkanSurfaceSwapchain& swapchain,
    VulkanHardwareBufferImports& ahbImports,
    VulkanCoreShaderModules& /*coreShaders*/,
    HardwareBufferHandle fromHandle,
    HardwareBufferHandle toHandle,
    const VideoTransitionFrameTransform& /*transition*/,
    const VideoBeautyV2RenderParams& /*fromBeauty*/,
    const VideoBeautyV2RenderParams& /*toBeauty*/) {
    if (!impl_ || !impl_->initialized) {
        return RenderFrameResult::kBackendNotInitialized;
    }
    if (!swapchain.hasSurface()) {
        return RenderFrameResult::kNoSurface;
    }
    if (fromHandle == toHandle ||
        !ahbImports.hasBuffer(fromHandle) || ahbImports.getImage(fromHandle) == nullptr ||
        !ahbImports.hasBuffer(toHandle) || ahbImports.getImage(toHandle) == nullptr) {
        return RenderFrameResult::kInvalidBufferHandle;
    }
    return RenderFrameResult::kUnavailable;
}

// P5-OVERLAYS-TRANSITION-COMP-N1: host-build stub for the overlay-aware
// transition frame overload, mirroring the overlay renderFrame host stub's
// pattern: no Vulkan is available on host, so this always reports
// unavailable once past the same argument validation as the two-source
// transition stub above. Native-only: no JNI/Kotlin route calls this yet.
RenderFrameResult VulkanFrameRenderer::renderTransitionFrame(
    void* /*queueHandle*/,
    void* /*physicalDeviceHandle*/,
    VulkanSurfaceSwapchain& swapchain,
    VulkanHardwareBufferImports& ahbImports,
    VulkanCoreShaderModules& /*coreShaders*/,
    HardwareBufferHandle fromHandle,
    HardwareBufferHandle toHandle,
    const VideoTransitionFrameTransform& /*transition*/,
    const VulkanOverlayFrameDraw* overlayDraws,
    uint32_t overlayCount,
    const VideoBeautyV2RenderParams& /*fromBeauty*/,
    const VideoBeautyV2RenderParams& /*toBeauty*/) {
    if (!impl_ || !impl_->initialized) {
        return RenderFrameResult::kBackendNotInitialized;
    }
    if (!swapchain.hasSurface()) {
        return RenderFrameResult::kNoSurface;
    }
    if (fromHandle == toHandle ||
        !ahbImports.hasBuffer(fromHandle) || ahbImports.getImage(fromHandle) == nullptr ||
        !ahbImports.hasBuffer(toHandle) || ahbImports.getImage(toHandle) == nullptr) {
        return RenderFrameResult::kInvalidBufferHandle;
    }
    if (overlayCount > 0 && overlayDraws == nullptr) {
        return RenderFrameResult::kVulkanFailure;
    }
    return RenderFrameResult::kUnavailable;
}

// ANDROID-DUET-VULKAN-GREENSCREEN-VISUAL: host-build stub for the Duet
// green-screen frame; same argument validation as the Android path's
// pre-Vulkan checks, then unavailable.
RenderFrameResult VulkanFrameRenderer::renderDuetGreenScreenFrame(
    void* /*queueHandle*/,
    VulkanSurfaceSwapchain& swapchain,
    VulkanHardwareBufferImports& ahbImports,
    VulkanCoreShaderModules& /*coreShaders*/,
    const DuetLayoutLayer& source,
    const DuetLayoutLayer& camera,
    const VulkanGreenScreenMaskInfo& maskInfo) {
    if (!impl_ || !impl_->initialized) {
        return RenderFrameResult::kBackendNotInitialized;
    }
    if (!swapchain.hasSurface()) {
        return RenderFrameResult::kNoSurface;
    }
    if (source.handle == camera.handle ||
        !ahbImports.hasBuffer(source.handle) || ahbImports.getImage(source.handle) == nullptr ||
        !ahbImports.hasBuffer(camera.handle) || ahbImports.getImage(camera.handle) == nullptr) {
        return RenderFrameResult::kInvalidBufferHandle;
    }
    if (maskInfo.imageViewHandle == 0 || maskInfo.width == 0 || maskInfo.height == 0) {
        return RenderFrameResult::kVulkanFailure;
    }
    return RenderFrameResult::kUnavailable;
}

// ANDROID-DUET-VULKAN-GREENSCREEN-STATIC-BACKGROUND: host-build stub for the
// camera-only static-background green-screen frame; same argument validation
// as the Android path's pre-Vulkan checks, then unavailable.
RenderFrameResult VulkanFrameRenderer::renderDuetGreenScreenStaticBackgroundFrame(
    void* /*queueHandle*/,
    VulkanSurfaceSwapchain& swapchain,
    VulkanHardwareBufferImports& ahbImports,
    const DuetLayoutLayer& camera,
    const VulkanGreenScreenMaskInfo& maskInfo,
    const DuetStaticBackground& background) {
    if (!impl_ || !impl_->initialized) {
        return RenderFrameResult::kBackendNotInitialized;
    }
    if (!swapchain.hasSurface()) {
        return RenderFrameResult::kNoSurface;
    }
    if (!ahbImports.hasBuffer(camera.handle) || ahbImports.getImage(camera.handle) == nullptr) {
        return RenderFrameResult::kInvalidBufferHandle;
    }
    if (maskInfo.imageViewHandle == 0 || maskInfo.width == 0 || maskInfo.height == 0 ||
        background.modeLabel == nullptr) {
        return RenderFrameResult::kVulkanFailure;
    }
    return RenderFrameResult::kUnavailable;
}

} // namespace render
} // namespace vanguard

#endif // __ANDROID__
