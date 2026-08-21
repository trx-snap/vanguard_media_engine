// vulkan_surface_swapchain.cpp
// Phase 2K: Vulkan Render Pass + Swapchain Framebuffer Foundation.
//
// On Android (__ANDROID__):
//   Owns VkSurfaceKHR + VkSwapchainKHR + swapchain images/extent/format
//   lifecycle. Render-target objects (VkRenderPass, VkImageView[],
//   VkFramebuffer[]) are delegated to VulkanSwapchainRenderTargets.
//   Receives borrowed VkInstance/VkPhysicalDevice/VkDevice and a borrowed
//   ANativeWindow* (via void*).  Does NOT acquire/release the native window.
//
// On non-Android host builds:
//   All methods are stubs (no Vulkan/Android headers included).
//
// WSI resize semantics (Khronos VkSwapchainCreateInfoKHR spec):
//   When vkCreateSwapchainKHR is called with oldSwapchain != VK_NULL_HANDLE,
//   oldSwapchain is retired even if the new swapchain creation fails.  After
//   retirement the old swapchain handle must not be used for presentation.
//   resize() preserves old state ONLY for failures that occur before
//   vkCreateSwapchainKHR is called (kFailedBeforeOldRetired).  Any failure
//   at or after vkCreateSwapchainKHR (kFailedAfterOldRetired) causes
//   fail-closed teardown; the caller must reattach / retry.
//
// NOTE: Compute pipeline remains deferred. The current compute shader has no
// storage output target; future compute work requires descriptor and pipeline
// layout expansion before a VkPipeline can be created here.

#include "vulkan_surface_swapchain.h"
#include "vulkan_swapchain_render_targets.h"

#if defined(__ANDROID__)

#define VK_USE_PLATFORM_ANDROID_KHR
#include <vulkan/vulkan.h>
#include <android/log.h>

#include <algorithm>
#include <cstring>
#include <limits>
#include <vector>

#define VGLOG_SWP(...) \
    __android_log_print(ANDROID_LOG_DEBUG, "VanguardSwapchain", __VA_ARGS__)

#endif // __ANDROID__

namespace vanguard {
namespace render {

// ---------------------------------------------------------------------------
// Impl definition
// ---------------------------------------------------------------------------

struct VulkanSurfaceSwapchain::Impl {
#if defined(__ANDROID__)
    // Borrowed (not owned) device handles - valid as long as VulkanBackend::Impl lives.
    VkInstance       instance       = VK_NULL_HANDLE;
    VkPhysicalDevice physDev        = VK_NULL_HANDLE;
    VkDevice         device         = VK_NULL_HANDLE;
    uint32_t         queueFamily    = UINT32_MAX;

    // Owned WSI handles.
    VkSurfaceKHR     surface        = VK_NULL_HANDLE;
    VkSwapchainKHR   swapchain      = VK_NULL_HANDLE;
    std::vector<VkImage> images;

    VkExtent2D       extent         = {0, 0};
    VkFormat         format         = VK_FORMAT_UNDEFINED;
    VkColorSpaceKHR  colorSpace     = VK_COLOR_SPACE_SRGB_NONLINEAR_KHR;
#endif

    // Phase 2K: render-target objects extracted into dedicated class.
    std::unique_ptr<VulkanSwapchainRenderTargets> renderTargets;

