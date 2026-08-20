// Phase 2A: Real Android Vulkan capability probe.
//
// Instance extensions checked via vkEnumerateInstanceExtensionProperties:
//   - VK_KHR_surface       (instance extension per Khronos spec)
//   - VK_KHR_android_surface (instance extension per Khronos spec)
//
// Device extensions checked via vkEnumerateDeviceExtensionProperties:
//   - VK_KHR_swapchain
//   - VK_ANDROID_external_memory_android_hardware_buffer
//
// VK_KHR_sampler_ycbcr_conversion is NOT checked as a device extension string
// because it is promoted to Vulkan 1.1 core. The API >= 1.1 check is sufficient
// for Phase 2A. Full AVP 2022 profile validation is deferred to Phase 2B.
//
// Probe creates a temporary VkInstance with required instance extensions enabled,
// enumerates physical devices, validates device type and API version, checks
// device extension availability, then destroys the instance on every path.
//
// No VkDevice, swapchain, surface, queue, AHardwareBuffer, EGL context, or
// rendering is created.

#include "vanguard/platform/android_backend_probe.h"
#include "vanguard/core/logging.h"

#include <vulkan/vulkan.h>
#include <android/log.h>

#include <cstring>
#include <vector>

#define VGLOG(...) __android_log_print(ANDROID_LOG_DEBUG, "VanguardProbe", __VA_ARGS__)

