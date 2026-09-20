// Phase 2O2B1: VulkanBackend implementation.
//
// On Android (__ANDROID__):
//   - Vulkan headers included here, never in the public header.
//   - Phase 2B1: instance extension check, VkInstance (API 1.1),
//     physical device selection, queue family, VkDevice, vkGetDeviceQueue.
//   - Phase 2B2: delegates surface/swapchain lifecycle to VulkanSurfaceSwapchain.
//   - Phase 2C: delegates AHardwareBuffer import to VulkanHardwareBufferImports.
//   - Phase 2O2B1: modular frame renderer helper (VulkanFrameRenderer).
//   - Phase 2O2B1: frame runtime state scaffolding and renderFrame validation.
//
// On non-Android host builds:
//   - No Vulkan headers included.
//   - initialize() returns false; shutdown() is a no-op.
//   - Surface methods return false / no-op.
//   - AHardwareBuffer methods return kUnavailable / false.
//   - renderFrame returns kUnavailable.

#include "vanguard/render/vulkan_backend.h"
#include "vulkan_surface_swapchain.h"
#include "vulkan_hardware_buffer_imports.h"
#include "vulkan_shader_module.h"
#include "vulkan_frame_renderer.h"
#include "vulkan_overlay_texture_store.h"

#if defined(__ANDROID__)

#include <vulkan/vulkan.h>
#include <android/log.h>

#include <cstring>
#include <unistd.h>
#include <vector>

#define VGLOG_VKB(...) __android_log_print(ANDROID_LOG_DEBUG, "VanguardVkBackend", __VA_ARGS__)

#elif !defined(_WIN32)

#include <unistd.h>

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
    VkCommandPool    commandPool = VK_NULL_HANDLE; // Phase 2F

    // Phase 2J: AOT-embedded core shader modules.
    std::unique_ptr<VulkanCoreShaderModules> coreShaders;

    // P5-OVERLAYS-TRANS / P5-OVERLAYS-PRODUCTION-EXPORT-ROUTE-A backend seam
    // sub-slice N4: backend-owned Vulkan overlay texture store for static
    // sticker RGBA pixels. Lazily instantiated/initialized on first
    // createOverlayTextureRgba8888() call.
    std::unique_ptr<VulkanOverlayTextureStore> overlayTextureStore;
#endif

    // Phase 2O2B1: modular frame renderer helper.
    std::unique_ptr<VulkanFrameRenderer> frameRenderer;

    // Phase 2B2: surface/swapchain lifecycle helper.
    std::unique_ptr<VulkanSurfaceSwapchain> surfaceSwapchain;

    // Phase 2C: AHardwareBuffer import helper.
    std::unique_ptr<VulkanHardwareBufferImports> ahbImports;

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

// Phase 2C: AHardwareBuffer import stubs - not supported on host builds.

HardwareBufferImportResult VulkanBackend::importHardwareBuffer(
    void* /*hardwareBuffer*/,
    int acquireFenceFd,
    HardwareBufferHandle* outHandle,
    HardwareBufferDescriptor* outDescriptor)
{
    // Ownership of acquireFenceFd transfers at call entry; close it if valid.
#if !defined(_WIN32)
    if (acquireFenceFd >= 0) ::close(acquireFenceFd);
#else
    (void)acquireFenceFd;
#endif
    if (outHandle)     *outHandle     = kInvalidHardwareBufferHandle;
    if (outDescriptor) *outDescriptor = HardwareBufferDescriptor{};
    return HardwareBufferImportResult::kUnavailable;
}

HardwareBufferImportResult VulkanBackend::releaseHardwareBuffer(
    HardwareBufferHandle /*handle*/,
    int* outReleaseFenceFd)
{
    if (outReleaseFenceFd) *outReleaseFenceFd = -1;
    return HardwareBufferImportResult::kUnavailable;
}

bool VulkanBackend::hasHardwareBuffer(HardwareBufferHandle /*handle*/) const {
    return false;
}

// ---------------------------------------------------------------------------
// Phase 2O2B1: renderFrame stub - host build.
// Phase 2O2B2 will wire acquire-semaphore wait + command recording + queue
// submit + swapchain present. Do NOT add any of those here.
// ---------------------------------------------------------------------------

RenderFrameResult VulkanBackend::renderFrame(HardwareBufferHandle /*handle*/) {
    return RenderFrameResult::kUnavailable;
}

// ---------------------------------------------------------------------------
// Phase 4B2C: renderFrame with transform stub - host build.
// ---------------------------------------------------------------------------

RenderFrameResult VulkanBackend::renderFrame(HardwareBufferHandle /*handle*/,
                                             const VideoFrameTransform& /*transform*/) {
    return RenderFrameResult::kUnavailable;
}

// ---------------------------------------------------------------------------
// P5-OVERLAYS-TRANS / P5-OVERLAYS-PRODUCTION-EXPORT-ROUTE-A backend seam
// sub-slice N3: renderFrame with overlay draws stub - host build.
// ---------------------------------------------------------------------------

RenderFrameResult VulkanBackend::renderFrame(HardwareBufferHandle /*handle*/,
                                             const VideoFrameTransform& /*transform*/,
                                             const VulkanOverlayFrameDraw* /*overlayDraws*/,
                                             uint32_t /*overlayCount*/) {
    return RenderFrameResult::kUnavailable;
}

// ---------------------------------------------------------------------------
// P5-BEAUTY-V2-PRODUCTION-EXPORT-ROUTE-A: renderFrame with beauty stub - host build.
// ---------------------------------------------------------------------------

RenderFrameResult VulkanBackend::renderFrame(HardwareBufferHandle /*handle*/,
                                             const VideoFrameTransform& /*transform*/,
                                             const VideoBeautyV2RenderParams& /*beauty*/) {
    return RenderFrameResult::kUnavailable;
}

// ---------------------------------------------------------------------------
// P5-OVERLAYS-BEAUTY-SOLO: renderFrame with beauty + overlay draws stub -
// host build.
// ---------------------------------------------------------------------------

RenderFrameResult VulkanBackend::renderFrame(HardwareBufferHandle /*handle*/,
                                             const VideoFrameTransform& /*transform*/,
                                             const VideoBeautyV2RenderParams& /*beauty*/,
                                             const VulkanOverlayFrameDraw* /*overlayDraws*/,
                                             uint32_t /*overlayCount*/) {
    return RenderFrameResult::kUnavailable;
}

// ---------------------------------------------------------------------------
// P5-COMPOSITOR-TRANS: renderTransitionFrame stub - host build.
// ---------------------------------------------------------------------------

RenderFrameResult VulkanBackend::renderTransitionFrame(
    HardwareBufferHandle /*fromHandle*/,
    HardwareBufferHandle /*toHandle*/,
    const VideoTransitionFrameTransform& /*transition*/,
    const VideoBeautyV2RenderParams& /*fromBeauty*/,
    const VideoBeautyV2RenderParams& /*toBeauty*/) {
    return RenderFrameResult::kUnavailable;
}

