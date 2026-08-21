// vulkan_swapchain_render_targets.cpp
// Phase 2K: Vulkan Render Pass + Swapchain Framebuffer Foundation.
//
// On Android (__ANDROID__):
//   Owns VkRenderPass + VkImageView[] + VkFramebuffer[] lifecycle for one
//   swapchain. Receives a borrowed VkDevice (via void*); never stores the
//   native window or any WSI handle.
//
// On non-Android host builds:
//   All methods are stubs (no Vulkan/Android headers included).
//
// NOTE: Compute pipeline remains deferred. The current compute shader has no
// storage output target; future compute work requires descriptor and pipeline
// layout expansion before a VkPipeline can be created here.

#include "vulkan_swapchain_render_targets.h"

#if defined(__ANDROID__)

#define VK_USE_PLATFORM_ANDROID_KHR
#include <vulkan/vulkan.h>
#include <android/log.h>

#include <cstring>
#include <vector>

#define VGLOG_RT(...) \
    __android_log_print(ANDROID_LOG_DEBUG, "VanguardRenderTargets", __VA_ARGS__)

#endif // __ANDROID__

namespace vanguard {
namespace render {

// ---------------------------------------------------------------------------
// Impl definition
// ---------------------------------------------------------------------------

struct VulkanSwapchainRenderTargets::Impl {
#if defined(__ANDROID__)
    VkRenderPass              renderPass  = VK_NULL_HANDLE;
    std::vector<VkImageView>  imageViews;
    std::vector<VkFramebuffer> framebuffers;
#endif
    bool created = false;
};

// ---------------------------------------------------------------------------
// Constructor / destructor
// ---------------------------------------------------------------------------

VulkanSwapchainRenderTargets::VulkanSwapchainRenderTargets()
    : impl_(std::make_unique<Impl>()) {}

VulkanSwapchainRenderTargets::~VulkanSwapchainRenderTargets() {
    // destroy() requires a device handle; callers must call destroy() before
    // this object is destroyed. The destructor does not call Vulkan (device
    // pointer unavailable here). Caller owns teardown ordering.
}

// ---------------------------------------------------------------------------
// Non-Android stubs
// ---------------------------------------------------------------------------

#if !defined(__ANDROID__)

bool VulkanSwapchainRenderTargets::create(void*, uint32_t, uint32_t, uint32_t,
                                           const uint64_t*, uint32_t) {
    return false;
}

void VulkanSwapchainRenderTargets::destroy(void*) {}

bool     VulkanSwapchainRenderTargets::isCreated() const              { return false; }
uint32_t VulkanSwapchainRenderTargets::getImageCount() const          { return 0; }
uint64_t VulkanSwapchainRenderTargets::getRenderPassHandle() const    { return 0; }
uint64_t VulkanSwapchainRenderTargets::getImageViewHandle(uint32_t) const  { return 0; }
uint64_t VulkanSwapchainRenderTargets::getFramebufferHandle(uint32_t) const { return 0; }

#else // __ANDROID__

// ---------------------------------------------------------------------------
// Android helpers (anonymous namespace)
// ---------------------------------------------------------------------------

namespace {

// Portable helper: convert any Vulkan non-dispatchable handle to uint64_t
// without truncation or undefined behaviour.
//
// On 64-bit targets (VK_USE_64_BIT_PTR_DEFINES==1) non-dispatchable handles
// are pointer-sized opaque struct pointers, so static_cast to uint64_t is
// ill-formed; reinterpret_cast would work but only for pointers.
// On 32-bit targets (VK_USE_64_BIT_PTR_DEFINES==0) they are already uint64_t,
// so reinterpret_cast is ill-formed.
// Using memcpy avoids both issues and is well-defined on all ABIs and sizes.
template <typename VkHandle>
static inline uint64_t vkHandleToU64(VkHandle h) {
    static_assert(sizeof(VkHandle) <= sizeof(uint64_t),
                  "VkHandle too large for uint64_t");
    uint64_t v = 0;
    // NOLINTNEXTLINE(bugprone-undefined-memory-manipulation)
    memcpy(&v, &h, sizeof(VkHandle));
    return v;
}

// Reverse: reconstruct a VkHandle from an opaque uint64_t.
// Portable across 32-bit (VkImage == uint64_t) and 64-bit NDK ABIs.
template <typename VkHandle>
static inline VkHandle u64ToVkHandle(uint64_t v) {
    static_assert(sizeof(VkHandle) <= sizeof(uint64_t),
                  "VkHandle too large for uint64_t");
    VkHandle h{};
    // NOLINTNEXTLINE(bugprone-undefined-memory-manipulation)
    memcpy(&h, &v, sizeof(VkHandle));
    return h;
}

// Destroy render targets in safe order: framebuffers -> imageViews ->
// renderPass. Resets all handles to VK_NULL_HANDLE and clears vectors.
// device must be valid.
void DestroyAll(VkDevice device,
                VkRenderPass* renderPass,
                std::vector<VkImageView>* imageViews,
                std::vector<VkFramebuffer>* framebuffers) {
    for (VkFramebuffer fb : *framebuffers) {
        if (fb != VK_NULL_HANDLE) {
            vkDestroyFramebuffer(device, fb, nullptr);
        }
    }
    framebuffers->clear();

    for (VkImageView iv : *imageViews) {
        if (iv != VK_NULL_HANDLE) {
            vkDestroyImageView(device, iv, nullptr);
        }
    }
    imageViews->clear();

    if (*renderPass != VK_NULL_HANDLE) {
        vkDestroyRenderPass(device, *renderPass, nullptr);
        *renderPass = VK_NULL_HANDLE;
    }
}

} // anonymous namespace

// ---------------------------------------------------------------------------
// create() - Android
// ---------------------------------------------------------------------------

bool VulkanSwapchainRenderTargets::create(void* deviceHandle,
                                           uint32_t format,
                                           uint32_t extentWidth,
                                           uint32_t extentHeight,
                                           const uint64_t* imageHandles,
                                           uint32_t imageCount) {
    if (!deviceHandle || imageCount == 0 || !imageHandles ||
        extentWidth == 0 || extentHeight == 0) {
        VGLOG_RT("create: invalid arguments");
        return false;
    }

    // Destroy any pre-existing state (idempotent re-entry guard).
    if (impl_->created) {
        VGLOG_RT("create: called while already created; destroying first");
        destroy(deviceHandle);
    }

    auto* device = static_cast<VkDevice>(deviceHandle);
    auto  vkFmt  = static_cast<VkFormat>(format);
    VkExtent2D extent{extentWidth, extentHeight};

    // --- Create render pass ---
    VkAttachmentDescription colorAttachment{};
    colorAttachment.format         = vkFmt;
    colorAttachment.samples        = VK_SAMPLE_COUNT_1_BIT;
    colorAttachment.loadOp         = VK_ATTACHMENT_LOAD_OP_CLEAR;
    colorAttachment.storeOp        = VK_ATTACHMENT_STORE_OP_STORE;
    colorAttachment.stencilLoadOp  = VK_ATTACHMENT_LOAD_OP_DONT_CARE;
    colorAttachment.stencilStoreOp = VK_ATTACHMENT_STORE_OP_DONT_CARE;
    colorAttachment.initialLayout  = VK_IMAGE_LAYOUT_UNDEFINED;
    colorAttachment.finalLayout    = VK_IMAGE_LAYOUT_PRESENT_SRC_KHR;

    VkAttachmentReference colorRef{};
    colorRef.attachment = 0;
    colorRef.layout     = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL;

    VkSubpassDescription subpass{};
    subpass.pipelineBindPoint    = VK_PIPELINE_BIND_POINT_GRAPHICS;
    subpass.colorAttachmentCount = 1;
    subpass.pColorAttachments    = &colorRef;

    // External -> subpass dependency: wait for COLOR_ATTACHMENT_OUTPUT stage
    // before writing to the color attachment.
    VkSubpassDependency dep{};
    dep.srcSubpass    = VK_SUBPASS_EXTERNAL;
    dep.dstSubpass    = 0;
    dep.srcStageMask  = VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT;
    dep.dstStageMask  = VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT;
    dep.srcAccessMask = 0;
    dep.dstAccessMask = VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT;

    VkRenderPassCreateInfo rpci{};
    rpci.sType           = VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO;
    rpci.attachmentCount = 1;
    rpci.pAttachments    = &colorAttachment;
    rpci.subpassCount    = 1;
    rpci.pSubpasses      = &subpass;
    rpci.dependencyCount = 1;
    rpci.pDependencies   = &dep;

    VkRenderPass newRenderPass = VK_NULL_HANDLE;
    VkResult res = vkCreateRenderPass(device, &rpci, nullptr, &newRenderPass);
    if (res != VK_SUCCESS) {
        VGLOG_RT("vkCreateRenderPass failed: %d", static_cast<int>(res));
        return false;
    }

    // --- Create image views ---
    // imageHandles[] encodes VkImage values as uint64_t via memcpy; use
    // u64ToVkHandle to reconstruct the correct type on both 32-bit and 64-bit
    // NDK ABIs without undefined behaviour.
    std::vector<VkImageView> newImageViews;
    newImageViews.reserve(imageCount);

    for (uint32_t i = 0; i < imageCount; ++i) {
        VkImage image = u64ToVkHandle<VkImage>(imageHandles[i]);

        VkImageViewCreateInfo ivci{};
        ivci.sType                           = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO;
        ivci.image                           = image;
        ivci.viewType                        = VK_IMAGE_VIEW_TYPE_2D;
        ivci.format                          = vkFmt;
        ivci.components.r                    = VK_COMPONENT_SWIZZLE_IDENTITY;
        ivci.components.g                    = VK_COMPONENT_SWIZZLE_IDENTITY;
        ivci.components.b                    = VK_COMPONENT_SWIZZLE_IDENTITY;
        ivci.components.a                    = VK_COMPONENT_SWIZZLE_IDENTITY;
        ivci.subresourceRange.aspectMask     = VK_IMAGE_ASPECT_COLOR_BIT;
        ivci.subresourceRange.baseMipLevel   = 0;
        ivci.subresourceRange.levelCount     = 1;
        ivci.subresourceRange.baseArrayLayer = 0;
        ivci.subresourceRange.layerCount     = 1;

        VkImageView view = VK_NULL_HANDLE;
        res = vkCreateImageView(device, &ivci, nullptr, &view);
        if (res != VK_SUCCESS) {
            VGLOG_RT("vkCreateImageView[%u] failed: %d", i, static_cast<int>(res));
            // Destroy already-created views, then the render pass.
            for (VkImageView v : newImageViews) {
                vkDestroyImageView(device, v, nullptr);
            }
            vkDestroyRenderPass(device, newRenderPass, nullptr);
            return false;
        }
        newImageViews.push_back(view);
    }

    // --- Create framebuffers ---
    std::vector<VkFramebuffer> newFramebuffers;
    newFramebuffers.reserve(imageCount);

    for (uint32_t i = 0; i < imageCount; ++i) {
        VkFramebufferCreateInfo fbci{};
        fbci.sType           = VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO;
        fbci.renderPass      = newRenderPass;
        fbci.attachmentCount = 1;
        fbci.pAttachments    = &newImageViews[i];
        fbci.width           = extent.width;
        fbci.height          = extent.height;
        fbci.layers          = 1;

        VkFramebuffer fb = VK_NULL_HANDLE;
        res = vkCreateFramebuffer(device, &fbci, nullptr, &fb);
        if (res != VK_SUCCESS) {
            VGLOG_RT("vkCreateFramebuffer[%u] failed: %d", i, static_cast<int>(res));
            // Destroy partially-created framebuffers, all image views, and
            // the render pass -- leave state clean.
            for (VkFramebuffer f : newFramebuffers) {
                vkDestroyFramebuffer(device, f, nullptr);
            }
            for (VkImageView v : newImageViews) {
                vkDestroyImageView(device, v, nullptr);
            }
            vkDestroyRenderPass(device, newRenderPass, nullptr);
            return false;
        }
        newFramebuffers.push_back(fb);
    }

    // Commit.
    impl_->renderPass   = newRenderPass;
    impl_->imageViews   = std::move(newImageViews);
    impl_->framebuffers = std::move(newFramebuffers);
    impl_->created      = true;

    VGLOG_RT("create: ok extent=%ux%u images=%u",
              extentWidth, extentHeight, imageCount);
    return true;
}

// ---------------------------------------------------------------------------
// destroy() - Android - idempotent
// ---------------------------------------------------------------------------

void VulkanSwapchainRenderTargets::destroy(void* deviceHandle) {
    if (!impl_->created) return;

    if (deviceHandle) {
        auto* device = static_cast<VkDevice>(deviceHandle);
        DestroyAll(device,
                   &impl_->renderPass,
                   &impl_->imageViews,
                   &impl_->framebuffers);
    }
    impl_->created = false;
}

// ---------------------------------------------------------------------------
// Accessors - Android
// ---------------------------------------------------------------------------

bool VulkanSwapchainRenderTargets::isCreated() const {
    return impl_->created;
}

uint32_t VulkanSwapchainRenderTargets::getImageCount() const {
    if (!impl_->created) return 0;
    return static_cast<uint32_t>(impl_->framebuffers.size());
}

uint64_t VulkanSwapchainRenderTargets::getRenderPassHandle() const {
    if (!impl_->created) return 0;
    // vkHandleToU64 is portable across 32-bit (uint64_t handles) and
    // 64-bit (pointer-typed handles) NDK ABIs; see helper above.
    return vkHandleToU64(impl_->renderPass);
}

uint64_t VulkanSwapchainRenderTargets::getImageViewHandle(uint32_t index) const {
    if (!impl_->created) return 0;
    if (index >= static_cast<uint32_t>(impl_->imageViews.size())) return 0;
    return vkHandleToU64(impl_->imageViews[index]);
}

uint64_t VulkanSwapchainRenderTargets::getFramebufferHandle(uint32_t index) const {
    if (!impl_->created) return 0;
    if (index >= static_cast<uint32_t>(impl_->framebuffers.size())) return 0;
    return vkHandleToU64(impl_->framebuffers[index]);
}

#endif // __ANDROID__

} // namespace render
} // namespace vanguard