namespace vanguard {
namespace platform {

namespace {

// --- Instance extension check ---
// VK_KHR_surface and VK_KHR_android_surface are instance extensions.
// Must be queried with vkEnumerateInstanceExtensionProperties.

static const char* kRequiredInstanceExtensions[] = {
    "VK_KHR_surface",
    "VK_KHR_android_surface",
};
static const int kRequiredInstanceExtensionCount =
    static_cast<int>(sizeof(kRequiredInstanceExtensions) / sizeof(kRequiredInstanceExtensions[0]));

bool HasRequiredInstanceExtensions() {
    uint32_t count = 0;
    if (vkEnumerateInstanceExtensionProperties(nullptr, &count, nullptr) != VK_SUCCESS) {
        VGLOG("vkEnumerateInstanceExtensionProperties count query failed");
        return false;
    }
    std::vector<VkExtensionProperties> available(count);
    if (vkEnumerateInstanceExtensionProperties(nullptr, &count, available.data()) != VK_SUCCESS) {
        VGLOG("vkEnumerateInstanceExtensionProperties data query failed");
        return false;
    }
    for (int req = 0; req < kRequiredInstanceExtensionCount; ++req) {
        bool found = false;
        for (uint32_t i = 0; i < count; ++i) {
            if (std::strcmp(available[i].extensionName, kRequiredInstanceExtensions[req]) == 0) {
                found = true;
                break;
            }
        }
        if (!found) {
            VGLOG("Missing required instance extension: %s", kRequiredInstanceExtensions[req]);
            return false;
        }
    }
    return true;
}

// --- Device extension check ---
// VK_KHR_swapchain and VK_ANDROID_external_memory_android_hardware_buffer
// are device extensions. Must be queried with vkEnumerateDeviceExtensionProperties.
// VK_KHR_sampler_ycbcr_conversion is core in Vulkan 1.1 — not checked here.

static const char* kRequiredDeviceExtensions[] = {
    "VK_KHR_swapchain",
    "VK_ANDROID_external_memory_android_hardware_buffer",
};
static const int kRequiredDeviceExtensionCount =
    static_cast<int>(sizeof(kRequiredDeviceExtensions) / sizeof(kRequiredDeviceExtensions[0]));

bool HasRequiredDeviceExtensions(VkPhysicalDevice device) {
    uint32_t count = 0;
    if (vkEnumerateDeviceExtensionProperties(device, nullptr, &count, nullptr) != VK_SUCCESS) {
        VGLOG("vkEnumerateDeviceExtensionProperties count query failed");
        return false;
    }
    std::vector<VkExtensionProperties> available(count);
    if (vkEnumerateDeviceExtensionProperties(device, nullptr, &count, available.data()) != VK_SUCCESS) {
        VGLOG("vkEnumerateDeviceExtensionProperties data query failed");
        return false;
    }
    for (int req = 0; req < kRequiredDeviceExtensionCount; ++req) {
        bool found = false;
        for (uint32_t i = 0; i < count; ++i) {
            if (std::strcmp(available[i].extensionName, kRequiredDeviceExtensions[req]) == 0) {
                found = true;
                break;
            }
        }
        if (!found) {
            VGLOG("Missing required device extension: %s", kRequiredDeviceExtensions[req]);
            return false;
        }
    }
    return true;
}

// Returns a GLES fallback capability with an explicit reason.
render::BackendCapability GlesFallback(const char* reason,
                                       const std::string& gpuVendor = "",
                                       const std::string& gpuRenderer = "") {
    render::BackendCapability cap;
    cap.selected            = render::RenderBackendType::kGles;
    cap.vulkanSupported     = false;
    cap.glesSupported       = true;
    cap.fallbackReason      = reason;
    cap.gpuVendor           = gpuVendor;
    cap.gpuRenderer         = gpuRenderer;
    cap.vulkanDriverVersion = 0;
    return cap;
}

} // namespace

render::BackendCapability AndroidProbeBackendCapability() {
    VGLOG("Starting Vulkan capability probe (Phase 2A)");

    // --- 1. Check required instance extensions before creating VkInstance ---
    if (!HasRequiredInstanceExtensions()) {
        VGLOG("Required instance extensions not available; falling back to GLES");
        return GlesFallback("missing_required_instance_extensions");
    }

    // --- 2. Create a VkInstance with required instance extensions enabled ---
    VkApplicationInfo appInfo{};
    appInfo.sType            = VK_STRUCTURE_TYPE_APPLICATION_INFO;
    appInfo.pApplicationName = "VanguardProbe";
    appInfo.apiVersion       = VK_API_VERSION_1_1;

    VkInstanceCreateInfo instanceInfo{};
    instanceInfo.sType                   = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO;
    instanceInfo.pApplicationInfo        = &appInfo;
    instanceInfo.enabledExtensionCount   = static_cast<uint32_t>(kRequiredInstanceExtensionCount);
    instanceInfo.ppEnabledExtensionNames = kRequiredInstanceExtensions;

    VkInstance instance = VK_NULL_HANDLE;
    VkResult result = vkCreateInstance(&instanceInfo, nullptr, &instance);
    if (result != VK_SUCCESS) {
        VGLOG("vkCreateInstance failed: %d", static_cast<int>(result));
        return GlesFallback("vulkan_instance_creation_failed");
    }

    // Guard: always destroy the instance when this scope exits.
    struct InstanceGuard {
        VkInstance inst;
        ~InstanceGuard() { if (inst != VK_NULL_HANDLE) vkDestroyInstance(inst, nullptr); }
    } guard{instance};

    // --- 3. Enumerate physical devices ---
    uint32_t deviceCount = 0;
    if (vkEnumeratePhysicalDevices(instance, &deviceCount, nullptr) != VK_SUCCESS || deviceCount == 0) {
        VGLOG("No Vulkan physical devices found");
        return GlesFallback("no_vulkan_physical_devices");
    }
    std::vector<VkPhysicalDevice> devices(deviceCount);
    if (vkEnumeratePhysicalDevices(instance, &deviceCount, devices.data()) != VK_SUCCESS) {
        VGLOG("vkEnumeratePhysicalDevices data query failed");
        return GlesFallback("vulkan_device_enumeration_failed");
    }

    // --- 4. Find the first suitable GPU device ---
    VkPhysicalDevice chosen = VK_NULL_HANDLE;
    VkPhysicalDeviceProperties chosenProps{};
    std::string chosenVendor;
    std::string chosenRenderer;

    for (VkPhysicalDevice dev : devices) {
        VkPhysicalDeviceProperties props{};
        vkGetPhysicalDeviceProperties(dev, &props);

        VGLOG("Physical device: %s (type=%d, apiVersion=%u)",
              props.deviceName,
              static_cast<int>(props.deviceType),
              props.apiVersion);

        // Reject CPU / software renderers (SwiftShader, llvmpipe, etc.)
        if (props.deviceType == VK_PHYSICAL_DEVICE_TYPE_CPU) {
            VGLOG("Rejecting CPU/software renderer: %s", props.deviceName);
            continue;
        }

        // Require Vulkan API >= 1.1.
        // Also satisfies VK_KHR_sampler_ycbcr_conversion which is core in 1.1.
        if (VK_VERSION_MAJOR(props.apiVersion) < 1 ||
            (VK_VERSION_MAJOR(props.apiVersion) == 1 && VK_VERSION_MINOR(props.apiVersion) < 1)) {
            VGLOG("Device %s: Vulkan API < 1.1, skipping", props.deviceName);
            continue;
        }

        // Check required device extensions.
        if (!HasRequiredDeviceExtensions(dev)) {
            VGLOG("Device %s: missing required device extensions", props.deviceName);
            continue;
        }

        chosen         = dev;
        chosenProps    = props;
        chosenVendor   = std::to_string(props.vendorID);
        chosenRenderer = std::string(props.deviceName);
        break;
    }

    // --- 5. Return result ---
    if (chosen == VK_NULL_HANDLE) {
        VGLOG("No suitable Vulkan device found; falling back to GLES");
        // Full AVP 2022 profile validation deferred to Phase 2B.
        return GlesFallback("vulkan_no_suitable_device_avp2022_profile_validation_pending");
    }

    VGLOG("Vulkan probe passed: device=%s apiVersion=%u",
          chosenProps.deviceName, chosenProps.apiVersion);

    // NOTE: Full AVP 2022 profile validation is deferred to Phase 2B.
    // Phase 2A validates: required instance extensions present and enabled,
    // Vulkan 1.1+, non-CPU device type, required device extensions available.
    render::BackendCapability cap;
    cap.selected            = render::RenderBackendType::kVulkan;
    cap.vulkanSupported     = true;
    cap.glesSupported       = true;
    cap.fallbackReason      = "none";
    cap.gpuVendor           = chosenVendor;
    cap.gpuRenderer         = chosenRenderer;
    cap.vulkanDriverVersion = chosenProps.driverVersion;
    return cap;
}

} // namespace platform
} // namespace vanguard
