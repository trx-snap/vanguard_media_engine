// Phase 2Q: Vulkan probe safety gate and diagnostics.
//
// Instance extensions checked via vkEnumerateInstanceExtensionProperties:
//   - VK_KHR_surface       (instance extension per Khronos spec)
//   - VK_KHR_android_surface (instance extension per Khronos spec)
//
// Device extensions checked via vkEnumerateDeviceExtensionProperties:
//   - VK_KHR_swapchain
//   - VK_ANDROID_external_memory_android_hardware_buffer
//   - VK_KHR_external_semaphore_fd
//
// VK_KHR_sampler_ycbcr_conversion is promoted to Vulkan 1.1 core.
// We verify the feature bit via dynamically resolved vkGetPhysicalDeviceFeatures2
// (or KHR fallback) rather than relying on platform symbol availability.
//
// Graphics+compute queue family is verified via vkGetPhysicalDeviceQueueFamilyProperties.
//
// A static driver blacklist schema is present with zero active entries.
// No entries are activated without fleet evidence.
//
// Probe creates a temporary VkInstance with required instance extensions enabled,
// enumerates physical devices, validates each candidate, then destroys the
// instance on every path.
//
// No VkDevice, swapchain, surface, queue, AHardwareBuffer, EGL context, or
// rendering is created.
//
// Full AVP 2022 conformance is NOT claimed. This phase implements a conservative
// avp2022_partial_pass / compatibility safety gate only.

#include "vanguard/platform/android_backend_probe.h"
#include "vanguard/core/logging.h"

#include <vulkan/vulkan.h>
#include <vulkan/vulkan_android.h>
#include <android/log.h>

#include <array>
#include <cstring>
#include <string>
#include <vector>

#define VGLOG(...) __android_log_print(ANDROID_LOG_DEBUG, "VanguardProbe", __VA_ARGS__)