// ---------------------------------------------------------------------------
// P5-OVERLAYS-TRANSITION-COMP-N1: renderTransitionFrame with overlay draws
// stub - host build. Native-only: no JNI/Kotlin route calls this yet.
// ---------------------------------------------------------------------------

RenderFrameResult VulkanBackend::renderTransitionFrame(
    HardwareBufferHandle /*fromHandle*/,
    HardwareBufferHandle /*toHandle*/,
    const VideoTransitionFrameTransform& /*transition*/,
    const VulkanOverlayFrameDraw* /*overlayDraws*/,
    uint32_t /*overlayCount*/,
    const VideoBeautyV2RenderParams& /*fromBeauty*/,
    const VideoBeautyV2RenderParams& /*toBeauty*/) {
    return RenderFrameResult::kUnavailable;
}

RenderFrameResult VulkanBackend::renderDuetGreenScreenFrame(
    HardwareBufferHandle /*sourceHandle*/,
    HardwareBufferHandle /*cameraHandle*/,
    const RenderDestinationRect& /*sourceRect*/,
    const RenderDestinationRect& /*cameraRect*/,
    uint32_t /*sourceBufferWidth*/,
    uint32_t /*sourceBufferHeight*/,
    uint32_t /*cameraBufferWidth*/,
    uint32_t /*cameraBufferHeight*/,
    VulkanOverlayTextureHandle /*cpuMaskHandle*/,
    HardwareBufferHandle /*gpuMaskHandle*/,
    uint32_t /*gpuMaskWidth*/,
    uint32_t /*gpuMaskHeight*/,
    uint32_t /*sourceRotationDegrees*/,
    bool /*sourceMirrorHorizontal*/,
    uint32_t /*cameraRotationDegrees*/,
    bool /*cameraMirrorHorizontal*/,
    int32_t /*debugMode*/) {
    return RenderFrameResult::kUnavailable;
}

// ---------------------------------------------------------------------------
// ANDROID-DUET-VULKAN-GREENSCREEN-STATIC-BACKGROUND:
// renderDuetGreenScreenStaticBackgroundFrame stub - host build.
// ---------------------------------------------------------------------------

RenderFrameResult VulkanBackend::renderDuetGreenScreenStaticBackgroundFrame(
    HardwareBufferHandle /*cameraHandle*/,
    const RenderDestinationRect& /*cameraRect*/,
    uint32_t /*cameraBufferWidth*/,
    uint32_t /*cameraBufferHeight*/,
    VulkanOverlayTextureHandle /*cpuMaskHandle*/,
    HardwareBufferHandle /*gpuMaskHandle*/,
    uint32_t /*gpuMaskWidth*/,
    uint32_t /*gpuMaskHeight*/,
    uint32_t /*cameraRotationDegrees*/,
    bool /*cameraMirrorHorizontal*/,
    int32_t /*debugMode*/,
    DuetGreenScreenStaticBackgroundMode /*backgroundMode*/) {
    return RenderFrameResult::kUnavailable;
}

// ---------------------------------------------------------------------------
// ANDROID-DUET-VULKAN-LAYOUT: renderDuetLayoutFrame stub - host build.
// ---------------------------------------------------------------------------

RenderFrameResult VulkanBackend::renderDuetLayoutFrame(
    HardwareBufferHandle /*sourceHandle*/,
    HardwareBufferHandle /*cameraHandle*/,
    const RenderDestinationRect& /*sourceRect*/,
    const RenderDestinationRect& /*cameraRect*/,
    uint32_t /*sourceBufferWidth*/,
    uint32_t /*sourceBufferHeight*/,
    uint32_t /*cameraBufferWidth*/,
    uint32_t /*cameraBufferHeight*/,
    uint32_t /*sourceRotationDegrees*/,
    bool /*sourceMirrorHorizontal*/,
    uint32_t /*cameraRotationDegrees*/,
    bool /*cameraMirrorHorizontal*/,
    float /*cameraCornerRadiusPx*/) {
    return RenderFrameResult::kUnavailable;
}

// ---------------------------------------------------------------------------
// P5-OVERLAYS-TRANS / P5-OVERLAYS-PRODUCTION-EXPORT-ROUTE-A backend seam
// sub-slice N4: overlay texture store stubs - host build.
// ---------------------------------------------------------------------------

bool VulkanBackend::createOverlayTextureRgba8888(const uint8_t* /*rgba*/,
                                                 size_t /*rgbaByteCount*/,
                                                 uint32_t /*width*/,
                                                 uint32_t /*height*/,
                                                 uint32_t /*rowStrideBytes*/,
                                                 VulkanOverlayTextureHandle* outHandle,
                                                 VulkanOverlayTextureInfo* outInfo) {
    if (outHandle) *outHandle = kInvalidOverlayTextureHandle;
    if (outInfo) *outInfo = VulkanOverlayTextureInfo{};
    return false;
}

bool VulkanBackend::createOverlayTextureR8(const uint8_t* /*r8*/,
                                           size_t /*r8ByteCount*/,
                                           uint32_t /*width*/,
                                           uint32_t /*height*/,
                                           uint32_t /*rowStrideBytes*/,
                                           VulkanOverlayTextureHandle* outHandle,
                                           VulkanOverlayTextureInfo* outInfo) {
    if (outHandle) *outHandle = kInvalidOverlayTextureHandle;
    if (outInfo) *outInfo = VulkanOverlayTextureInfo{};
    return false;
}

bool VulkanBackend::updateOverlayTextureR8(VulkanOverlayTextureHandle /*handle*/,
                                           const uint8_t* /*r8*/,
                                           size_t /*r8ByteCount*/,
                                           uint32_t /*width*/,
                                           uint32_t /*height*/,
                                           uint32_t /*rowStrideBytes*/) {
    return false;
}

bool VulkanBackend::releaseOverlayTexture(VulkanOverlayTextureHandle /*handle*/) {
    return false;
}

bool VulkanBackend::getOverlayTextureInfo(VulkanOverlayTextureHandle /*handle*/,
                                          VulkanOverlayTextureInfo* outInfo) const {
    if (outInfo) *outInfo = VulkanOverlayTextureInfo{};
    return false;
}

