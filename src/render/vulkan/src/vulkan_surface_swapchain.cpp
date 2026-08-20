// vulkan_surface_swapchain.cpp
// Phase 2B2: VulkanSurfaceSwapchain implementation.
//
// On Android (__ANDROID__):
//   Owns VkSurfaceKHR + VkSwapchainKHR lifecycle.
//   Receives borrowed VkInstance/VkPhysicalDevice/VkDevice and a borrowed
//   ANativeWindow* (via void*).  Does NOT acquire/release the native window.
//
// On non-Android host builds:
//   All methods are stubs (no Vulkan/Android headers included).

#include "vulkan_surface_swapchain.h"

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

#else // __ANDROID__

// ---------------------------------------------------------------------------
// Android helpers (anonymous namespace)
// ---------------------------------------------------------------------------

namespace {

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

// Create swapchain. oldSwapchain may be VK_NULL_HANDLE.
// On success, *outSwapchain is populated. On failure *outSwapchain is
// VK_NULL_HANDLE and no partial handle is leaked.
bool CreateSwapchain(VkPhysicalDevice physDev,
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

    // --- Surface capabilities ---
    VkSurfaceCapabilitiesKHR caps{};
    VkResult res = vkGetPhysicalDeviceSurfaceCapabilitiesKHR(
            physDev, surface, &caps);
    if (res != VK_SUCCESS) {
        VGLOG_SWP("vkGetPhysicalDeviceSurfaceCapabilitiesKHR failed: %d",
                  static_cast<int>(res));
        return false;
    }

    // Require COLOR_ATTACHMENT usage.
    if (!(caps.supportedUsageFlags & VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT)) {
        VGLOG_SWP("Surface does not support VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT");
        return false;
    }

    // --- Surface formats ---
    uint32_t fmtCount = 0;
    res = vkGetPhysicalDeviceSurfaceFormatsKHR(physDev, surface, &fmtCount, nullptr);
    if (res != VK_SUCCESS || fmtCount == 0) {
        VGLOG_SWP("vkGetPhysicalDeviceSurfaceFormatsKHR count failed: %d", static_cast<int>(res));
        return false;
    }
    std::vector<VkSurfaceFormatKHR> formats(fmtCount);
    res = vkGetPhysicalDeviceSurfaceFormatsKHR(physDev, surface, &fmtCount, formats.data());
    if (res != VK_SUCCESS) {
        VGLOG_SWP("vkGetPhysicalDeviceSurfaceFormatsKHR data failed: %d", static_cast<int>(res));
        return false;
    }

    VkFormat chosenFormat;
    VkColorSpaceKHR chosenColorSpace;
    if (!ChooseFormat(formats, chosenFormat, chosenColorSpace)) {
        VGLOG_SWP("No usable surface format found");
        return false;
    }

    // --- Present modes ---
    uint32_t pmCount = 0;
    res = vkGetPhysicalDeviceSurfacePresentModesKHR(physDev, surface, &pmCount, nullptr);
    if (res != VK_SUCCESS || pmCount == 0) {
        VGLOG_SWP("vkGetPhysicalDeviceSurfacePresentModesKHR count failed: %d", static_cast<int>(res));
        return false;
    }
    std::vector<VkPresentModeKHR> presentModes(pmCount);
    res = vkGetPhysicalDeviceSurfacePresentModesKHR(physDev, surface, &pmCount, presentModes.data());
    if (res != VK_SUCCESS) {
        VGLOG_SWP("vkGetPhysicalDeviceSurfacePresentModesKHR data failed: %d", static_cast<int>(res));
        return false;
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

    VkSwapchainKHR newSwapchain = VK_NULL_HANDLE;
    res = vkCreateSwapchainKHR(device, &sci, nullptr, &newSwapchain);
    if (res != VK_SUCCESS) {
        VGLOG_SWP("vkCreateSwapchainKHR failed: %d", static_cast<int>(res));
        return false;
    }

    // --- Fetch swapchain images ---
    uint32_t imgCount = 0;
    res = vkGetSwapchainImagesKHR(device, newSwapchain, &imgCount, nullptr);
    if (res != VK_SUCCESS || imgCount == 0) {
        VGLOG_SWP("vkGetSwapchainImagesKHR count failed: %d", static_cast<int>(res));
        vkDestroySwapchainKHR(device, newSwapchain, nullptr);
        return false;
    }
    std::vector<VkImage> imgs(imgCount);
    res = vkGetSwapchainImagesKHR(device, newSwapchain, &imgCount, imgs.data());
    if (res != VK_SUCCESS) {
        VGLOG_SWP("vkGetSwapchainImagesKHR data failed: %d", static_cast<int>(res));
        vkDestroySwapchainKHR(device, newSwapchain, nullptr);
        return false;
    }

    *outSwapchain   = newSwapchain;
    *outFormat      = chosenFormat;
    *outColorSpace  = chosenColorSpace;
    *outExtent      = chosenExtent;
    *outImages      = std::move(imgs);
    return true;
}

} // anonymous namespace

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
    VkSwapchainKHR newSwapchain = VK_NULL_HANDLE;
    VkFormat       newFormat;
    VkColorSpaceKHR newColorSpace;
    VkExtent2D     newExtent;
    std::vector<VkImage> newImages;

    bool ok = CreateSwapchain(physDev, device, impl_->surface,
                              width, height,
                              VK_NULL_HANDLE,
                              &newSwapchain, &newFormat, &newColorSpace,
                              &newExtent, &newImages);
    if (!ok) {
        vkDestroySurfaceKHR(instance, impl_->surface, nullptr);
        impl_->surface  = VK_NULL_HANDLE;
        impl_->instance = VK_NULL_HANDLE;
        impl_->physDev  = VK_NULL_HANDLE;
        impl_->device   = VK_NULL_HANDLE;
        return false;
    }

    impl_->swapchain   = newSwapchain;
    impl_->format      = newFormat;
    impl_->colorSpace  = newColorSpace;
    impl_->extent      = newExtent;
    impl_->images      = std::move(newImages);
    impl_->attached    = true;

    VGLOG_SWP("attach: swapchain created extent=%ux%u images=%u",
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

    bool ok = CreateSwapchain(impl_->physDev, impl_->device, impl_->surface,
                              width, height,
                              impl_->swapchain,   // oldSwapchain
                              &newSwapchain, &newFormat, &newColorSpace,
                              &newExtent, &newImages);
    if (!ok) {
        // Old swapchain/images preserved.
        VGLOG_SWP("resize: CreateSwapchain failed; keeping old swapchain");
        return false;
    }

    // Destroy old swapchain only after successful recreation.
    vkDestroySwapchainKHR(impl_->device, impl_->swapchain, nullptr);

    impl_->swapchain  = newSwapchain;
    impl_->format     = newFormat;
    impl_->colorSpace = newColorSpace;
    impl_->extent     = newExtent;
    impl_->images     = std::move(newImages);

    VGLOG_SWP("resize: new swapchain extent=%ux%u images=%u",
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

#endif // __ANDROID__

} // namespace render
} // namespace vanguard