    bool attached = false;
};

// ---------------------------------------------------------------------------
// Constructor / destructor
// ---------------------------------------------------------------------------

VulkanSurfaceSwapchain::VulkanSurfaceSwapchain()
    : impl_(std::make_unique<Impl>()) {}

VulkanSurfaceSwapchain::~VulkanSurfaceSwapchain() {
    detach();
}

// ---------------------------------------------------------------------------
// Non-Android stubs
// ---------------------------------------------------------------------------

#if !defined(__ANDROID__)

bool VulkanSurfaceSwapchain::attach(void*, void*, void*, uint32_t, void*,
                                    uint32_t, uint32_t) {
    return false;
}

bool VulkanSurfaceSwapchain::resize(uint32_t, uint32_t) {
    return false;
}

void VulkanSurfaceSwapchain::detach() {}

bool VulkanSurfaceSwapchain::hasSurface() const {
    return false;
}

// Phase 2K: host stubs - no Vulkan runtime available on the host.
uint64_t VulkanSurfaceSwapchain::getRenderPassHandle() const       { return 0; }
uint32_t VulkanSurfaceSwapchain::getImageCount() const             { return 0; }
uint64_t VulkanSurfaceSwapchain::getImageViewHandle(uint32_t) const   { return 0; }
uint64_t VulkanSurfaceSwapchain::getFramebufferHandle(uint32_t) const { return 0; }

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

// Describes whether a CreateSwapchain failure occurred before or after
// vkCreateSwapchainKHR was called with a non-null oldSwapchain.
//
// Khronos spec (VkSwapchainCreateInfoKHR): oldSwapchain is retired by the
// driver at the moment vkCreateSwapchainKHR is invoked, regardless of whether
// the call succeeds.  Failures before that call (kFailedBeforeOldRetired)
// leave the old swapchain intact and re-usable.  Failures at or after that
// call (kFailedAfterOldRetired) must be treated as irrecoverable; the caller
// must reattach / retry rather than continue using the old handles.
enum class SwapchainCreateStatus {
    kSuccess,
    kFailedBeforeOldRetired,  // safe: old swapchain still valid
    kFailedAfterOldRetired,   // unsafe: old swapchain is retired; fail-closed
};

// Pick swapchain format: prefer B8G8R8A8_UNORM or R8G8B8A8_UNORM with
// SRGB_NONLINEAR; fall back to first available.
bool ChooseFormat(const std::vector<VkSurfaceFormatKHR>& formats,
                  VkFormat& outFormat,
                  VkColorSpaceKHR& outColorSpace) {
    if (formats.empty()) return false;

    for (const auto& f : formats) {
        if (f.colorSpace != VK_COLOR_SPACE_SRGB_NONLINEAR_KHR) continue;
        if (f.format == VK_FORMAT_B8G8R8A8_UNORM ||
            f.format == VK_FORMAT_R8G8B8A8_UNORM) {
            outFormat     = f.format;
            outColorSpace = f.colorSpace;
            return true;
        }
    }
    // Fallback: first entry.
    outFormat     = formats[0].format;
    outColorSpace = formats[0].colorSpace;
    return true;
}

// Pick present mode: prefer MAILBOX if available, else FIFO.
VkPresentModeKHR ChoosePresentMode(const std::vector<VkPresentModeKHR>& modes) {
    for (auto m : modes) {
        if (m == VK_PRESENT_MODE_MAILBOX_KHR) return m;
    }
    return VK_PRESENT_MODE_FIFO_KHR;
}

// Pick a supported composite alpha bit, preferring OPAQUE.
VkCompositeAlphaFlagBitsKHR ChooseCompositeAlpha(
        VkCompositeAlphaFlagsKHR supported) {
    const VkCompositeAlphaFlagBitsKHR kPreference[] = {
        VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR,
        VK_COMPOSITE_ALPHA_PRE_MULTIPLIED_BIT_KHR,
        VK_COMPOSITE_ALPHA_POST_MULTIPLIED_BIT_KHR,
        VK_COMPOSITE_ALPHA_INHERIT_BIT_KHR,
    };
    for (auto bit : kPreference) {
        if (supported & bit) return bit;
    }
    return VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR; // should not reach
}

// Create swapchain. oldSwapchain may be VK_NULL_HANDLE (attach path) or a
// live handle (resize path).
//
// Returns SwapchainCreateStatus:
//   kSuccess              - *outSwapchain and output fields are populated.
//   kFailedBeforeOldRetired - failed before vkCreateSwapchainKHR; old
//                             swapchain is still valid and re-usable.
//   kFailedAfterOldRetired  - failed at or after vkCreateSwapchainKHR (which
//                             retires oldSwapchain per spec); old swapchain is
//                             no longer usable; caller must fail-closed.
//
// On any failure *outSwapchain is VK_NULL_HANDLE and no partial handle is
// leaked.
SwapchainCreateStatus CreateSwapchain(VkPhysicalDevice physDev,
                     VkDevice device,
                     VkSurfaceKHR surface,
                     uint32_t width,
                     uint32_t height,
                     VkSwapchainKHR oldSwapchain,
                     VkSwapchainKHR* outSwapchain,
                     VkFormat* outFormat,
                     VkColorSpaceKHR* outColorSpace,
                     VkExtent2D* outExtent,
                     std::vector<VkImage>* outImages) {
    *outSwapchain = VK_NULL_HANDLE;

    // All failures before vkCreateSwapchainKHR are safe: oldSwapchain is
    // untouched and still valid.

    // --- Surface capabilities ---
    VkSurfaceCapabilitiesKHR caps{};
    VkResult res = vkGetPhysicalDeviceSurfaceCapabilitiesKHR(
            physDev, surface, &caps);
    if (res != VK_SUCCESS) {
        VGLOG_SWP("vkGetPhysicalDeviceSurfaceCapabilitiesKHR failed: %d",
                  static_cast<int>(res));
        return SwapchainCreateStatus::kFailedBeforeOldRetired;
    }

    // Require COLOR_ATTACHMENT usage.
    if (!(caps.supportedUsageFlags & VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT)) {
        VGLOG_SWP("Surface does not support VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT");
        return SwapchainCreateStatus::kFailedBeforeOldRetired;
    }

    // --- Surface formats ---
    uint32_t fmtCount = 0;
    res = vkGetPhysicalDeviceSurfaceFormatsKHR(physDev, surface, &fmtCount, nullptr);
    if (res != VK_SUCCESS || fmtCount == 0) {
        VGLOG_SWP("vkGetPhysicalDeviceSurfaceFormatsKHR count failed: %d", static_cast<int>(res));
        return SwapchainCreateStatus::kFailedBeforeOldRetired;
    }
    std::vector<VkSurfaceFormatKHR> formats(fmtCount);
    res = vkGetPhysicalDeviceSurfaceFormatsKHR(physDev, surface, &fmtCount, formats.data());
    if (res != VK_SUCCESS) {
        VGLOG_SWP("vkGetPhysicalDeviceSurfaceFormatsKHR data failed: %d", static_cast<int>(res));
        return SwapchainCreateStatus::kFailedBeforeOldRetired;
    }

    VkFormat chosenFormat;
    VkColorSpaceKHR chosenColorSpace;
    if (!ChooseFormat(formats, chosenFormat, chosenColorSpace)) {
        VGLOG_SWP("No usable surface format found");
        return SwapchainCreateStatus::kFailedBeforeOldRetired;
    }

    // --- Present modes ---
    uint32_t pmCount = 0;
    res = vkGetPhysicalDeviceSurfacePresentModesKHR(physDev, surface, &pmCount, nullptr);
    if (res != VK_SUCCESS || pmCount == 0) {
        VGLOG_SWP("vkGetPhysicalDeviceSurfacePresentModesKHR count failed: %d", static_cast<int>(res));
        return SwapchainCreateStatus::kFailedBeforeOldRetired;
    }
    std::vector<VkPresentModeKHR> presentModes(pmCount);
    res = vkGetPhysicalDeviceSurfacePresentModesKHR(physDev, surface, &pmCount, presentModes.data());
    if (res != VK_SUCCESS) {
        VGLOG_SWP("vkGetPhysicalDeviceSurfacePresentModesKHR data failed: %d", static_cast<int>(res));
        return SwapchainCreateStatus::kFailedBeforeOldRetired;
    }
    VkPresentModeKHR chosenPresentMode = ChoosePresentMode(presentModes);

    // --- Extent ---
    VkExtent2D chosenExtent;
    if (caps.currentExtent.width != std::numeric_limits<uint32_t>::max()) {
        chosenExtent = caps.currentExtent;
    } else {
        chosenExtent.width  = std::max(caps.minImageExtent.width,
                                       std::min(caps.maxImageExtent.width,  width));
        chosenExtent.height = std::max(caps.minImageExtent.height,
                                       std::min(caps.maxImageExtent.height, height));
    }

    // --- Image count: minImageCount+1, at least 3 when allowed ---
    uint32_t imageCount = caps.minImageCount + 1;
    if (imageCount < 3 &&
        (caps.maxImageCount == 0 || caps.maxImageCount >= 3)) {
        imageCount = 3;
    }
    if (caps.maxImageCount > 0 && imageCount > caps.maxImageCount) {
        imageCount = caps.maxImageCount;
    }

    VkCompositeAlphaFlagBitsKHR compositeAlpha =
            ChooseCompositeAlpha(caps.supportedCompositeAlpha);

    // --- Create swapchain ---
    VkSwapchainCreateInfoKHR sci{};
    sci.sType            = VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR;
    sci.surface          = surface;
    sci.minImageCount    = imageCount;
    sci.imageFormat      = chosenFormat;
    sci.imageColorSpace  = chosenColorSpace;
    sci.imageExtent      = chosenExtent;
    sci.imageArrayLayers = 1;
    sci.imageUsage       = VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT;
    sci.imageSharingMode = VK_SHARING_MODE_EXCLUSIVE;
    sci.preTransform     = caps.currentTransform;
    sci.compositeAlpha   = compositeAlpha;
    sci.presentMode      = chosenPresentMode;
    sci.clipped          = VK_TRUE;
    sci.oldSwapchain     = oldSwapchain;

    // *** Retirement point ***
    // From this moment on, if oldSwapchain != VK_NULL_HANDLE, the driver
    // retires it regardless of whether vkCreateSwapchainKHR succeeds.
    // All subsequent failures must return kFailedAfterOldRetired when
    // oldSwapchain was non-null; otherwise they remain kFailedBeforeOldRetired.
    VkSwapchainKHR newSwapchain = VK_NULL_HANDLE;
    res = vkCreateSwapchainKHR(device, &sci, nullptr, &newSwapchain);
    if (res != VK_SUCCESS) {
        VGLOG_SWP("vkCreateSwapchainKHR failed: %d", static_cast<int>(res));
        // Destroy any partial newSwapchain (none was created on failure, but
        // guard for safety).
        if (newSwapchain != VK_NULL_HANDLE) {
            vkDestroySwapchainKHR(device, newSwapchain, nullptr);
        }
        // If oldSwapchain was non-null the driver has retired it; escalate.
        if (oldSwapchain != VK_NULL_HANDLE) {
            return SwapchainCreateStatus::kFailedAfterOldRetired;
        }
        return SwapchainCreateStatus::kFailedBeforeOldRetired;
    }

    // --- Fetch swapchain images ---
    uint32_t imgCount = 0;
    res = vkGetSwapchainImagesKHR(device, newSwapchain, &imgCount, nullptr);
    if (res != VK_SUCCESS || imgCount == 0) {
        VGLOG_SWP("vkGetSwapchainImagesKHR count failed: %d", static_cast<int>(res));
        vkDestroySwapchainKHR(device, newSwapchain, nullptr);
        // oldSwapchain has been retired (we passed vkCreateSwapchainKHR).
        if (oldSwapchain != VK_NULL_HANDLE) {
            return SwapchainCreateStatus::kFailedAfterOldRetired;
        }
        return SwapchainCreateStatus::kFailedBeforeOldRetired;
    }
    std::vector<VkImage> imgs(imgCount);
    res = vkGetSwapchainImagesKHR(device, newSwapchain, &imgCount, imgs.data());
    if (res != VK_SUCCESS) {
        VGLOG_SWP("vkGetSwapchainImagesKHR data failed: %d", static_cast<int>(res));
        vkDestroySwapchainKHR(device, newSwapchain, nullptr);
        if (oldSwapchain != VK_NULL_HANDLE) {
            return SwapchainCreateStatus::kFailedAfterOldRetired;
        }
        return SwapchainCreateStatus::kFailedBeforeOldRetired;
    }

    *outSwapchain   = newSwapchain;
    *outFormat      = chosenFormat;
    *outColorSpace  = chosenColorSpace;
    *outExtent      = chosenExtent;
    *outImages      = std::move(imgs);
    return SwapchainCreateStatus::kSuccess;
}

// Build a uint64_t array from a VkImage vector using the portable vkHandleToU64
// memcpy helper.  Passed to VulkanSwapchainRenderTargets::create(), which
// reconstructs VkImage values on the other side via the matching u64ToVkHandle.
static std::vector<uint64_t> BuildImageHandleArray(
        const std::vector<VkImage>& images) {
    std::vector<uint64_t> handles(images.size());
    for (size_t i = 0; i < images.size(); ++i) {
        handles[i] = vkHandleToU64(images[i]);
    }
    return handles;
}

} // anonymous namespace - end of Phase 2B2 helpers


// ---------------------------------------------------------------------------
// attach() - Android
// ---------------------------------------------------------------------------

bool VulkanSurfaceSwapchain::attach(void* instanceHandle,
                                    void* physicalDeviceHandle,
                                    void* deviceHandle,
                                    uint32_t queueFamilyIndex,
                                    void* nativeWindow,
                                    uint32_t width,
                                    uint32_t height) {
    if (!instanceHandle || !physicalDeviceHandle || !deviceHandle ||
        !nativeWindow || width == 0 || height == 0 ||
        queueFamilyIndex == UINT32_MAX) {
        VGLOG_SWP("attach: invalid arguments");
        return false;
    }

    // If already attached, tear down first.
    if (impl_->attached) {
        detach();
    }

    auto* instance  = static_cast<VkInstance>(instanceHandle);
    auto* physDev   = static_cast<VkPhysicalDevice>(physicalDeviceHandle);
    auto* device    = static_cast<VkDevice>(deviceHandle);
    auto* window    = static_cast<ANativeWindow*>(nativeWindow);

    // Store borrowed handles.
    impl_->instance    = instance;
    impl_->physDev     = physDev;
    impl_->device      = device;
    impl_->queueFamily = queueFamilyIndex;

    // --- Create VkSurfaceKHR via VK_KHR_android_surface ---
    VkAndroidSurfaceCreateInfoKHR surfCI{};
    surfCI.sType  = VK_STRUCTURE_TYPE_ANDROID_SURFACE_CREATE_INFO_KHR;
    surfCI.window = window;

    VkResult res = vkCreateAndroidSurfaceKHR(instance, &surfCI, nullptr,
                                              &impl_->surface);
    if (res != VK_SUCCESS) {
        VGLOG_SWP("vkCreateAndroidSurfaceKHR failed: %d", static_cast<int>(res));
        impl_->instance = VK_NULL_HANDLE;
        impl_->physDev  = VK_NULL_HANDLE;
        impl_->device   = VK_NULL_HANDLE;
        return false;
    }

    // --- Confirm presentation support on this queue family ---
    VkBool32 presentSupported = VK_FALSE;
    res = vkGetPhysicalDeviceSurfaceSupportKHR(physDev, queueFamilyIndex,
                                               impl_->surface,
                                               &presentSupported);
    if (res != VK_SUCCESS || presentSupported != VK_TRUE) {
        VGLOG_SWP("Queue family %u does not support presentation: res=%d supported=%d",
                  queueFamilyIndex, static_cast<int>(res),
                  static_cast<int>(presentSupported));
        vkDestroySurfaceKHR(instance, impl_->surface, nullptr);
        impl_->surface  = VK_NULL_HANDLE;
        impl_->instance = VK_NULL_HANDLE;
        impl_->physDev  = VK_NULL_HANDLE;
        impl_->device   = VK_NULL_HANDLE;
        return false;
    }

    // --- Create swapchain ---
    // attach always passes VK_NULL_HANDLE as oldSwapchain, so any failure is
    // kFailedBeforeOldRetired (clean attach failure; surface is still ours).
    VkSwapchainKHR newSwapchain = VK_NULL_HANDLE;
    VkFormat       newFormat;
    VkColorSpaceKHR newColorSpace;
    VkExtent2D     newExtent;
    std::vector<VkImage> newImages;

    SwapchainCreateStatus scStatus = CreateSwapchain(
            physDev, device, impl_->surface,
            width, height,
            VK_NULL_HANDLE,
            &newSwapchain, &newFormat, &newColorSpace,
            &newExtent, &newImages);
    if (scStatus != SwapchainCreateStatus::kSuccess) {
        vkDestroySurfaceKHR(instance, impl_->surface, nullptr);
        impl_->surface  = VK_NULL_HANDLE;
        impl_->instance = VK_NULL_HANDLE;
        impl_->physDev  = VK_NULL_HANDLE;
        impl_->device   = VK_NULL_HANDLE;
        return false;
    }

    // --- Phase 2K: create render targets via dedicated class ---
    if (!impl_->renderTargets) {
        impl_->renderTargets = std::make_unique<VulkanSwapchainRenderTargets>();
    }

    // Encode VkImage handles as uint64_t via memcpy (portable across 32-bit
    // and 64-bit NDK ABIs) before passing to VulkanSwapchainRenderTargets.
    std::vector<uint64_t> imageHandles = BuildImageHandleArray(newImages);

    if (!impl_->renderTargets->create(
            static_cast<void*>(device),
            static_cast<uint32_t>(newFormat),
            newExtent.width,
            newExtent.height,
            imageHandles.data(),
            static_cast<uint32_t>(newImages.size()))) {
        // Render-target creation failed; clean up new swapchain and surface.
        impl_->renderTargets->destroy(static_cast<void*>(device));
        vkDestroySwapchainKHR(device, newSwapchain, nullptr);
        vkDestroySurfaceKHR(instance, impl_->surface, nullptr);
        impl_->surface  = VK_NULL_HANDLE;
        impl_->instance = VK_NULL_HANDLE;
        impl_->physDev  = VK_NULL_HANDLE;
        impl_->device   = VK_NULL_HANDLE;
        return false;
    }

    // All steps succeeded - commit to impl_.
    impl_->swapchain    = newSwapchain;
    impl_->format       = newFormat;
    impl_->colorSpace   = newColorSpace;
    impl_->extent       = newExtent;
    impl_->images       = std::move(newImages);
    impl_->attached     = true;

    VGLOG_SWP("attach: swapchain+render targets created extent=%ux%u images=%u",
              impl_->extent.width, impl_->extent.height,
              static_cast<uint32_t>(impl_->images.size()));
    return true;
}

// ---------------------------------------------------------------------------
// resize() - Android
// ---------------------------------------------------------------------------

bool VulkanSurfaceSwapchain::resize(uint32_t width, uint32_t height) {
    if (!impl_->attached || width == 0 || height == 0) {
        VGLOG_SWP("resize: not attached or zero dimensions");
        return false;
    }

    VkSwapchainKHR newSwapchain = VK_NULL_HANDLE;
    VkFormat       newFormat;
    VkColorSpaceKHR newColorSpace;
    VkExtent2D     newExtent;
    std::vector<VkImage> newImages;

    // Pass existing swapchain as oldSwapchain.  Per Khronos spec, the driver
    // retires oldSwapchain at the moment vkCreateSwapchainKHR is entered,
    // regardless of success.  CreateSwapchain distinguishes:
    //   kFailedBeforeOldRetired -> old handles still valid; keep old state.
    //   kFailedAfterOldRetired  -> old swapchain retired; must fail-closed.
    SwapchainCreateStatus scStatus = CreateSwapchain(
            impl_->physDev, impl_->device, impl_->surface,
            width, height,
            impl_->swapchain,   // oldSwapchain
            &newSwapchain, &newFormat, &newColorSpace,
            &newExtent, &newImages);

    if (scStatus == SwapchainCreateStatus::kFailedBeforeOldRetired) {
        // Safe: old swapchain/images/render targets are fully preserved.
        VGLOG_SWP("resize: swapchain query failed before retirement; old state preserved");
        return false;
    }

    if (scStatus == SwapchainCreateStatus::kFailedAfterOldRetired) {
        // Old swapchain has been retired by the driver; it must not be used.
        // Fail-closed: tear down everything and mark detached.
        VGLOG_SWP("resize: vkCreateSwapchainKHR failed after old swapchain retirement; failing closed");
        if (impl_->device != VK_NULL_HANDLE) {
            vkDeviceWaitIdle(impl_->device);
            if (impl_->renderTargets) {
                impl_->renderTargets->destroy(static_cast<void*>(impl_->device));
            }
        }
        if (impl_->swapchain != VK_NULL_HANDLE) {
            vkDestroySwapchainKHR(impl_->device, impl_->swapchain, nullptr);
            impl_->swapchain = VK_NULL_HANDLE;
        }
        if (impl_->surface != VK_NULL_HANDLE) {
            vkDestroySurfaceKHR(impl_->instance, impl_->surface, nullptr);
            impl_->surface = VK_NULL_HANDLE;
        }
        impl_->images.clear();
        impl_->extent     = {0, 0};
        impl_->format     = VK_FORMAT_UNDEFINED;
        impl_->colorSpace = VK_COLOR_SPACE_SRGB_NONLINEAR_KHR;
        // Keep borrowed device handles so the caller can inspect them, but
        // mark detached so all accessors return safe defaults.
        impl_->attached = false;
        return false;
    }

    // scStatus == kSuccess: new swapchain is live.  oldSwapchain has been
    // retired by the driver.  Now build render targets into a temporary
    // VulkanSwapchainRenderTargets instance.  We do NOT touch old render
    // targets until we have confirmed success AND called vkDeviceWaitIdle.
    //
    // Any failure here is post-retirement and requires the same fail-closed
    // teardown (old render targets reference the retired swapchain's images).

    // Encode VkImage handles as uint64_t via memcpy (portable across 32-bit
    // and 64-bit NDK ABIs) before passing to VulkanSwapchainRenderTargets.
    std::vector<uint64_t> imageHandles = BuildImageHandleArray(newImages);

    // Create new render targets in a temporary instance so that the old
    // render targets are not touched until device is idle.
    auto newRenderTargets = std::make_unique<VulkanSwapchainRenderTargets>();

    if (!newRenderTargets->create(
            static_cast<void*>(impl_->device),
            static_cast<uint32_t>(newFormat),
            newExtent.width,
            newExtent.height,
            imageHandles.data(),
            static_cast<uint32_t>(newImages.size()))) {
        // New render-target creation failed. New swapchain succeeded but
        // oldSwapchain is already retired. Fail-closed:
        //   1. Destroy new render targets (partially-created objects cleaned
        //      inside create(), but destroy() is idempotent / safe to call).
        //   2. Destroy new swapchain.
        //   3. vkDeviceWaitIdle (GPU may still reference old RT resources).
        //   4. Destroy old render targets and old swapchain (retired handle).
        //   5. Destroy surface, clear state, attached=false.
        VGLOG_SWP("resize: render-target creation failed post-retirement; failing closed");
        newRenderTargets->destroy(static_cast<void*>(impl_->device));
        vkDestroySwapchainKHR(impl_->device, newSwapchain, nullptr);

        if (impl_->device != VK_NULL_HANDLE) {
            vkDeviceWaitIdle(impl_->device);
        }

        // Destroy old render targets (GPU is now idle).
        if (impl_->renderTargets && impl_->renderTargets->isCreated()) {
            impl_->renderTargets->destroy(static_cast<void*>(impl_->device));
        }

        // Old WSI swapchain already retired by driver; destroy handle.
        if (impl_->swapchain != VK_NULL_HANDLE) {
            vkDestroySwapchainKHR(impl_->device, impl_->swapchain, nullptr);
            impl_->swapchain = VK_NULL_HANDLE;
        }
        if (impl_->surface != VK_NULL_HANDLE) {
            vkDestroySurfaceKHR(impl_->instance, impl_->surface, nullptr);
            impl_->surface = VK_NULL_HANDLE;
        }
        impl_->images.clear();
        impl_->extent     = {0, 0};
        impl_->format     = VK_FORMAT_UNDEFINED;
        impl_->colorSpace = VK_COLOR_SPACE_SRGB_NONLINEAR_KHR;
        impl_->attached   = false;
        return false;
    }

    // All steps succeeded.
    //   1. vkDeviceWaitIdle: ensure GPU is done with old render targets.
    //   2. Destroy old render targets (GPU is now idle).
    //   3. Destroy old swapchain (driver already retired it; this frees any
    //      remaining driver-side resources per Vulkan spec).
    //   4. Move/commit new render targets and new swapchain state.
    if (impl_->device != VK_NULL_HANDLE) {
        vkDeviceWaitIdle(impl_->device);
    }

    // Destroy old render targets (GPU is now idle; safe to release).
    if (impl_->renderTargets && impl_->renderTargets->isCreated()) {
        impl_->renderTargets->destroy(static_cast<void*>(impl_->device));
    }

    // Destroy old swapchain handle (driver has already retired it).
    vkDestroySwapchainKHR(impl_->device, impl_->swapchain, nullptr);

    // Commit new state.
    impl_->renderTargets = std::move(newRenderTargets);
    impl_->swapchain     = newSwapchain;
    impl_->format        = newFormat;
    impl_->colorSpace    = newColorSpace;
    impl_->extent        = newExtent;
    impl_->images        = std::move(newImages);

    VGLOG_SWP("resize: new swapchain+render targets extent=%ux%u images=%u",
              impl_->extent.width, impl_->extent.height,
              static_cast<uint32_t>(impl_->images.size()));
    return true;
}

// ---------------------------------------------------------------------------
// detach() - Android - idempotent
// ---------------------------------------------------------------------------

void VulkanSurfaceSwapchain::detach() {
    if (!impl_->attached) return;

    if (impl_->device != VK_NULL_HANDLE) {
        vkDeviceWaitIdle(impl_->device);
    }

    // Phase 2K: destroy render targets first (framebuffers -> imageViews ->
    // renderPass), then swapchain, then surface.
    if (impl_->renderTargets && impl_->device != VK_NULL_HANDLE) {
        impl_->renderTargets->destroy(static_cast<void*>(impl_->device));
    }

    if (impl_->swapchain != VK_NULL_HANDLE) {
        vkDestroySwapchainKHR(impl_->device, impl_->swapchain, nullptr);
        impl_->swapchain = VK_NULL_HANDLE;
    }

    if (impl_->surface != VK_NULL_HANDLE) {
        vkDestroySurfaceKHR(impl_->instance, impl_->surface, nullptr);
        impl_->surface = VK_NULL_HANDLE;
    }

    impl_->images.clear();
    impl_->extent      = {0, 0};
    impl_->format      = VK_FORMAT_UNDEFINED;
    impl_->colorSpace  = VK_COLOR_SPACE_SRGB_NONLINEAR_KHR;

    // Clear borrowed references (they are not owned here).
    impl_->instance    = VK_NULL_HANDLE;
    impl_->physDev     = VK_NULL_HANDLE;
    impl_->device      = VK_NULL_HANDLE;
    impl_->queueFamily = UINT32_MAX;

    impl_->attached = false;
    VGLOG_SWP("detach: complete");
}

// ---------------------------------------------------------------------------
// hasSurface()
// ---------------------------------------------------------------------------

bool VulkanSurfaceSwapchain::hasSurface() const {
    return impl_->attached;
}

// ---------------------------------------------------------------------------
// Phase 2K render-target getters - Android
// Delegate to VulkanSwapchainRenderTargets for handle access.
// ---------------------------------------------------------------------------

uint64_t VulkanSurfaceSwapchain::getRenderPassHandle() const {
    if (!impl_->attached || !impl_->renderTargets) return 0;
    return impl_->renderTargets->getRenderPassHandle();
}

uint32_t VulkanSurfaceSwapchain::getImageCount() const {
    if (!impl_->attached || !impl_->renderTargets) return 0;
    return impl_->renderTargets->getImageCount();
}

uint64_t VulkanSurfaceSwapchain::getImageViewHandle(uint32_t index) const {
    if (!impl_->attached || !impl_->renderTargets) return 0;
    return impl_->renderTargets->getImageViewHandle(index);
}

uint64_t VulkanSurfaceSwapchain::getFramebufferHandle(uint32_t index) const {
    if (!impl_->attached || !impl_->renderTargets) return 0;
    return impl_->renderTargets->getFramebufferHandle(index);
}

#endif // __ANDROID__

} // namespace render
} // namespace vanguard
