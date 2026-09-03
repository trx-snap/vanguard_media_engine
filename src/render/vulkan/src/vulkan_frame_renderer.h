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

    // P5-COMPOSITOR-TRANS: two-source clip overlap transition frame. Same
    // acquire / frame fence / imageAvailable + presentReady semaphore /
    // pending AHB acquire semaphore wait / release-fence export / present
    // protocol as renderFrame, with the "from" and "to" imports drawn into
    // one clear render pass per [VideoTransitionFrameTransform]'s draw model.
    // Transition pipelines are rebuilt per call (pipeline layouts are per
    // import) after a device idle wait and retired on the next render call,
    // failClosed, invalidatePipeline or shutdown.
    RenderFrameResult renderTransitionFrame(
        void* queueHandle,
        VulkanSurfaceSwapchain& swapchain,
        VulkanHardwareBufferImports& ahbImports,
        VulkanCoreShaderModules& coreShaders,
        HardwareBufferHandle fromHandle,
        HardwareBufferHandle toHandle,
        const VideoTransitionFrameTransform& transition);

private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};

} // namespace render
} // namespace vanguard