namespace vanguard {
namespace platform {

namespace {

// ---------------------------------------------------------------------------
// Required instance extensions
// ---------------------------------------------------------------------------
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

// ---------------------------------------------------------------------------
// Required device extensions
// ---------------------------------------------------------------------------
static const char* kRequiredDeviceExtensions[] = {
    "VK_KHR_swapchain",
    "VK_ANDROID_external_memory_android_hardware_buffer",
    "VK_KHR_external_semaphore_fd",
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

// ---------------------------------------------------------------------------
// samplerYcbcrConversion check via dynamically resolved vkGetPhysicalDeviceFeatures2
// minSdk 24 safe: we do NOT link directly to the 1.1 symbol; we resolve at
// runtime via vkGetInstanceProcAddr and fall back to the KHR variant.
// ---------------------------------------------------------------------------
bool HasSamplerYcbcrConversion(VkInstance instance, VkPhysicalDevice device) {
    // Try core 1.1 first.
    auto fn2 = reinterpret_cast<PFN_vkGetPhysicalDeviceFeatures2>(
        vkGetInstanceProcAddr(instance, "vkGetPhysicalDeviceFeatures2"));
    // Fall back to KHR if core symbol not available.
    if (!fn2) {
        fn2 = reinterpret_cast<PFN_vkGetPhysicalDeviceFeatures2>(
            vkGetInstanceProcAddr(instance, "vkGetPhysicalDeviceFeatures2KHR"));
    }
    if (!fn2) {
        // Neither symbol available; conservatively fail.
        VGLOG("vkGetPhysicalDeviceFeatures2 / KHR not resolvable; rejecting device");
        return false;
    }

    VkPhysicalDeviceSamplerYcbcrConversionFeatures ycbcrFeatures{};
    ycbcrFeatures.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_SAMPLER_YCBCR_CONVERSION_FEATURES;
    ycbcrFeatures.pNext = nullptr;

    VkPhysicalDeviceFeatures2 features2{};
    features2.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2;
    features2.pNext = &ycbcrFeatures;

    fn2(device, &features2);
    return ycbcrFeatures.samplerYcbcrConversion == VK_TRUE;
}

// ---------------------------------------------------------------------------
// Graphics + compute queue family check
// ---------------------------------------------------------------------------
bool HasGraphicsComputeQueueFamily(VkPhysicalDevice device) {
    uint32_t count = 0;
    vkGetPhysicalDeviceQueueFamilyProperties(device, &count, nullptr);
    if (count == 0) return false;

    std::vector<VkQueueFamilyProperties> families(count);
    vkGetPhysicalDeviceQueueFamilyProperties(device, &count, families.data());

    const VkQueueFlags required = VK_QUEUE_GRAPHICS_BIT | VK_QUEUE_COMPUTE_BIT;
    for (uint32_t i = 0; i < count; ++i) {
        if ((families[i].queueFlags & required) == required) {
            return true;
        }
    }
    return false;
}

// ---------------------------------------------------------------------------
// Static driver blacklist schema.
// Zero active entries by default. Entries are added only with fleet evidence.
// Schema: { vendorId, deviceId (0 = any device), driverVersionMin,
//           driverVersionMax (0 = unbounded), label }
// ---------------------------------------------------------------------------
struct BlacklistEntry {
    uint32_t    vendorId;
    uint32_t    deviceId;         // 0 = match any device from this vendor
    uint32_t    driverVersionMin; // inclusive
    uint32_t    driverVersionMax; // inclusive; 0 = unbounded
    const char* label;
};

static const std::array<BlacklistEntry, 0> kDriverBlacklist = {};
// Zero active entries. Add entries only with fleet evidence.
// Example schema (NOT active):
//   { 0x5143, 0x0000, 0x00000000, 0x00000000, "example_qcom_placeholder" },

// Returns the matching label, or nullptr if not blacklisted.
const char* CheckBlacklist(uint32_t vendorId, uint32_t deviceId, uint32_t driverVersion) {
    for (const BlacklistEntry& e : kDriverBlacklist) {
        if (e.vendorId != vendorId) continue;
        if (e.deviceId != 0 && e.deviceId != deviceId) continue;
        if (driverVersion < e.driverVersionMin) continue;
        if (e.driverVersionMax != 0 && driverVersion > e.driverVersionMax) continue;
        return e.label;
    }
    return nullptr;
}

// ---------------------------------------------------------------------------
// Device telemetry snapshot
// ---------------------------------------------------------------------------
struct DeviceTelemetry {
    uint32_t    vendorId      = 0;
    uint32_t    deviceId      = 0;
    uint32_t    apiVersion    = 0;
    uint32_t    driverVersion = 0;
    std::string deviceName;
    std::string vendorString; // numeric hex string derived from vendorId

    bool populated = false;
};

DeviceTelemetry CaptureDeviceTelemetry(const VkPhysicalDeviceProperties& props) {
    DeviceTelemetry t;
    t.vendorId      = props.vendorID;
    t.deviceId      = props.deviceID;
    t.apiVersion    = props.apiVersion;
    t.driverVersion = props.driverVersion;
    t.deviceName    = std::string(props.deviceName);

    // Derive a human-readable vendor string from known vendorIDs.
    switch (props.vendorID) {
        case 0x1002: t.vendorString = "AMD";    break;
        case 0x1010: t.vendorString = "ImgTec"; break;
        case 0x10DE: t.vendorString = "NVIDIA"; break;
        case 0x13B5: t.vendorString = "ARM";    break;
        case 0x5143: t.vendorString = "Qualcomm"; break;
        case 0x8086: t.vendorString = "Intel";  break;
        default:
            char buf[16];
            std::snprintf(buf, sizeof(buf), "0x%04X", props.vendorID);
            t.vendorString = buf;
            break;
    }
    t.populated = true;
    return t;
}

// ---------------------------------------------------------------------------
// GLES fallback builder
// ---------------------------------------------------------------------------
render::BackendCapability GlesFallback(
        const char*       fallbackReason,
        const char*       profileGateStatus,
        const char*       blacklistStatus,
        const DeviceTelemetry& tel = DeviceTelemetry{}) {
    render::BackendCapability cap;
    cap.selected          = render::RenderBackendType::kGles;
    cap.vulkanSupported   = false;
    cap.glesSupported     = true;
    cap.fallbackReason    = fallbackReason;
    cap.profileGateStatus = profileGateStatus;
    cap.blacklistStatus   = blacklistStatus;
    if (tel.populated) {
        cap.gpuVendor           = tel.vendorString;
        cap.gpuRenderer         = tel.deviceName;
        cap.vendorId            = tel.vendorId;
        cap.deviceId            = tel.deviceId;
        cap.apiVersion          = tel.apiVersion;
        cap.vulkanDriverVersion = tel.driverVersion;
    }
    return cap;
}

} // namespace

// ---------------------------------------------------------------------------
// Main probe entry point
// ---------------------------------------------------------------------------
render::BackendCapability AndroidProbeBackendCapability() {
    VGLOG("Starting Vulkan capability probe (Phase 2Q)");

    // --- 1. Check required instance extensions before creating VkInstance ---
    if (!HasRequiredInstanceExtensions()) {
        VGLOG("Required instance extensions not available; falling back to GLES");
        return GlesFallback(
            "missing_required_instance_extensions",
            "failed_instance_extensions",
            "not_evaluated");
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
        return GlesFallback(
            "vulkan_instance_creation_failed",
            "failed_instance_creation",
            "not_evaluated");
    }

    // Guard: always destroy the instance when this scope exits.
    struct InstanceGuard {
        VkInstance inst;
        ~InstanceGuard() { if (inst != VK_NULL_HANDLE) vkDestroyInstance(inst, nullptr); }
    } guard{instance};

    // --- 3. Enumerate physical devices ---
    uint32_t deviceCount = 0;
    VkResult enumResult = vkEnumeratePhysicalDevices(instance, &deviceCount, nullptr);
    if (enumResult != VK_SUCCESS) {
        VGLOG("vkEnumeratePhysicalDevices count query failed: %d", static_cast<int>(enumResult));
        return GlesFallback(
            "vulkan_device_enumeration_failed",
            "failed_device_enumeration",
            "not_evaluated");
    }
    if (deviceCount == 0) {
        VGLOG("No Vulkan physical devices found");
        return GlesFallback(
            "no_vulkan_physical_devices",
            "failed_no_devices",
            "not_evaluated");
    }
    std::vector<VkPhysicalDevice> devices(deviceCount);
    if (vkEnumeratePhysicalDevices(instance, &deviceCount, devices.data()) != VK_SUCCESS) {
        VGLOG("vkEnumeratePhysicalDevices data query failed");
        return GlesFallback(
            "vulkan_device_enumeration_failed",
            "failed_device_enumeration",
            "not_evaluated");
    }

    // --- 4. Iterate devices; apply all checks; preserve telemetry of best
    //        real GPU encountered even if it is ultimately rejected.        ---
    VkPhysicalDevice chosen = VK_NULL_HANDLE;
    VkPhysicalDeviceProperties chosenProps{};
    DeviceTelemetry chosenTel;

    // Stores the telemetry of the last real (non-CPU) GPU we tested,
    // for preservation when all candidates are rejected.
    DeviceTelemetry bestRejectedTel;

    // Rejection reason strings for the overall loop exit.
    const char* loopFallbackReason    = "vulkan_no_suitable_device";
    const char* loopProfileGateStatus = "unverified";
    // Blacklist status tracks whether the last-inspected real GPU was checked
    // against the blacklist.  "not_evaluated" until a real GPU reaches that check.
    const char* loopBlacklistStatus   = "not_evaluated";

    for (VkPhysicalDevice dev : devices) {
        VkPhysicalDeviceProperties props{};
        vkGetPhysicalDeviceProperties(dev, &props);

        VGLOG("Physical device: %s (type=%d, apiVersion=%u, vendor=0x%X, device=0x%X)",
              props.deviceName,
              static_cast<int>(props.deviceType),
              props.apiVersion,
              props.vendorID,
              props.deviceID);

        // Reject CPU / software renderers (SwiftShader, llvmpipe, etc.)
        if (props.deviceType == VK_PHYSICAL_DEVICE_TYPE_CPU) {
            VGLOG("Rejecting CPU/software renderer: %s", props.deviceName);
            loopFallbackReason    = "cpu_software_renderer_rejected";
            loopProfileGateStatus = "failed_cpu_device";
            continue;
        }

        // Capture telemetry for any real GPU we inspect.
        DeviceTelemetry tel = CaptureDeviceTelemetry(props);
        bestRejectedTel = tel; // update best-rejected on every real GPU

        // Require Vulkan API >= 1.1 (also ensures samplerYcbcrConversion is core).
        if (VK_VERSION_MAJOR(props.apiVersion) < 1 ||
            (VK_VERSION_MAJOR(props.apiVersion) == 1 &&
             VK_VERSION_MINOR(props.apiVersion) < 1)) {
            VGLOG("Device %s: Vulkan API < 1.1, skipping", props.deviceName);
            loopFallbackReason    = "vulkan_api_version_unsupported";
            loopProfileGateStatus = "failed_api_version";
            continue;
        }

        // Check required device extensions.
        if (!HasRequiredDeviceExtensions(dev)) {
            VGLOG("Device %s: missing required device extensions", props.deviceName);
            loopFallbackReason    = "missing_required_device_extensions";
            loopProfileGateStatus = "failed_device_extensions";
            continue;
        }

        // Check samplerYcbcrConversion feature via dynamic proc resolution.
        if (!HasSamplerYcbcrConversion(instance, dev)) {
            VGLOG("Device %s: samplerYcbcrConversion feature not available", props.deviceName);
            loopFallbackReason    = "missing_sampler_ycbcr_feature";
            loopProfileGateStatus = "failed_ycbcr_feature";
            continue;
        }

        // Check graphics + compute queue family.
        if (!HasGraphicsComputeQueueFamily(dev)) {
            VGLOG("Device %s: no queue family with both GRAPHICS and COMPUTE bits", props.deviceName);
            loopFallbackReason    = "missing_graphics_compute_queue_family";
            loopProfileGateStatus = "failed_queue_family";
            continue;
        }

        // Check driver blacklist.
        const char* blacklistLabel = CheckBlacklist(props.vendorID, props.deviceID, props.driverVersion);
        if (blacklistLabel != nullptr) {
            VGLOG("Device %s: blacklisted (%s)", props.deviceName, blacklistLabel);
            loopFallbackReason    = "blacklisted_gpu_driver";
            loopProfileGateStatus = "failed_blacklisted";
            loopBlacklistStatus   = "blacklisted_match";
            continue;
        }
        // Device cleared the blacklist; record that it was checked and not matched.
        loopBlacklistStatus = "not_blacklisted";

        // All checks passed – this device is suitable.
        chosen      = dev;
        chosenProps = props;
        chosenTel   = tel;
        break;
    }

    // --- 5. Return result ---
    if (chosen == VK_NULL_HANDLE) {
        VGLOG("No suitable Vulkan device found; falling back to GLES (%s)", loopFallbackReason);
        // Preserve telemetry from the best/last real GPU we examined.
        return GlesFallback(loopFallbackReason, loopProfileGateStatus, loopBlacklistStatus,
                            bestRejectedTel);
    }

    VGLOG("Vulkan probe passed (avp2022_partial_pass): device=%s apiVersion=%u vendor=0x%X device=0x%X driver=%u",
          chosenProps.deviceName,
          chosenProps.apiVersion,
          chosenProps.vendorID,
          chosenProps.deviceID,
          chosenProps.driverVersion);

    // NOTE: We report avp2022_partial_pass – conservative safety gate only.
    // Full AVP 2022 conformance is NOT claimed (no official Vulkan Profiles
    // library validation was performed).
    render::BackendCapability cap;
    cap.selected          = render::RenderBackendType::kVulkan;
    cap.vulkanSupported   = true;
    cap.glesSupported     = true;
    cap.fallbackReason    = "none";
    cap.profileGateStatus = "avp2022_partial_pass";
    cap.blacklistStatus   = "not_blacklisted";
    cap.gpuVendor           = chosenTel.vendorString;
    cap.gpuRenderer         = chosenTel.deviceName;
    cap.vendorId            = chosenTel.vendorId;
    cap.deviceId            = chosenTel.deviceId;
    cap.apiVersion          = chosenTel.apiVersion;
    cap.vulkanDriverVersion = chosenTel.driverVersion;
    return cap;
}

} // namespace platform
} // namespace vanguard
