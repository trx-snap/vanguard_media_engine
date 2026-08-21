// vulkan_frame_renderer.cpp
// Phase 2O2B1: Modular Frame Renderer Extraction.
//
// Implements VulkanFrameRenderer helper managing frame synchronization,
// graphics pipeline caching, and frame rendering orchestration behind a PImpl.
//
// On Android (__ANDROID__):
//   - Manages VulkanFrameSynchronization and VulkanGraphicsPipeline.
//   - renderFrame validates all preconditions and returns kUnavailable (real loop in Phase 2O2B2).
//
// On non-Android host builds:
//   - Compiles without Vulkan SDK.
//   - initialize() returns false; renderFrame returns kUnavailable.

#include "vulkan_frame_renderer.h"
#include "vulkan_frame_synchronization.h"
#include "vulkan_graphics_pipeline.h"
#include "vulkan_surface_swapchain.h"
#include "vulkan_hardware_buffer_imports.h"
#include "vulkan_shader_module.h"

#include <cstring>

#if defined(__ANDROID__)

#include <vulkan/vulkan.h>
#include <android/log.h>

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

    void invalidatePipeline() {
        if (graphicsPipeline) {
            graphicsPipeline->destroy(device);
            graphicsPipeline.reset();
        }
        activePipelineLayout = VK_NULL_HANDLE;
        activeRenderPassHandle = 0;
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

RenderFrameResult VulkanFrameRenderer::renderFrame(
    void* queueHandle,
    VulkanSurfaceSwapchain& swapchain,
    VulkanHardwareBufferImports& ahbImports,
    VulkanCoreShaderModules& coreShaders,
    HardwareBufferHandle handle) {
    (void)queueHandle;

    if (!impl_ || !impl_->initialized) {
        return RenderFrameResult::kBackendNotInitialized;
    }
    if (!swapchain.hasSurface()) {
        return RenderFrameResult::kNoSurface;
    }
    if (!ahbImports.hasBuffer(handle) || ahbImports.getImage(handle) == nullptr) {
        return RenderFrameResult::kInvalidBufferHandle;
    }
    if (coreShaders.vertex.get() == VK_NULL_HANDLE || coreShaders.fragment.get() == VK_NULL_HANDLE) {
        return RenderFrameResult::kVulkanFailure;
    }

    // Strict Phase 2O2B1 boundary:
    // Real frame loop (acquire, record, submit, present) is deferred to Phase 2O2B2.
    return RenderFrameResult::kUnavailable;
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

} // namespace render
} // namespace vanguard

#endif // __ANDROID__
