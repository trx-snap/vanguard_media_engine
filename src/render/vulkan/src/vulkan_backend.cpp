// Phase 2B2: VulkanBackend implementation.
//
// On Android (__ANDROID__):
//   - Vulkan headers included here, never in the public header.
//   - Phase 2B1: instance extension check, VkInstance (API 1.1),
//     physical device selection, queue family, VkDevice, vkGetDeviceQueue.
//   - Phase 2B2: delegates surface/swapchain lifecycle to VulkanSurfaceSwapchain.
//
// On non-Android host builds:
//   - No Vulkan headers included.
//   - initialize() returns false; shutdown() is a no-op.
//   - Surface methods return false / no-op.

#include "vanguard/render/vulkan_backend.h"
#include "vulkan_surface_swapchain.h"

#if defined(__ANDROID__)

#include <vulkan/vulkan.h>
#include <android/log.h>

#include <cstring>
#include <vector>

#define VGLOG_VKB(...) __android_log_print(ANDROID_LOG_DEBUG, "VanguardVkBackend", __VA_ARGS__)

#endif // __ANDROID__

namespace vanguard {
namespace render {

// ---------------------------------------------------------------------------
// Impl definition
// ---------------------------------------------------------------------------

struct VulkanBackend::Impl {
#if defined(__ANDROID__)
    VkInstance       instance  = VK_NULL_HANDLE;
    VkPhysicalDevice physDev   = VK_NULL_HANDLE;
    VkDevice         device    = VK_NULL_HANDLE;
    VkQueue          queue     = VK_NULL_HANDLE;
    uint32_t         queueFamilyIndex = UINT32_MAX;
#endif

    // Phase 2B2: surface/swapchain lifecycle helper.
    std::unique_ptr<VulkanSurfaceSwapchain> surfaceSwapchain;