void VulkanBackend::clearOverlayTextures() {
    // no-op on host builds
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
// Phase 2G: VK_KHR_external_semaphore_fd added to enable sync-fd acquire-fence
// semaphore import (vkImportSemaphoreFdKHR) for DAG queue submit ordering.
// Phase 2P1: VK_KHR_external_semaphore_fd also supports release-semaphore export
// via vkGetSemaphoreFdKHR.
static const char* kRequiredDeviceExtensions[] = {
    "VK_KHR_swapchain",
    "VK_ANDROID_external_memory_android_hardware_buffer",
    "VK_KHR_external_semaphore_fd",
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
// pNext chain. Requires Vulkan 1.1 (feature query via pNext is core 1.1).
// Dynamically resolves vkGetPhysicalDeviceFeatures2 to maintain minSdk 24 compatibility.
bool CheckYcbcrConversionFeature(VkInstance instance, VkPhysicalDevice physDev) {
    if (instance == VK_NULL_HANDLE || physDev == VK_NULL_HANDLE) {
        return false;
    }

    auto pfnGetPhysicalDeviceFeatures2 = reinterpret_cast<PFN_vkGetPhysicalDeviceFeatures2>(
        vkGetInstanceProcAddr(instance, "vkGetPhysicalDeviceFeatures2"));
    if (!pfnGetPhysicalDeviceFeatures2) {
        pfnGetPhysicalDeviceFeatures2 = reinterpret_cast<PFN_vkGetPhysicalDeviceFeatures2>(
            vkGetInstanceProcAddr(instance, "vkGetPhysicalDeviceFeatures2KHR"));
    }
    if (!pfnGetPhysicalDeviceFeatures2) {
        VGLOG_VKB("vkGetPhysicalDeviceFeatures2 symbol not found via vkGetInstanceProcAddr");
        return false;
    }

    VkPhysicalDeviceSamplerYcbcrConversionFeatures ycbcr{};
    ycbcr.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_SAMPLER_YCBCR_CONVERSION_FEATURES;
    ycbcr.pNext = nullptr;

    VkPhysicalDeviceFeatures2 features2{};
    features2.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2;
    features2.pNext = &ycbcr;

    pfnGetPhysicalDeviceFeatures2(physDev, &features2);

    if (ycbcr.samplerYcbcrConversion != VK_TRUE) {
        VGLOG_VKB("samplerYcbcrConversion not supported on physical device");
        return false;
    }
    return true;
}

// Returns the index of the first queue family supporting both GRAPHICS and
// COMPUTE bits, or UINT32_MAX if none qualifies. Transfer is implicit for
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

// Portable helper: convert any Vulkan non-dispatchable handle to uint64_t
// without truncation or undefined behaviour.
// Safe on 32-bit (uint64_t handle) and 64-bit (pointer handle) Android ABIs.
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
        if (!CheckYcbcrConversionFeature(s.instance, dev)) {
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
        vkDestroyInstance(s.instance, nullptr);
        s.instance         = VK_NULL_HANDLE;
        s.physDev          = VK_NULL_HANDLE;
        s.queueFamilyIndex = UINT32_MAX;
        return false;
    }

    // --- 6. Retrieve the queue ---
    vkGetDeviceQueue(s.device, s.queueFamilyIndex, /*queueIndex=*/0, &s.queue);

    VGLOG_VKB("VulkanBackend initialized: device=%p queue=%p queueFamily=%u",
              static_cast<void*>(s.device), static_cast<void*>(s.queue), s.queueFamilyIndex);

    // --- 7. Create persistent command pool (Phase 2F) ---
    VkCommandPoolCreateInfo poolCI{};
    poolCI.sType            = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO;
    poolCI.flags            = VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT;
    poolCI.queueFamilyIndex = s.queueFamilyIndex;

    result = vkCreateCommandPool(s.device, &poolCI, nullptr, &s.commandPool);
    if (result != VK_SUCCESS) {
        VGLOG_VKB("vkCreateCommandPool failed: %d", static_cast<int>(result));
        vkDestroyDevice(s.device, nullptr);
        s.device = VK_NULL_HANDLE;
        s.queue = VK_NULL_HANDLE;
        vkDestroyInstance(s.instance, nullptr);
        s.instance = VK_NULL_HANDLE;
        s.physDev = VK_NULL_HANDLE;
        s.queueFamilyIndex = UINT32_MAX;
        return false;
    }

    // --- 8. Initialize Phase 2C AHardwareBuffer import helper ---
    s.ahbImports = std::make_unique<VulkanHardwareBufferImports>();
    if (!s.ahbImports->initialize(static_cast<void*>(s.device), static_cast<void*>(s.physDev))) {
        VGLOG_VKB("VulkanHardwareBufferImports initialization failed; importHardwareBuffer will return kUnavailable");
        s.ahbImports.reset();
    }

    // --- 9. Initialize Phase 2J AOT core shader modules ---
    s.coreShaders = std::make_unique<VulkanCoreShaderModules>();
    if (!s.coreShaders->initialize(s.device)) {
        VGLOG_VKB("VulkanCoreShaderModules initialization failed; aborting backend init");
        s.coreShaders.reset();
        if (s.ahbImports) {
            s.ahbImports->shutdown();
            s.ahbImports.reset();
        }
        vkDestroyCommandPool(s.device, s.commandPool, nullptr);
        s.commandPool = VK_NULL_HANDLE;
        vkDestroyDevice(s.device, nullptr);
        s.device = VK_NULL_HANDLE;
        s.queue = VK_NULL_HANDLE;
        vkDestroyInstance(s.instance, nullptr);
        s.instance = VK_NULL_HANDLE;
        s.physDev = VK_NULL_HANDLE;
        s.queueFamilyIndex = UINT32_MAX;
        return false;
    }

    // --- 10. Initialize Phase 2O2B1 modular frame renderer helper ---
    s.frameRenderer = std::make_unique<VulkanFrameRenderer>();
    const uint64_t cmdPoolHandle = vkHandleToU64(s.commandPool);

    if (!s.frameRenderer->initialize(static_cast<void*>(s.device),
                                     cmdPoolHandle,
                                     VulkanFrameRenderer::kDefaultFramesInFlight)) {
        VGLOG_VKB("VulkanFrameRenderer initialization failed; aborting backend init");
        s.frameRenderer.reset();
        if (s.coreShaders) {
            s.coreShaders->shutdown(s.device);
            s.coreShaders.reset();
        }
        if (s.ahbImports) {
            s.ahbImports->shutdown();
            s.ahbImports.reset();
        }
        vkDestroyCommandPool(s.device, s.commandPool, nullptr);
        s.commandPool = VK_NULL_HANDLE;
        vkDestroyDevice(s.device, nullptr);
        s.device = VK_NULL_HANDLE;
        s.queue = VK_NULL_HANDLE;
        vkDestroyInstance(s.instance, nullptr);
        s.instance = VK_NULL_HANDLE;
        s.physDev = VK_NULL_HANDLE;
        s.queueFamilyIndex = UINT32_MAX;
        return false;
    }

    s.initialized = true;
    return true;
}

// ---------------------------------------------------------------------------
// shutdown() - Android - idempotent, reverse-order teardown
// ---------------------------------------------------------------------------

void VulkanBackend::shutdown() {
    if (!impl_) return;

    Impl& s = *impl_;

    if (!s.initialized && s.device == VK_NULL_HANDLE && s.instance == VK_NULL_HANDLE) {
        return; // already clean
    }

    // Wait for device idle before tearing down any GPU resources.
    if (s.device != VK_NULL_HANDLE) {
        vkDeviceWaitIdle(s.device);
    }

    // Phase 2O2B1: Invalidate and destroy pipeline if present via frameRenderer.
    if (s.frameRenderer) {
        s.frameRenderer->invalidatePipeline();
    }

    if (s.surfaceSwapchain) {
        s.surfaceSwapchain->detach();
    }

    // Phase 2C: Release all AHardwareBuffer imports before destroying device.
    // Phase 2P2: drainAllRetired() first so retired Vulkan objects are freed
    // while the device is still alive; shutdown() then destroys active records.
    if (s.ahbImports) {
        s.ahbImports->drainAllRetired();
        s.ahbImports->shutdown();
        s.ahbImports.reset();
    }

    // Phase 2O2B1: Shutdown and destroy frame renderer resources before command pool / device.
    if (s.frameRenderer) {
        s.frameRenderer->shutdown();
        s.frameRenderer.reset();
    }

    // P5-OVERLAYS-TRANS / P5-OVERLAYS-PRODUCTION-EXPORT-ROUTE-A backend seam
    // sub-slice N4: destroy overlay texture store resources (images, views,
    // shared sampler, transient command pool) before command pool / device.
    if (s.overlayTextureStore) {
        s.overlayTextureStore->clear();
        s.overlayTextureStore.reset();
    }

    // Phase 2J: Destroy AOT core shader modules before command pool/device.
    if (s.coreShaders) {
        s.coreShaders->shutdown(s.device);
        s.coreShaders.reset();
    }

    // Phase 2F: Destroy persistent command pool before vkDestroyDevice.
    if (s.commandPool != VK_NULL_HANDLE && s.device != VK_NULL_HANDLE) {
        vkDestroyCommandPool(s.device, s.commandPool, nullptr);
        s.commandPool = VK_NULL_HANDLE;
    }

    // Reverse-order: device -> instance. VkQueue is destroyed with device.
    if (s.device != VK_NULL_HANDLE) {
        vkDestroyDevice(s.device, nullptr);
        s.device = VK_NULL_HANDLE;
    }

    s.queue            = VK_NULL_HANDLE;
    s.physDev          = VK_NULL_HANDLE;
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
    if (!s.initialized || s.device == VK_NULL_HANDLE || !s.surfaceSwapchain) {
        return false;
    }

    // Phase 2P2: Resize is a lifecycle path that is allowed to block.
    // Wait for GPU idle and drain retired imports before invalidating the
    // pipeline or letting the swapchain resize tear down framebuffers/render
    // passes that retired records may still reference.
    vkDeviceWaitIdle(s.device);
    if (s.ahbImports) {
        s.ahbImports->drainAllRetired();
    }

    if (s.frameRenderer) {
        s.frameRenderer->invalidatePipeline();
    }
    return s.surfaceSwapchain->resize(width, height);
}

void VulkanBackend::detachSurface() {
    if (!impl_) return;
    Impl& s = *impl_;
    if (s.device != VK_NULL_HANDLE) {
        vkDeviceWaitIdle(s.device);
    }
    // Phase 2P2: After idle wait, drain retired imports so their Vulkan objects
    // are freed before the swapchain surfaces they referenced are torn down.
    if (s.ahbImports) {
        s.ahbImports->drainAllRetired();
    }
    if (s.frameRenderer) {
        s.frameRenderer->invalidatePipeline();
    }
    if (s.surfaceSwapchain) {
        s.surfaceSwapchain->detach();
    }
}

bool VulkanBackend::hasSurface() const {
    return impl_ && impl_->surfaceSwapchain && impl_->surfaceSwapchain->hasSurface();
}

// ---------------------------------------------------------------------------
// Phase 2C: AHardwareBuffer import - Android
// ---------------------------------------------------------------------------

HardwareBufferImportResult VulkanBackend::importHardwareBuffer(
    void* hardwareBuffer,
    int acquireFenceFd,
    HardwareBufferHandle* outHandle,
    HardwareBufferDescriptor* outDescriptor)
{
    if (!impl_ || !impl_->initialized) {
        if (acquireFenceFd >= 0) ::close(acquireFenceFd);
        if (outHandle)     *outHandle     = kInvalidHardwareBufferHandle;
        if (outDescriptor) *outDescriptor = HardwareBufferDescriptor{};
        return HardwareBufferImportResult::kBackendNotInitialized;
    }
    if (!impl_->ahbImports) {
        if (acquireFenceFd >= 0) ::close(acquireFenceFd);
        if (outHandle)     *outHandle     = kInvalidHardwareBufferHandle;
        if (outDescriptor) *outDescriptor = HardwareBufferDescriptor{};
        return HardwareBufferImportResult::kUnavailable;
    }
    return impl_->ahbImports->importBuffer(hardwareBuffer, acquireFenceFd,
                                          outHandle, outDescriptor);
}

HardwareBufferImportResult VulkanBackend::releaseHardwareBuffer(
    HardwareBufferHandle handle,
    int* outReleaseFenceFd)
{
    if (outReleaseFenceFd) *outReleaseFenceFd = -1;
    if (!impl_ || !impl_->initialized || !impl_->ahbImports) {
        return HardwareBufferImportResult::kUnavailable;
    }
    Impl& s = *impl_;

    // Phase 2P2: Non-blocking normal release path.
    // releaseBuffer() moves in-flight records to the retired queue instead of
    // destroying them immediately. No idle wait or pipeline invalidation here;
    // the pipeline may still reference current descriptor/image resources.
    const HardwareBufferImportResult result =
        s.ahbImports->releaseBuffer(handle, outReleaseFenceFd);

    // Phase 2P2: Bounded backpressure. If the retired queue has grown beyond 16
    // records, force a global idle and drain-all to prevent unbounded native
    // resource accumulation. This is a fallback path only; the normal drain
    // occurs per-frame after the corresponding frame fence wait.
    if (result == HardwareBufferImportResult::kSuccess &&
        s.ahbImports->retiredRecordCount() > 16) {
        VGLOG_VKB("releaseHardwareBuffer: retired count exceeded 16; "
                  "forcing vkDeviceWaitIdle + drainAllRetired");
        if (s.device != VK_NULL_HANDLE) {
            vkDeviceWaitIdle(s.device);
        }
        s.ahbImports->drainAllRetired();
    }

    return result;
}


bool VulkanBackend::hasHardwareBuffer(HardwareBufferHandle handle) const {
    if (!impl_ || !impl_->initialized || !impl_->ahbImports) return false;
    return impl_->ahbImports->hasBuffer(handle);
}

// ---------------------------------------------------------------------------
// renderFrame - Android.
// Phase 2P2: Non-blocking AHardwareBuffer retirement queue active.
// Released imports are deferred to drainRetiredForFrame() called after the
// corresponding frame fence wait, removing normal-path vkDeviceWaitIdle.
// Compute-pipeline deferral is not implemented in this phase.
// ---------------------------------------------------------------------------

RenderFrameResult VulkanBackend::renderFrame(HardwareBufferHandle handle) {
    if (!impl_ || !impl_->initialized) {
        return RenderFrameResult::kBackendNotInitialized;
    }
    Impl& s = *impl_;
    if (!s.surfaceSwapchain || !s.surfaceSwapchain->hasSurface()) {
        return RenderFrameResult::kNoSurface;
    }
    if (!s.ahbImports || !hasHardwareBuffer(handle) || s.ahbImports->getImage(handle) == nullptr) {
        return RenderFrameResult::kInvalidBufferHandle;
    }
    if (!s.frameRenderer || !s.coreShaders) {
        return RenderFrameResult::kUnavailable;
    }
    return s.frameRenderer->renderFrame(
        static_cast<void*>(s.queue),
        *s.surfaceSwapchain,
        *s.ahbImports,
        *s.coreShaders,
        handle);
}

// ---------------------------------------------------------------------------
// Phase 4B2C: renderFrame with rotation transform - Android.
// Builds VideoTransformPushConstants and delegates to the frame renderer.
// ---------------------------------------------------------------------------

RenderFrameResult VulkanBackend::renderFrame(HardwareBufferHandle handle,
                                             const VideoFrameTransform& transform) {
    if (!impl_ || !impl_->initialized) {
        return RenderFrameResult::kBackendNotInitialized;
    }
    Impl& s = *impl_;
    if (!s.surfaceSwapchain || !s.surfaceSwapchain->hasSurface()) {
        return RenderFrameResult::kNoSurface;
    }
    if (!s.ahbImports || !hasHardwareBuffer(handle) || s.ahbImports->getImage(handle) == nullptr) {
        return RenderFrameResult::kInvalidBufferHandle;
    }
    if (!s.frameRenderer || !s.coreShaders) {
        return RenderFrameResult::kUnavailable;
    }
    return s.frameRenderer->renderFrame(
        static_cast<void*>(s.queue),
        *s.surfaceSwapchain,
        *s.ahbImports,
        *s.coreShaders,
        handle,
        transform);
}

// ---------------------------------------------------------------------------
// P5-OVERLAYS-TRANS / P5-OVERLAYS-PRODUCTION-EXPORT-ROUTE-A backend seam
// sub-slice N3: renderFrame with overlay draws - Android.
// Delegates to the frame renderer's overlay-aware overload, which itself
// delegates straight back to the plain transform overload whenever
// overlayCount == 0 -- so this seam never changes non-overlay behavior.
// ---------------------------------------------------------------------------

RenderFrameResult VulkanBackend::renderFrame(HardwareBufferHandle handle,
                                             const VideoFrameTransform& transform,
                                             const VulkanOverlayFrameDraw* overlayDraws,
                                             uint32_t overlayCount) {
    if (!impl_ || !impl_->initialized) {
        return RenderFrameResult::kBackendNotInitialized;
    }
    Impl& s = *impl_;
    if (!s.surfaceSwapchain || !s.surfaceSwapchain->hasSurface()) {
        return RenderFrameResult::kNoSurface;
    }
    if (!s.ahbImports || !hasHardwareBuffer(handle) || s.ahbImports->getImage(handle) == nullptr) {
        return RenderFrameResult::kInvalidBufferHandle;
    }
    if (!s.frameRenderer || !s.coreShaders) {
        return RenderFrameResult::kUnavailable;
    }
    return s.frameRenderer->renderFrame(
        static_cast<void*>(s.queue),
        *s.surfaceSwapchain,
        *s.ahbImports,
        *s.coreShaders,
        handle,
        transform,
        overlayDraws,
        overlayCount);
}

// ---------------------------------------------------------------------------
// P5-BEAUTY-V2-PRODUCTION-EXPORT-ROUTE-A: renderFrame with beauty - Android.
// Delegates to the frame renderer's beauty-aware overload, which itself
// delegates straight back to the plain transform overload whenever
// beauty.enabled is false -- so this seam never changes non-beauty behavior.
// ---------------------------------------------------------------------------

RenderFrameResult VulkanBackend::renderFrame(HardwareBufferHandle handle,
                                             const VideoFrameTransform& transform,
                                             const VideoBeautyV2RenderParams& beauty) {
    if (!impl_ || !impl_->initialized) {
        return RenderFrameResult::kBackendNotInitialized;
    }
    Impl& s = *impl_;
    if (!s.surfaceSwapchain || !s.surfaceSwapchain->hasSurface()) {
        return RenderFrameResult::kNoSurface;
    }
    if (!s.ahbImports || !hasHardwareBuffer(handle) || s.ahbImports->getImage(handle) == nullptr) {
        return RenderFrameResult::kInvalidBufferHandle;
    }
    if (!s.frameRenderer || !s.coreShaders) {
        return RenderFrameResult::kUnavailable;
    }
    return s.frameRenderer->renderFrame(
        static_cast<void*>(s.queue),
        static_cast<void*>(s.physDev),
        *s.surfaceSwapchain,
        *s.ahbImports,
        *s.coreShaders,
        handle,
        transform,
        beauty);
}

// ---------------------------------------------------------------------------
// P5-OVERLAYS-BEAUTY-SOLO: renderFrame with both beauty and overlay draws -
// Android. Delegates to the frame renderer's combined overload, which itself
// delegates straight back to the overlay-only or beauty-only overload above
// whenever beauty.enabled is false or overlayCount == 0 respectively -- so
// this seam never changes either existing single-feature path.
// ---------------------------------------------------------------------------

RenderFrameResult VulkanBackend::renderFrame(HardwareBufferHandle handle,
                                             const VideoFrameTransform& transform,
                                             const VideoBeautyV2RenderParams& beauty,
                                             const VulkanOverlayFrameDraw* overlayDraws,
                                             uint32_t overlayCount) {
    if (!impl_ || !impl_->initialized) {
        return RenderFrameResult::kBackendNotInitialized;
    }
    Impl& s = *impl_;
    if (!s.surfaceSwapchain || !s.surfaceSwapchain->hasSurface()) {
        return RenderFrameResult::kNoSurface;
    }
    if (!s.ahbImports || !hasHardwareBuffer(handle) || s.ahbImports->getImage(handle) == nullptr) {
        return RenderFrameResult::kInvalidBufferHandle;
    }
    if (!s.frameRenderer || !s.coreShaders) {
        return RenderFrameResult::kUnavailable;
    }
    return s.frameRenderer->renderFrame(
        static_cast<void*>(s.queue),
        static_cast<void*>(s.physDev),
        *s.surfaceSwapchain,
        *s.ahbImports,
        *s.coreShaders,
        handle,
        transform,
        beauty,
        overlayDraws,
        overlayCount);
}

// ---------------------------------------------------------------------------
// P5-COMPOSITOR-TRANS: renderTransitionFrame - Android.
// Validates both imports and delegates to the frame renderer's two-source
// transition path, which preserves the swapchain acquire / frame fence /
// semaphore / release-fence-export protocol of renderFrame.
// ---------------------------------------------------------------------------

RenderFrameResult VulkanBackend::renderTransitionFrame(
    HardwareBufferHandle fromHandle,
    HardwareBufferHandle toHandle,
    const VideoTransitionFrameTransform& transition,
    const VideoBeautyV2RenderParams& fromBeauty,
    const VideoBeautyV2RenderParams& toBeauty) {
    if (!impl_ || !impl_->initialized) {
        return RenderFrameResult::kBackendNotInitialized;
    }
    Impl& s = *impl_;
    if (!s.surfaceSwapchain || !s.surfaceSwapchain->hasSurface()) {
        return RenderFrameResult::kNoSurface;
    }
    if (!s.ahbImports || fromHandle == toHandle ||
        !hasHardwareBuffer(fromHandle) || s.ahbImports->getImage(fromHandle) == nullptr ||
        !hasHardwareBuffer(toHandle) || s.ahbImports->getImage(toHandle) == nullptr) {
        return RenderFrameResult::kInvalidBufferHandle;
    }
    if (!s.frameRenderer || !s.coreShaders) {
        return RenderFrameResult::kUnavailable;
    }
    return s.frameRenderer->renderTransitionFrame(
        static_cast<void*>(s.queue),
        static_cast<void*>(s.physDev),
        *s.surfaceSwapchain,
        *s.ahbImports,
        *s.coreShaders,
        fromHandle,
        toHandle,
        transition,
        fromBeauty,
        toBeauty);
}

// ---------------------------------------------------------------------------
// P5-OVERLAYS-TRANSITION-COMP-N1: renderTransitionFrame with overlay draws -
// Android. Delegates to the frame renderer's overlay-aware transition
// overload, which itself delegates straight back to the plain transition
// overload whenever overlayCount == 0 -- so this seam never changes
// non-overlay transition behavior. Native-only: no JNI/Kotlin route calls
// this yet, and this slice does not change export admission.
// ---------------------------------------------------------------------------

RenderFrameResult VulkanBackend::renderTransitionFrame(
    HardwareBufferHandle fromHandle,
    HardwareBufferHandle toHandle,
    const VideoTransitionFrameTransform& transition,
    const VulkanOverlayFrameDraw* overlayDraws,
    uint32_t overlayCount,
    const VideoBeautyV2RenderParams& fromBeauty,
    const VideoBeautyV2RenderParams& toBeauty) {
    if (!impl_ || !impl_->initialized) {
        return RenderFrameResult::kBackendNotInitialized;
    }
    Impl& s = *impl_;
    if (!s.surfaceSwapchain || !s.surfaceSwapchain->hasSurface()) {
        return RenderFrameResult::kNoSurface;
    }
    if (!s.ahbImports || fromHandle == toHandle ||
        !hasHardwareBuffer(fromHandle) || s.ahbImports->getImage(fromHandle) == nullptr ||
        !hasHardwareBuffer(toHandle) || s.ahbImports->getImage(toHandle) == nullptr) {
        return RenderFrameResult::kInvalidBufferHandle;
    }
    if (!s.frameRenderer || !s.coreShaders) {
        return RenderFrameResult::kUnavailable;
    }
    return s.frameRenderer->renderTransitionFrame(
        static_cast<void*>(s.queue),
        static_cast<void*>(s.physDev),
        *s.surfaceSwapchain,
        *s.ahbImports,
        *s.coreShaders,
        fromHandle,
        toHandle,
        transition,
        overlayDraws,
        overlayCount,
        fromBeauty,
        toBeauty);
}

// ---------------------------------------------------------------------------
// P5-OVERLAYS-TRANS / P5-OVERLAYS-PRODUCTION-EXPORT-ROUTE-A backend seam
// sub-slice N4: overlay texture store - Android.
// The store is lazily instantiated/initialized on the first successful call
// here rather than eagerly during VulkanBackend::initialize().
// ---------------------------------------------------------------------------

bool VulkanBackend::createOverlayTextureRgba8888(const uint8_t* rgba,
                                                 size_t rgbaByteCount,
                                                 uint32_t width,
                                                 uint32_t height,
                                                 uint32_t rowStrideBytes,
                                                 VulkanOverlayTextureHandle* outHandle,
                                                 VulkanOverlayTextureInfo* outInfo) {
    if (!impl_ || !impl_->initialized) {
        if (outHandle) *outHandle = kInvalidOverlayTextureHandle;
        if (outInfo) *outInfo = VulkanOverlayTextureInfo{};
        return false;
    }
    Impl& s = *impl_;
    if (!s.overlayTextureStore) {
        s.overlayTextureStore = std::make_unique<VulkanOverlayTextureStore>();
        if (!s.overlayTextureStore->initialize(static_cast<void*>(s.device),
                                               static_cast<void*>(s.physDev),
                                               static_cast<void*>(s.queue),
                                               s.queueFamilyIndex)) {
            s.overlayTextureStore.reset();
        }
    }
    if (!s.overlayTextureStore) {
        if (outHandle) *outHandle = kInvalidOverlayTextureHandle;
        if (outInfo) *outInfo = VulkanOverlayTextureInfo{};
        return false;
    }
    return s.overlayTextureStore->createTextureRgba8888(
        rgba, rgbaByteCount, width, height, rowStrideBytes, outHandle, outInfo);
}

bool VulkanBackend::createOverlayTextureR8(const uint8_t* r8,
                                           size_t r8ByteCount,
                                           uint32_t width,
                                           uint32_t height,
                                           uint32_t rowStrideBytes,
                                           VulkanOverlayTextureHandle* outHandle,
                                           VulkanOverlayTextureInfo* outInfo) {
    if (!impl_ || !impl_->initialized) {
        if (outHandle) *outHandle = kInvalidOverlayTextureHandle;
        if (outInfo) *outInfo = VulkanOverlayTextureInfo{};
        return false;
    }
    Impl& s = *impl_;
    if (!s.overlayTextureStore) {
        s.overlayTextureStore = std::make_unique<VulkanOverlayTextureStore>();
        if (!s.overlayTextureStore->initialize(static_cast<void*>(s.device),
                                               static_cast<void*>(s.physDev),
                                               static_cast<void*>(s.queue),
                                               s.queueFamilyIndex)) {
            s.overlayTextureStore.reset();
        }
    }
    if (!s.overlayTextureStore) {
        if (outHandle) *outHandle = kInvalidOverlayTextureHandle;
        if (outInfo) *outInfo = VulkanOverlayTextureInfo{};
        return false;
    }
    return s.overlayTextureStore->createTextureR8(
        r8, r8ByteCount, width, height, rowStrideBytes, outHandle, outInfo);
}

bool VulkanBackend::updateOverlayTextureR8(VulkanOverlayTextureHandle handle,
                                           const uint8_t* r8,
                                           size_t r8ByteCount,
                                           uint32_t width,
                                           uint32_t height,
                                           uint32_t rowStrideBytes) {
    if (!impl_ || !impl_->initialized || !impl_->overlayTextureStore) {
        return false;
    }
    return impl_->overlayTextureStore->updateTextureR8(
        handle, r8, r8ByteCount, width, height, rowStrideBytes, nullptr);
}

bool VulkanBackend::releaseOverlayTexture(VulkanOverlayTextureHandle handle) {
    if (!impl_ || !impl_->initialized || !impl_->overlayTextureStore) {
        return false;
    }
    return impl_->overlayTextureStore->releaseTexture(handle);
}

bool VulkanBackend::getOverlayTextureInfo(VulkanOverlayTextureHandle handle,
                                          VulkanOverlayTextureInfo* outInfo) const {
    if (!impl_ || !impl_->initialized || !impl_->overlayTextureStore) {
        if (outInfo) *outInfo = VulkanOverlayTextureInfo{};
        return false;
    }
    return impl_->overlayTextureStore->getTextureInfo(handle, outInfo);
}

void VulkanBackend::clearOverlayTextures() {
    if (!impl_ || !impl_->overlayTextureStore) {
        return;
    }
    impl_->overlayTextureStore->clear();
}

// ANDROID-DUET-VULKAN-GREENSCREEN-VISUAL: validates the same backend /
// surface / import preconditions as renderDuetLayoutFrame below, selects the
// mask (GPU import preferred, CPU overlay texture otherwise), then delegates
// to VulkanFrameRenderer::renderDuetGreenScreenFrame with the core
// passthrough shaders for the source layer and the same per-layer rect /
// buffer-dimension contract as the layout path.
RenderFrameResult VulkanBackend::renderDuetGreenScreenFrame(HardwareBufferHandle sourceHandle,
                                                            HardwareBufferHandle cameraHandle,
                                                            const RenderDestinationRect& sourceRect,
                                                            const RenderDestinationRect& cameraRect,
                                                            uint32_t sourceBufferWidth,
                                                            uint32_t sourceBufferHeight,
                                                            uint32_t cameraBufferWidth,
                                                            uint32_t cameraBufferHeight,
                                                            VulkanOverlayTextureHandle cpuMaskHandle,
                                                            HardwareBufferHandle gpuMaskHandle,
                                                            uint32_t gpuMaskWidth,
                                                            uint32_t gpuMaskHeight,
                                                            uint32_t sourceRotationDegrees,
                                                            bool sourceMirrorHorizontal,
                                                            uint32_t cameraRotationDegrees,
                                                            bool cameraMirrorHorizontal,
                                                            int32_t debugMode) {
    if (!impl_ || !impl_->initialized) {
        return RenderFrameResult::kBackendNotInitialized;
    }
    Impl& s = *impl_;
    if (!s.surfaceSwapchain || !s.surfaceSwapchain->hasSurface()) {
        return RenderFrameResult::kNoSurface;
    }
    if (!s.ahbImports || sourceHandle == cameraHandle ||
        !hasHardwareBuffer(sourceHandle) || s.ahbImports->getImage(sourceHandle) == nullptr ||
        !hasHardwareBuffer(cameraHandle) || s.ahbImports->getImage(cameraHandle) == nullptr) {
        return RenderFrameResult::kInvalidBufferHandle;
    }
    if (!s.frameRenderer || !s.coreShaders) {
        return RenderFrameResult::kUnavailable;
    }

    // ANDROID-DUET-VULKAN-GPU-MASK: prefer the GPU-resident mask when the
    // caller supplied a currently active import distinct from the source /
    // camera buffers being rendered this frame; otherwise fall back to the
    // CPU-uploaded overlay-texture mask (unchanged behavior when
    // gpuMaskHandle is kInvalidHardwareBufferHandle). The mask is sampled
    // through the green-screen helper's own mutable sampler, so an
    // external-format (YCbCr, immutable-sampler-only) GPU mask import is
    // not usable and also falls back to the CPU mask.
    const VulkanHardwareBufferImage* gpuMaskImage =
        (gpuMaskHandle != kInvalidHardwareBufferHandle && gpuMaskWidth > 0 && gpuMaskHeight > 0 &&
         gpuMaskHandle != sourceHandle && gpuMaskHandle != cameraHandle &&
         hasHardwareBuffer(gpuMaskHandle))
            ? s.ahbImports->getImage(gpuMaskHandle)
            : nullptr;

    VulkanFrameRenderer::VulkanGreenScreenMaskInfo maskInfo{};
    if (gpuMaskImage != nullptr && gpuMaskImage->imageView != VK_NULL_HANDLE &&
        !gpuMaskImage->isExternalFormat()) {
        maskInfo.imageViewHandle = vkHandleToU64(gpuMaskImage->imageView);
        maskInfo.width = gpuMaskWidth;
        maskInfo.height = gpuMaskHeight;
        maskInfo.gpuMaskHandle = gpuMaskHandle;
    } else {
        VulkanOverlayTextureInfo overlayInfo{};
        if (!getOverlayTextureInfo(cpuMaskHandle, &overlayInfo)) {
            return RenderFrameResult::kVulkanFailure;
        }
        maskInfo.imageViewHandle = overlayInfo.imageViewHandle;
        maskInfo.width = overlayInfo.width;
        maskInfo.height = overlayInfo.height;
        maskInfo.gpuMaskHandle = kInvalidHardwareBufferHandle;
    }
    maskInfo.debugMode = debugMode;

    VulkanFrameRenderer::DuetLayoutLayer source;
    source.handle = sourceHandle;
    source.rect = sourceRect;
    source.bufferWidth = sourceBufferWidth;
    source.bufferHeight = sourceBufferHeight;
    source.rotationDegrees = sourceRotationDegrees;
    source.mirrorHorizontal = sourceMirrorHorizontal;

    VulkanFrameRenderer::DuetLayoutLayer camera;
    camera.handle = cameraHandle;
    camera.rect = cameraRect;
    camera.bufferWidth = cameraBufferWidth;
    camera.bufferHeight = cameraBufferHeight;
    camera.rotationDegrees = cameraRotationDegrees;
    camera.mirrorHorizontal = cameraMirrorHorizontal;

    return s.frameRenderer->renderDuetGreenScreenFrame(
        static_cast<void*>(s.queue),
        *s.surfaceSwapchain,
        *s.ahbImports,
        *s.coreShaders,
        source,
        camera,
        maskInfo);
}

// ANDROID-DUET-VULKAN-GREENSCREEN-STATIC-BACKGROUND (RND diagnostic only):
// validates the same backend / surface preconditions as
// renderDuetGreenScreenFrame above for the single camera import, selects the
// mask with the SAME GPU-preferred / CPU-fallback rule, resolves the
// backgroundMode to its clear colour, then delegates to
// VulkanFrameRenderer::renderDuetGreenScreenStaticBackgroundFrame (no source
// layer, so the core passthrough shaders are not needed here).
RenderFrameResult VulkanBackend::renderDuetGreenScreenStaticBackgroundFrame(
    HardwareBufferHandle cameraHandle,
    const RenderDestinationRect& cameraRect,
    uint32_t cameraBufferWidth,
    uint32_t cameraBufferHeight,
    VulkanOverlayTextureHandle cpuMaskHandle,
    HardwareBufferHandle gpuMaskHandle,
    uint32_t gpuMaskWidth,
    uint32_t gpuMaskHeight,
    uint32_t cameraRotationDegrees,
    bool cameraMirrorHorizontal,
    int32_t debugMode,
    DuetGreenScreenStaticBackgroundMode backgroundMode) {
    if (!impl_ || !impl_->initialized) {
        return RenderFrameResult::kBackendNotInitialized;
    }
    Impl& s = *impl_;
    if (!s.surfaceSwapchain || !s.surfaceSwapchain->hasSurface()) {
        return RenderFrameResult::kNoSurface;
    }
    if (!s.ahbImports ||
        !hasHardwareBuffer(cameraHandle) || s.ahbImports->getImage(cameraHandle) == nullptr) {
        return RenderFrameResult::kInvalidBufferHandle;
    }
    if (!s.frameRenderer) {
        return RenderFrameResult::kUnavailable;
    }

    // Fail closed on an unrecognized mode before the swapchain is touched;
    // only the listed modes have a defined clear colour.
    VulkanFrameRenderer::DuetStaticBackground background;
    switch (backgroundMode) {
        case DuetGreenScreenStaticBackgroundMode::kSolidTeal:
            background.clearRgba[0] = 0.0f;
            background.clearRgba[1] = 0.5f;
            background.clearRgba[2] = 0.5f;
            background.clearRgba[3] = 1.0f;
            background.modeLabel = "solid_teal";
            break;
        default:
            return RenderFrameResult::kVulkanFailure;
    }

    // Same mask selection as renderDuetGreenScreenFrame: prefer the GPU
    // import when active, distinct from the camera buffer and
    // non-external-format; otherwise the CPU-uploaded overlay-texture mask.
    const VulkanHardwareBufferImage* gpuMaskImage =
        (gpuMaskHandle != kInvalidHardwareBufferHandle && gpuMaskWidth > 0 && gpuMaskHeight > 0 &&
         gpuMaskHandle != cameraHandle && hasHardwareBuffer(gpuMaskHandle))
            ? s.ahbImports->getImage(gpuMaskHandle)
            : nullptr;

    VulkanFrameRenderer::VulkanGreenScreenMaskInfo maskInfo{};
    if (gpuMaskImage != nullptr && gpuMaskImage->imageView != VK_NULL_HANDLE &&
        !gpuMaskImage->isExternalFormat()) {
        maskInfo.imageViewHandle = vkHandleToU64(gpuMaskImage->imageView);
        maskInfo.width = gpuMaskWidth;
        maskInfo.height = gpuMaskHeight;
        maskInfo.gpuMaskHandle = gpuMaskHandle;
    } else {
        VulkanOverlayTextureInfo overlayInfo{};
        if (!getOverlayTextureInfo(cpuMaskHandle, &overlayInfo)) {
            return RenderFrameResult::kVulkanFailure;
        }
        maskInfo.imageViewHandle = overlayInfo.imageViewHandle;
        maskInfo.width = overlayInfo.width;
        maskInfo.height = overlayInfo.height;
        maskInfo.gpuMaskHandle = kInvalidHardwareBufferHandle;
    }
    maskInfo.debugMode = debugMode;

    VulkanFrameRenderer::DuetLayoutLayer camera;
    camera.handle = cameraHandle;
    camera.rect = cameraRect;
    camera.bufferWidth = cameraBufferWidth;
    camera.bufferHeight = cameraBufferHeight;
    camera.rotationDegrees = cameraRotationDegrees;
    camera.mirrorHorizontal = cameraMirrorHorizontal;

    return s.frameRenderer->renderDuetGreenScreenStaticBackgroundFrame(
        static_cast<void*>(s.queue),
        *s.surfaceSwapchain,
        *s.ahbImports,
        camera,
        maskInfo,
        background);
}

// ---------------------------------------------------------------------------
// ANDROID-DUET-VULKAN-LAYOUT: two-layer opaque Duet layout frame. Validates
// the same backend / surface / import preconditions as
// renderDuetGreenScreenFrame above, then delegates to VulkanFrameRenderer::
// renderDuetLayoutFrame with the core passthrough shaders (each layer draws
// through its import's own descriptor resources, like a solo frame).
// ---------------------------------------------------------------------------

RenderFrameResult VulkanBackend::renderDuetLayoutFrame(HardwareBufferHandle sourceHandle,
                                                       HardwareBufferHandle cameraHandle,
                                                       const RenderDestinationRect& sourceRect,
                                                       const RenderDestinationRect& cameraRect,
                                                       uint32_t sourceBufferWidth,
                                                       uint32_t sourceBufferHeight,
                                                       uint32_t cameraBufferWidth,
                                                       uint32_t cameraBufferHeight,
                                                       uint32_t sourceRotationDegrees,
                                                       bool sourceMirrorHorizontal,
                                                       uint32_t cameraRotationDegrees,
                                                       bool cameraMirrorHorizontal,
                                                       float cameraCornerRadiusPx) {
    if (!impl_ || !impl_->initialized) {
        return RenderFrameResult::kBackendNotInitialized;
    }
    Impl& s = *impl_;
    if (!s.surfaceSwapchain || !s.surfaceSwapchain->hasSurface()) {
        return RenderFrameResult::kNoSurface;
    }
    if (!s.ahbImports || sourceHandle == cameraHandle ||
        !hasHardwareBuffer(sourceHandle) || s.ahbImports->getImage(sourceHandle) == nullptr ||
        !hasHardwareBuffer(cameraHandle) || s.ahbImports->getImage(cameraHandle) == nullptr) {
        return RenderFrameResult::kInvalidBufferHandle;
    }
    if (!s.frameRenderer || !s.coreShaders) {
        return RenderFrameResult::kUnavailable;
    }

    VulkanFrameRenderer::DuetLayoutLayer source;
    source.handle = sourceHandle;
    source.rect = sourceRect;
    source.bufferWidth = sourceBufferWidth;
    source.bufferHeight = sourceBufferHeight;
    source.rotationDegrees = sourceRotationDegrees;
    source.mirrorHorizontal = sourceMirrorHorizontal;

    VulkanFrameRenderer::DuetLayoutLayer camera;
    camera.handle = cameraHandle;
    camera.rect = cameraRect;
    camera.bufferWidth = cameraBufferWidth;
    camera.bufferHeight = cameraBufferHeight;
    camera.rotationDegrees = cameraRotationDegrees;
    camera.mirrorHorizontal = cameraMirrorHorizontal;
    camera.cornerRadiusPx = cameraCornerRadiusPx;

    return s.frameRenderer->renderDuetLayoutFrame(
        static_cast<void*>(s.queue),
        *s.surfaceSwapchain,
        *s.ahbImports,
        *s.coreShaders,
        source,
        camera);
}

#endif // __ANDROID__

} // namespace render
} // namespace vanguard
