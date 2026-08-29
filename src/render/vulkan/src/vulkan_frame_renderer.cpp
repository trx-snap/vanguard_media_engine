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
#include "vulkan_frame_synchronization.h"
#include "vulkan_graphics_command_recorder.h"
#include "vulkan_graphics_pipeline.h"
#include "vulkan_surface_swapchain.h"
#include "vulkan_hardware_buffer_imports.h"
#include "vulkan_shader_module.h"
#include "vanguard/render/render_transform.h"

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

    void invalidatePipeline() {
        if (graphicsPipeline) {
            graphicsPipeline->destroy(device);
            graphicsPipeline.reset();
        }
        activePipelineLayout = VK_NULL_HANDLE;
        activeRenderPassHandle = 0;
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
        if (pipelineCompatibilityMismatch &&
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

    // Phase 4B2C: build push constants from transform.
    const VideoTransformPushConstants pc = makeVideoTransformPushConstants(transform);

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
    // Phase 4B2C: copy push constants into passParams.
    static_assert(sizeof(passParams.uvTransformPushConstants) == 32,
                  "uvTransformPushConstants size mismatch");
    std::memcpy(passParams.uvTransformPushConstants, &pc, 32);
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

} // namespace render
} // namespace vanguard

#endif // __ANDROID__