    bool initialized = false;
};

// ---------------------------------------------------------------------------
// Constructor / destructor
// ---------------------------------------------------------------------------

VulkanBackend::VulkanBackend()
    : impl_(std::make_unique<Impl>()) {}

VulkanBackend::~VulkanBackend() {
    shutdown();
}

// ---------------------------------------------------------------------------
// type()
// ---------------------------------------------------------------------------

RenderBackendType VulkanBackend::type() const {
    return RenderBackendType::kVulkan;
}

// ---------------------------------------------------------------------------
// initialize() / shutdown() - non-Android stub
// ---------------------------------------------------------------------------

#if !defined(__ANDROID__)

bool VulkanBackend::initialize() {
    return false;
}

void VulkanBackend::shutdown() {
    // no-op on host builds
}

bool VulkanBackend::attachSurface(void*, uint32_t, uint32_t) {
    return false;
}

bool VulkanBackend::resizeSurface(uint32_t, uint32_t) {
    return false;
}

void VulkanBackend::detachSurface() {
    // no-op on host builds
}

bool VulkanBackend::hasSurface() const {
    return false;
}

#else // __ANDROID__

// ---------------------------------------------------------------------------
// Android-only helpers (anonymous namespace, file-local)
// ---------------------------------------------------------------------------

namespace {

// Required instance extensions (instance-scoped per Khronos spec).
static const char* kRequiredInstanceExtensions[] = {
    "VK_KHR_surface",
    "VK_KHR_android_surface",
};
static constexpr uint32_t kRequiredInstanceExtensionCount =
    static_cast<uint32_t>(sizeof(kRequiredInstanceExtensions) /
                           sizeof(kRequiredInstanceExtensions[0]));

// Required device extensions (device-scoped per Khronos spec).
static const char* kRequiredDeviceExtensions[] = {
    "VK_KHR_swapchain",
    "VK_ANDROID_external_memory_android_hardware_buffer",
};
static constexpr uint32_t kRequiredDeviceExtensionCount =
    static_cast<uint32_t>(sizeof(kRequiredDeviceExtensions) /
                           sizeof(kRequiredDeviceExtensions[0]));

// Returns true iff all required instance extensions are advertised by the
// loader / driver via vkEnumerateInstanceExtensionProperties.
bool CheckInstanceExtensions() {
    uint32_t count = 0;
    if (vkEnumerateInstanceExtensionProperties(nullptr, &count, nullptr) != VK_SUCCESS) {
        VGLOG_VKB("vkEnumerateInstanceExtensionProperties count query failed");
        return false;
    }
    std::vector<VkExtensionProperties> available(count);
    if (vkEnumerateInstanceExtensionProperties(nullptr, &count, available.data()) != VK_SUCCESS) {
        VGLOG_VKB("vkEnumerateInstanceExtensionProperties data query failed");
        return false;
    }
    for (uint32_t req = 0; req < kRequiredInstanceExtensionCount; ++req) {
        bool found = false;
        for (uint32_t i = 0; i < count; ++i) {
            if (std::strcmp(available[i].extensionName,
                            kRequiredInstanceExtensions[req]) == 0) {
                found = true;
                break;
            }
        }
        if (!found) {
            VGLOG_VKB("Missing required instance extension: %s",
                      kRequiredInstanceExtensions[req]);
            return false;
        }
    }
    return true;
}

// Returns true iff all required device extensions are advertised for `physDev`.
bool CheckDeviceExtensions(VkPhysicalDevice physDev) {
    uint32_t count = 0;
    if (vkEnumerateDeviceExtensionProperties(physDev, nullptr, &count, nullptr) != VK_SUCCESS) {
        VGLOG_VKB("vkEnumerateDeviceExtensionProperties count query failed");
        return false;
    }
    std::vector<VkExtensionProperties> available(count);
    if (vkEnumerateDeviceExtensionProperties(physDev, nullptr, &count, available.data()) != VK_SUCCESS) {
        VGLOG_VKB("vkEnumerateDeviceExtensionProperties data query failed");
        return false;
    }
    for (uint32_t req = 0; req < kRequiredDeviceExtensionCount; ++req) {
        bool found = false;
        for (uint32_t i = 0; i < count; ++i) {
            if (std::strcmp(available[i].extensionName,
                            kRequiredDeviceExtensions[req]) == 0) {
                found = true;
                break;
            }
        }
        if (!found) {
            VGLOG_VKB("Missing required device extension: %s",
                      kRequiredDeviceExtensions[req]);
            return false;
        }
    }
    return true;
}

// Returns true iff the device reports samplerYcbcrConversion == VK_TRUE via
// the VkPhysicalDeviceFeatures2 / VkPhysicalDeviceSamplerYcbcrConversionFeatures
// pNext chain.  Requires Vulkan 1.1 (feature query via pNext is core 1.1).
bool CheckYcbcrConversionFeature(VkPhysicalDevice physDev) {
    VkPhysicalDeviceSamplerYcbcrConversionFeatures ycbcr{};
    ycbcr.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_SAMPLER_YCBCR_CONVERSION_FEATURES;
    ycbcr.pNext = nullptr;

    VkPhysicalDeviceFeatures2 features2{};
    features2.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2;
    features2.pNext = &ycbcr;

    vkGetPhysicalDeviceFeatures2(physDev, &features2);

    if (ycbcr.samplerYcbcrConversion != VK_TRUE) {
        VGLOG_VKB("samplerYcbcrConversion not supported on physical device");
        return false;
    }
    return true;
}

// Returns the index of the first queue family supporting both GRAPHICS and
// COMPUTE bits, or UINT32_MAX if none qualifies.  Transfer is implicit for
// either graphics or compute queues; a separate transfer bit is not required.
uint32_t FindQueueFamily(VkPhysicalDevice physDev) {
    uint32_t count = 0;
    vkGetPhysicalDeviceQueueFamilyProperties(physDev, &count, nullptr);
    std::vector<VkQueueFamilyProperties> families(count);
    vkGetPhysicalDeviceQueueFamilyProperties(physDev, &count, families.data());

    constexpr VkQueueFlags kRequired = VK_QUEUE_GRAPHICS_BIT | VK_QUEUE_COMPUTE_BIT;
    for (uint32_t i = 0; i < count; ++i) {
        if ((families[i].queueFlags & kRequired) == kRequired) {
            return i;
        }
    }
    return UINT32_MAX;
}

} // anonymous namespace

// ---------------------------------------------------------------------------
// initialize() - Android
// ---------------------------------------------------------------------------

bool VulkanBackend::initialize() {
    if (impl_->initialized) {
        return true; // idempotent
    }

    // Convenience alias.
    Impl& s = *impl_;

    // --- 1. Check required instance extensions ---
    if (!CheckInstanceExtensions()) {
        VGLOG_VKB("Required instance extensions not available");
        return false;
    }

    // --- 2. Create VkInstance with Vulkan API 1.1 ---
    VkApplicationInfo appInfo{};
    appInfo.sType            = VK_STRUCTURE_TYPE_APPLICATION_INFO;
    appInfo.pApplicationName = "VanguardMediaEngine";
    appInfo.applicationVersion = VK_MAKE_VERSION(0, 1, 0);
    appInfo.pEngineName      = "VanguardRenderEngine";
    appInfo.engineVersion    = VK_MAKE_VERSION(0, 1, 0);
    appInfo.apiVersion       = VK_API_VERSION_1_1;

    VkInstanceCreateInfo instanceCI{};
    instanceCI.sType                   = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO;
    instanceCI.pApplicationInfo        = &appInfo;
    instanceCI.enabledExtensionCount   = kRequiredInstanceExtensionCount;
    instanceCI.ppEnabledExtensionNames = kRequiredInstanceExtensions;

    VkResult result = vkCreateInstance(&instanceCI, nullptr, &s.instance);
    if (result != VK_SUCCESS) {
        VGLOG_VKB("vkCreateInstance failed: %d", static_cast<int>(result));
        // Nothing to destroy yet.
        return false;
    }

    // --- 3. Enumerate physical devices ---
    uint32_t deviceCount = 0;
    result = vkEnumeratePhysicalDevices(s.instance, &deviceCount, nullptr);
    if (result != VK_SUCCESS || deviceCount == 0) {
        VGLOG_VKB("No Vulkan physical devices found");
        vkDestroyInstance(s.instance, nullptr);
        s.instance = VK_NULL_HANDLE;
        return false;
    }
    std::vector<VkPhysicalDevice> devices(deviceCount);
    result = vkEnumeratePhysicalDevices(s.instance, &deviceCount, devices.data());
    if (result != VK_SUCCESS) {
        VGLOG_VKB("vkEnumeratePhysicalDevices data query failed");
        vkDestroyInstance(s.instance, nullptr);
        s.instance = VK_NULL_HANDLE;
        return false;
    }

    // --- 4. Select physical device ---
    //   Requirements:
    //     a) Not VK_PHYSICAL_DEVICE_TYPE_CPU
    //     b) API version >= Vulkan 1.1
    //     c) Required device extensions present
    //     d) samplerYcbcrConversion == VK_TRUE
    //     e) At least one queue family with GRAPHICS | COMPUTE

    VkPhysicalDevice chosen = VK_NULL_HANDLE;
    uint32_t chosenQueueFamily = UINT32_MAX;

    for (VkPhysicalDevice dev : devices) {
        VkPhysicalDeviceProperties props{};
        vkGetPhysicalDeviceProperties(dev, &props);

        VGLOG_VKB("Evaluating device: %s (type=%d, apiVersion=%u.%u)",
                  props.deviceName,
                  static_cast<int>(props.deviceType),
                  VK_VERSION_MAJOR(props.apiVersion),
                  VK_VERSION_MINOR(props.apiVersion));

        // a) Reject CPU / software renderers.
        if (props.deviceType == VK_PHYSICAL_DEVICE_TYPE_CPU) {
            VGLOG_VKB("  Rejected: CPU/software renderer");
            continue;
        }

        // b) Require Vulkan API >= 1.1.
        if (VK_VERSION_MAJOR(props.apiVersion) < 1 ||
            (VK_VERSION_MAJOR(props.apiVersion) == 1 &&
             VK_VERSION_MINOR(props.apiVersion) < 1)) {
            VGLOG_VKB("  Rejected: API version < 1.1");
            continue;
        }

        // c) Required device extensions.
        if (!CheckDeviceExtensions(dev)) {
            VGLOG_VKB("  Rejected: missing required device extensions");
            continue;
        }

        // d) samplerYcbcrConversion feature.
        if (!CheckYcbcrConversionFeature(dev)) {
            VGLOG_VKB("  Rejected: samplerYcbcrConversion not supported");
            continue;
        }

        // e) Queue family with GRAPHICS | COMPUTE.
        uint32_t queueFamily = FindQueueFamily(dev);
        if (queueFamily == UINT32_MAX) {
            VGLOG_VKB("  Rejected: no queue family with GRAPHICS | COMPUTE");
            continue;
        }

        chosen = dev;
        chosenQueueFamily = queueFamily;
        VGLOG_VKB("  Selected: queue family %u", chosenQueueFamily);
        break;
    }

    if (chosen == VK_NULL_HANDLE) {
        VGLOG_VKB("No suitable Vulkan physical device found");
        vkDestroyInstance(s.instance, nullptr);
        s.instance = VK_NULL_HANDLE;
        return false;
    }

    s.physDev = chosen;
    s.queueFamilyIndex = chosenQueueFamily;

    // --- 5. Create VkDevice ---
    //   - One queue at priority 1.0
    //   - Required device extensions enabled
    //   - samplerYcbcrConversion enabled via pNext feature chain

    float queuePriority = 1.0f;
    VkDeviceQueueCreateInfo queueCI{};
    queueCI.sType            = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO;
    queueCI.queueFamilyIndex = s.queueFamilyIndex;
    queueCI.queueCount       = 1;
    queueCI.pQueuePriorities = &queuePriority;

    // Enable samplerYcbcrConversion through the pNext chain.
    VkPhysicalDeviceSamplerYcbcrConversionFeatures ycbcrFeature{};
    ycbcrFeature.sType                  = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_SAMPLER_YCBCR_CONVERSION_FEATURES;
    ycbcrFeature.pNext                  = nullptr;
    ycbcrFeature.samplerYcbcrConversion = VK_TRUE;

    VkDeviceCreateInfo deviceCI{};
    deviceCI.sType                   = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO;
    deviceCI.pNext                   = &ycbcrFeature;
    deviceCI.queueCreateInfoCount    = 1;
    deviceCI.pQueueCreateInfos       = &queueCI;
    deviceCI.enabledExtensionCount   = kRequiredDeviceExtensionCount;
    deviceCI.ppEnabledExtensionNames = kRequiredDeviceExtensions;

    result = vkCreateDevice(s.physDev, &deviceCI, nullptr, &s.device);
    if (result != VK_SUCCESS) {
        VGLOG_VKB("vkCreateDevice failed: %d", static_cast<int>(result));
        // physDev is not owned (not created); destroy instance only.
        vkDestroyInstance(s.instance, nullptr);
        s.instance         = VK_NULL_HANDLE;
        s.physDev          = VK_NULL_HANDLE;
        s.queueFamilyIndex = UINT32_MAX;
        return false;
    }

    // --- 6. Retrieve the queue ---
    // VkQueue must NOT be destroyed separately (destroyed with the device).
    vkGetDeviceQueue(s.device, s.queueFamilyIndex, /*queueIndex=*/0, &s.queue);

    VGLOG_VKB("VulkanBackend initialized: device=%p queue=%p queueFamily=%u",
              static_cast<void*>(s.device),
              static_cast<void*>(s.queue),
              s.queueFamilyIndex);

    s.initialized = true;
    return true;
}

// ---------------------------------------------------------------------------
// shutdown() - Android - idempotent, reverse-order teardown
// ---------------------------------------------------------------------------

void VulkanBackend::shutdown() {
    if (!impl_) return; // safety: called after move (shouldn't happen, but guard)

    Impl& s = *impl_;

    if (!s.initialized && s.device == VK_NULL_HANDLE && s.instance == VK_NULL_HANDLE) {
        return; // already clean
    }

    if (s.surfaceSwapchain) {
        s.surfaceSwapchain->detach();
    }

    // Reverse-order: device -> instance.
    // VkQueue must NOT be destroyed separately.
    if (s.device != VK_NULL_HANDLE) {
        vkDeviceWaitIdle(s.device);
        vkDestroyDevice(s.device, nullptr);
        s.device = VK_NULL_HANDLE;
    }

    s.queue            = VK_NULL_HANDLE; // owned by device, already gone
    s.physDev          = VK_NULL_HANDLE; // not owned
    s.queueFamilyIndex = UINT32_MAX;

    if (s.instance != VK_NULL_HANDLE) {
        vkDestroyInstance(s.instance, nullptr);
        s.instance = VK_NULL_HANDLE;
    }

    s.initialized = false;

    VGLOG_VKB("VulkanBackend shut down");
}

// ---------------------------------------------------------------------------
// Surface / swapchain lifecycle - Android
// ---------------------------------------------------------------------------

bool VulkanBackend::attachSurface(void* nativeWindow,
                                  uint32_t width,
                                  uint32_t height) {
    if (!impl_) return false;
    Impl& s = *impl_;
    if (!s.initialized ||
        s.instance == VK_NULL_HANDLE ||
        s.physDev == VK_NULL_HANDLE ||
        s.device == VK_NULL_HANDLE ||
        s.queueFamilyIndex == UINT32_MAX) {
        return false;
    }

    if (!s.surfaceSwapchain) {
        s.surfaceSwapchain = std::make_unique<VulkanSurfaceSwapchain>();
    }

    return s.surfaceSwapchain->attach(
        static_cast<void*>(s.instance),
        static_cast<void*>(s.physDev),
        static_cast<void*>(s.device),
        s.queueFamilyIndex,
        nativeWindow,
        width,
        height);
}

bool VulkanBackend::resizeSurface(uint32_t width, uint32_t height) {
    if (!impl_) return false;
    Impl& s = *impl_;
    if (!s.initialized ||
        s.device == VK_NULL_HANDLE ||
        !s.surfaceSwapchain) {
        return false;
    }

    return s.surfaceSwapchain->resize(width, height);
}

void VulkanBackend::detachSurface() {
    if (impl_ && impl_->surfaceSwapchain) {
        impl_->surfaceSwapchain->detach();
    }
}

bool VulkanBackend::hasSurface() const {
    return impl_ && impl_->surfaceSwapchain && impl_->surfaceSwapchain->hasSurface();
}

#endif // __ANDROID__

} // namespace render
} // namespace vanguard
