// P3-MULTICAM-NODE-SINGLE-CAM-INGEST-VULKAN-SPATIAL-RENDER: bounded
// diagnostic proof that one real Camera2 ImageReader(YUV_420_888)
// buffer-queue frame (imported/sampled through Vulkan, including the
// samplerYcbcrConversion path for external-format camera buffers) and one
// synthetic solid-blue RGBA8 Vulkan scratch image are laid out by a
// caller-supplied Dart layout descriptor via the existing
// vanguard::compositors::ComputeMultiCamLayout(), rendered by the existing
// vanguard::render::VulkanMultiCamSpatialCompositor, structurally read back,
// and torn down synchronously -- combining the real-camera-HardwareBuffer
// lifecycle of android_phase3_multicam_single_cam_ingest_spatial_render_jni.cpp
// (GLES/OES sibling) with the self-contained Vulkan scratch-context/JSON-
// result shape of android_phase3_multicam_dynamic_descriptor_spatial_vulkan_
// render_jni.cpp. Strict descriptor-string resolution and the descriptor-
// before-any-Vulkan-side-effect ordering are duplicated here verbatim
// (private anonymous-namespace helpers, not shared through a header).
//
// The synthetic secondary layer is a plain Vulkan device image created and
// solid-blue-filled directly by this diagnostic (not an AHardwareBuffer) --
// see the "syntheticLayerSource" detail entry.
//
// The real camera YUV_420_888 buffer is always the Vulkan primary; the
// synthetic blue Vulkan scratch image is always the Vulkan secondary,
// regardless of layoutMode. Per vanguard::compositors::ComputeMultiCamLayout,
// the primary viewport is always the full canvas for both layoutModes, so
// camera-side readback assertions are structural only (import succeeded,
// image/view/sampler non-null, render/readback call succeeded, a probe pixel
// inside the camera region reads fully opaque alpha) -- never hue/luma/
// content, since the real camera frame's pixel content is unconstrained. The
// synthetic secondary additionally asserts deterministic solid blue.
//
// Proof boundary (exact):
// single_camera_ingest_buffer_queue_dynamic_descriptor_spatial_vulkan_render_readback_only_no_concurrent_camera_no_gles_no_recording_no_export_no_product
//
// Non-claims: no concurrent/dual camera, no GLES/OES, no recording/export, no
// product/editor UI, no camera hue/luma/content assertion, no production
// VulkanBackend mutation (this diagnostic owns an isolated temporary
// VkInstance/VkDevice/VkQueue/VkCommandPool).
//
// JNI entry point (matching VanguardNativeBridge.kt declaration):
//   runAndroidDagPhase3SingleCamIngestVulkanSpatialRenderSmoke(
//       cameraYuvBuffer: HardwareBuffer, width: Int, height: Int,
//       layoutMode: String, pipAnchor: String, pipCenterX: Double,
//       pipCenterY: Double, pipWidthFraction: Double, pipAspectRatio: Double,
//       pipMarginFraction: Double, splitDirection: String,
//       splitRatio: Double) -> jstring (JSON)

#include <jni.h>
#include <android/hardware_buffer.h>

#ifndef VK_USE_PLATFORM_ANDROID_KHR
#define VK_USE_PLATFORM_ANDROID_KHR
#endif
#include <vulkan/vulkan.h>

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <dlfcn.h>
#include <functional>
#include <memory>
#include <sstream>
#include <string>
#include <unistd.h>
#include <vector>

#include "vanguard/compositors/multi_cam_compositor_node.h"
#include "vulkan_hardware_buffer_imports.h"
#include "vulkan_hardware_buffer_image.h"
#include "vulkan_multicam_spatial_compositor.h"

namespace {

using vanguard::compositors::ComputeMultiCamLayout;
using vanguard::compositors::MultiCamLayout;
using vanguard::compositors::MultiCamLayoutMode;
using vanguard::compositors::MultiCamLayoutResult;
using vanguard::compositors::MultiCamPiPAnchor;
using vanguard::compositors::MultiCamSplitDirection;
using vanguard::compositors::NormalizedRect;
using vanguard::render::HardwareBufferHandle;
using vanguard::render::HardwareBufferDescriptor;
using vanguard::render::HardwareBufferImportResult;
using vanguard::render::VulkanHardwareBufferImage;
using vanguard::render::VulkanHardwareBufferImports;
using vanguard::render::VulkanMultiCamSpatialCompositor;
using vanguard::render::VulkanMultiCamSpatialLayerImage;
using vanguard::render::VulkanMultiCamSpatialRenderTarget;
using vanguard::render::VulkanSpatialViewportRectPx;
using vanguard::render::kInvalidHardwareBufferHandle;

constexpr const char* kProofBoundary =
    "single_camera_ingest_buffer_queue_dynamic_descriptor_spatial_vulkan_render_readback_only_no_concurrent_camera_no_gles_"
    "no_recording_no_export_no_product";
constexpr const char* kPassMarker = "ANDROID_DAG_PHASE3_SINGLE_CAM_INGEST_VULKAN_SPATIAL_RENDER_PASS";
constexpr const char* kFailMarker = "ANDROID_DAG_PHASE3_SINGLE_CAM_INGEST_VULKAN_SPATIAL_RENDER_FAIL";

constexpr int      kColorTolerance = 8;
constexpr VkFormat kColorFormat    = VK_FORMAT_R8G8B8A8_UNORM;

struct Rgb {
    uint8_t r;
    uint8_t g;
    uint8_t b;
};

constexpr Rgb kBlue  = {0, 0, 255};   // synthetic secondary layer
constexpr Rgb kGreen = {0, 255, 0};   // clear sentinel: only where no layer draws

std::string JStringToStdString(JNIEnv* env, jstring value) {
    if (!value) return std::string();
    const char* chars = env->GetStringUTFChars(value, nullptr);
    if (!chars) return std::string();
    std::string result(chars);
    env->ReleaseStringUTFChars(value, chars);
    return result;
}

// ---------------------------------------------------------------------------
// AHardwareBuffer_fromHardwareBuffer native symbol resolution (duplicated
// from android_phase3_multicam_single_cam_ingest_spatial_render_jni.cpp /
// android_phase3_multicam_dynamic_descriptor_spatial_render_jni.cpp).
// ---------------------------------------------------------------------------

using FnAHardwareBuffer_fromHardwareBuffer = AHardwareBuffer* (*)(JNIEnv*, jobject);

FnAHardwareBuffer_fromHardwareBuffer ResolveFromHardwareBufferFn() {
    void* lib = dlopen("libandroid.so", RTLD_NOW | RTLD_LOCAL);
    if (!lib) return nullptr;
    auto fn = reinterpret_cast<FnAHardwareBuffer_fromHardwareBuffer>(
        dlsym(lib, "AHardwareBuffer_fromHardwareBuffer"));
    dlclose(lib);
    return fn;
}

// ---------------------------------------------------------------------------
// Strict Dart-descriptor-string -> native MultiCam* enum resolution (private
// per-translation-unit copy of the policy shared by every dynamic-descriptor
// sibling route): every resolver reports ok=false for any string outside the
// exact accepted set instead of silently substituting a default, since this
// route performs real GPU rendering that must never proceed on a silently-
// reinterpreted layout.
// ---------------------------------------------------------------------------

struct LayoutModeResolution {
    bool ok = false;
    MultiCamLayoutMode mode = MultiCamLayoutMode::kPictureInPicture;
};

LayoutModeResolution ResolveLayoutModeStrict(const std::string& raw) {
    if (raw == "pip") return {true, MultiCamLayoutMode::kPictureInPicture};
    if (raw == "splitScreen") return {true, MultiCamLayoutMode::kSplitScreen};
    return {false, MultiCamLayoutMode::kPictureInPicture};
}

struct AnchorResolution {
    bool ok = false;
    MultiCamPiPAnchor anchor = MultiCamPiPAnchor::kFreeFloating;
};

AnchorResolution ResolveAnchorStrict(const std::string& raw) {
    if (raw == "freeFloating") return {true, MultiCamPiPAnchor::kFreeFloating};
    if (raw == "topLeft") return {true, MultiCamPiPAnchor::kTopLeft};
    if (raw == "topRight") return {true, MultiCamPiPAnchor::kTopRight};
    if (raw == "bottomLeft") return {true, MultiCamPiPAnchor::kBottomLeft};
    if (raw == "bottomRight") return {true, MultiCamPiPAnchor::kBottomRight};
    return {false, MultiCamPiPAnchor::kFreeFloating};
}

struct SplitDirectionResolution {
    bool ok = false;
    MultiCamSplitDirection direction = MultiCamSplitDirection::kTopBottom;
};

SplitDirectionResolution ResolveSplitDirectionStrict(const std::string& raw) {
    if (raw == "topBottom") return {true, MultiCamSplitDirection::kTopBottom};
    if (raw == "leftRight") return {true, MultiCamSplitDirection::kLeftRight};
    return {false, MultiCamSplitDirection::kTopBottom};
}

const char* LayoutModeName(MultiCamLayoutMode mode) {
    return mode == MultiCamLayoutMode::kSplitScreen ? "splitScreen" : "pip";
}

const char* AnchorName(MultiCamPiPAnchor anchor) {
    switch (anchor) {
        case MultiCamPiPAnchor::kTopLeft: return "topLeft";
        case MultiCamPiPAnchor::kTopRight: return "topRight";
        case MultiCamPiPAnchor::kBottomLeft: return "bottomLeft";
        case MultiCamPiPAnchor::kBottomRight: return "bottomRight";
        case MultiCamPiPAnchor::kFreeFloating: return "freeFloating";
    }
    return "freeFloating";
}

const char* SplitDirectionName(MultiCamSplitDirection direction) {
    return direction == MultiCamSplitDirection::kLeftRight ? "leftRight" : "topBottom";
}

struct ResolvedDescriptor {
    bool ok = false;
    std::string rejectionReason;
    MultiCamLayoutMode mode = MultiCamLayoutMode::kPictureInPicture;
    MultiCamPiPAnchor anchor = MultiCamPiPAnchor::kFreeFloating;
    MultiCamSplitDirection direction = MultiCamSplitDirection::kTopBottom;
};

ResolvedDescriptor ResolveDescriptorStrict(const std::string& layoutModeRaw,
                                           const std::string& pipAnchorRaw,
                                           const std::string& splitDirectionRaw) {
    ResolvedDescriptor out;
    const LayoutModeResolution modeRes = ResolveLayoutModeStrict(layoutModeRaw);
    if (!modeRes.ok) {
        out.rejectionReason = "unknown_layout_mode";
        return out;
    }
    const AnchorResolution anchorRes = ResolveAnchorStrict(pipAnchorRaw);
    if (!anchorRes.ok) {
        out.rejectionReason = "unknown_pip_anchor";
        return out;
    }
    const SplitDirectionResolution directionRes = ResolveSplitDirectionStrict(splitDirectionRaw);
    if (!directionRes.ok) {
        out.rejectionReason = "unknown_split_direction";
        return out;
    }
    out.ok        = true;
    out.mode      = modeRes.mode;
    out.anchor    = anchorRes.anchor;
    out.direction = directionRes.direction;
    return out;
}

// -- Vulkan scratch context (owned entirely by this diagnostic) -------------
// Private per-translation-unit copy of the shape used by every other
// diagnostic Vulkan scratch context in this codebase, extended with the
// AHardwareBuffer import device requirements (VK_ANDROID_external_memory_
// android_hardware_buffer device extension + samplerYcbcrConversion feature)
// so a real camera YUV buffer can be imported through
// VulkanHardwareBufferImports on the selected device.

uint32_t FindMemoryType(const VkPhysicalDeviceMemoryProperties& props,
                        uint32_t typeBits,
                        VkMemoryPropertyFlags required) {
    for (uint32_t i = 0; i < props.memoryTypeCount; ++i) {
        if ((typeBits & (1u << i)) != 0 &&
            (props.memoryTypes[i].propertyFlags & required) == required) {
            return i;
        }
    }
    return UINT32_MAX;
}

constexpr const char* kAhbDeviceExtension = "VK_ANDROID_external_memory_android_hardware_buffer";

bool DeviceSupportsExtension(VkPhysicalDevice physDev, const char* extensionName) {
    uint32_t count = 0;
    if (vkEnumerateDeviceExtensionProperties(physDev, nullptr, &count, nullptr) != VK_SUCCESS) {
        return false;
    }
    std::vector<VkExtensionProperties> available(count);
    if (count > 0 &&
        vkEnumerateDeviceExtensionProperties(physDev, nullptr, &count, available.data()) != VK_SUCCESS) {
        return false;
    }
    for (const auto& ext : available) {
        if (std::strcmp(ext.extensionName, extensionName) == 0) return true;
    }
    return false;
}

bool DeviceSupportsYcbcrConversion(VkInstance instance, VkPhysicalDevice physDev) {
    auto pfnGetFeatures2 = reinterpret_cast<PFN_vkGetPhysicalDeviceFeatures2>(
        vkGetInstanceProcAddr(instance, "vkGetPhysicalDeviceFeatures2"));
    if (!pfnGetFeatures2) {
        pfnGetFeatures2 = reinterpret_cast<PFN_vkGetPhysicalDeviceFeatures2>(
            vkGetInstanceProcAddr(instance, "vkGetPhysicalDeviceFeatures2KHR"));
    }
    if (!pfnGetFeatures2) return false;

    VkPhysicalDeviceSamplerYcbcrConversionFeatures ycbcr{};
    ycbcr.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_SAMPLER_YCBCR_CONVERSION_FEATURES;
    VkPhysicalDeviceFeatures2 features2{};
    features2.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2;
    features2.pNext = &ycbcr;
    pfnGetFeatures2(physDev, &features2);
    return ycbcr.samplerYcbcrConversion == VK_TRUE;
}

struct VulkanScratch {
    VkInstance       instance    = VK_NULL_HANDLE;
    VkPhysicalDevice physDev     = VK_NULL_HANDLE;
    uint32_t         queueFamily = UINT32_MAX;
    VkDevice         device      = VK_NULL_HANDLE;
    VkQueue          queue       = VK_NULL_HANDLE;
    VkCommandPool    commandPool = VK_NULL_HANDLE;
    VkPhysicalDeviceMemoryProperties memProps{};
    std::string      deviceName;
    uint32_t         deviceType    = 0;
    uint32_t         apiVersion    = 0;
    uint32_t         driverVersion = 0;
    bool             teardownWaitIdleOk = false;

    bool Setup(std::string* outError, bool* outUnsupported) {
        *outUnsupported = false;
        VkApplicationInfo appInfo{};
        appInfo.sType              = VK_STRUCTURE_TYPE_APPLICATION_INFO;
        appInfo.pApplicationName   = "VanguardSingleCamIngestVulkanSpatialSmoke";
        appInfo.applicationVersion = VK_MAKE_VERSION(0, 1, 0);
        appInfo.pEngineName        = "VanguardRenderEngine";
        appInfo.engineVersion      = VK_MAKE_VERSION(0, 1, 0);
        appInfo.apiVersion         = VK_API_VERSION_1_1;

        VkInstanceCreateInfo instanceCI{};
        instanceCI.sType            = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO;
        instanceCI.pApplicationInfo = &appInfo;
        VkResult vr = vkCreateInstance(&instanceCI, nullptr, &instance);
        if (vr != VK_SUCCESS) {
            instance = VK_NULL_HANDLE;
            *outUnsupported = true;
            *outError = "vulkan_instance_unavailable:" + std::to_string(static_cast<int>(vr));
            return false;
        }

        uint32_t deviceCount = 0;
        vr = vkEnumeratePhysicalDevices(instance, &deviceCount, nullptr);
        if (vr != VK_SUCCESS || deviceCount == 0) {
            *outUnsupported = true;
            *outError = "vulkan_no_physical_devices";
            Teardown();
            return false;
        }
        std::vector<VkPhysicalDevice> devices(deviceCount);
        if (vkEnumeratePhysicalDevices(instance, &deviceCount, devices.data()) != VK_SUCCESS) {
            *outError = "vulkan_enumerate_physical_devices_failed";
            Teardown();
            return false;
        }

        for (VkPhysicalDevice dev : devices) {
            VkPhysicalDeviceProperties props{};
            vkGetPhysicalDeviceProperties(dev, &props);
            if (props.deviceType == VK_PHYSICAL_DEVICE_TYPE_CPU) continue;
            if (VK_VERSION_MAJOR(props.apiVersion) < 1 ||
                (VK_VERSION_MAJOR(props.apiVersion) == 1 && VK_VERSION_MINOR(props.apiVersion) < 1)) {
                continue;
            }

            uint32_t familyCount = 0;
            vkGetPhysicalDeviceQueueFamilyProperties(dev, &familyCount, nullptr);
            std::vector<VkQueueFamilyProperties> families(familyCount);
            vkGetPhysicalDeviceQueueFamilyProperties(dev, &familyCount, families.data());
            uint32_t graphicsFamily = UINT32_MAX;
            for (uint32_t i = 0; i < familyCount; ++i) {
                if (families[i].queueCount > 0 &&
                    (families[i].queueFlags & VK_QUEUE_GRAPHICS_BIT) != 0) {
                    graphicsFamily = i;
                    break;
                }
            }
            if (graphicsFamily == UINT32_MAX) continue;

            VkFormatProperties fmt{};
            vkGetPhysicalDeviceFormatProperties(dev, kColorFormat, &fmt);
            const VkFormatFeatureFlags needed =
                VK_FORMAT_FEATURE_COLOR_ATTACHMENT_BIT | VK_FORMAT_FEATURE_SAMPLED_IMAGE_BIT |
                VK_FORMAT_FEATURE_TRANSFER_SRC_BIT | VK_FORMAT_FEATURE_TRANSFER_DST_BIT;
            if ((fmt.optimalTilingFeatures & needed) != needed) continue;

            if (!DeviceSupportsExtension(dev, kAhbDeviceExtension)) continue;
            if (!DeviceSupportsYcbcrConversion(instance, dev)) continue;

            physDev       = dev;
            queueFamily   = graphicsFamily;
            deviceName    = props.deviceName;
            deviceType    = static_cast<uint32_t>(props.deviceType);
            apiVersion    = props.apiVersion;
            driverVersion = props.driverVersion;
            break;
        }
        if (physDev == VK_NULL_HANDLE) {
            *outUnsupported = true;
            *outError = "vulkan_no_suitable_ahb_capable_graphics_device";
            Teardown();
            return false;
        }
        vkGetPhysicalDeviceMemoryProperties(physDev, &memProps);

        const float priority = 1.0f;
        VkDeviceQueueCreateInfo queueCI{};
        queueCI.sType            = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO;
        queueCI.queueFamilyIndex = queueFamily;
        queueCI.queueCount       = 1;
        queueCI.pQueuePriorities = &priority;

        VkPhysicalDeviceSamplerYcbcrConversionFeatures ycbcrFeature{};
        ycbcrFeature.sType                  = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_SAMPLER_YCBCR_CONVERSION_FEATURES;
        ycbcrFeature.samplerYcbcrConversion = VK_TRUE;

        const char* deviceExtensions[] = {kAhbDeviceExtension};

        VkDeviceCreateInfo deviceCI{};
        deviceCI.sType                   = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO;
        deviceCI.pNext                   = &ycbcrFeature;
        deviceCI.queueCreateInfoCount    = 1;
        deviceCI.pQueueCreateInfos       = &queueCI;
        deviceCI.enabledExtensionCount   = 1;
        deviceCI.ppEnabledExtensionNames = deviceExtensions;
        vr = vkCreateDevice(physDev, &deviceCI, nullptr, &device);
        if (vr != VK_SUCCESS) {
            device = VK_NULL_HANDLE;
            *outError = "vulkan_create_device_failed:" + std::to_string(static_cast<int>(vr));
            Teardown();
            return false;
        }
        vkGetDeviceQueue(device, queueFamily, 0, &queue);

        VkCommandPoolCreateInfo poolCI{};
        poolCI.sType            = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO;
        poolCI.flags            = VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT;
        poolCI.queueFamilyIndex = queueFamily;
        vr = vkCreateCommandPool(device, &poolCI, nullptr, &commandPool);
        if (vr != VK_SUCCESS) {
            commandPool = VK_NULL_HANDLE;
            *outError = "vulkan_create_command_pool_failed:" + std::to_string(static_cast<int>(vr));
            Teardown();
            return false;
        }
        return true;
    }

    void Teardown() {
        if (device != VK_NULL_HANDLE) {
            teardownWaitIdleOk = vkDeviceWaitIdle(device) == VK_SUCCESS;
            if (commandPool != VK_NULL_HANDLE) {
                vkDestroyCommandPool(device, commandPool, nullptr);
                commandPool = VK_NULL_HANDLE;
            }
            vkDestroyDevice(device, nullptr);
            device = VK_NULL_HANDLE;
            queue  = VK_NULL_HANDLE;
        }
        if (instance != VK_NULL_HANDLE) {
            vkDestroyInstance(instance, nullptr);
            instance = VK_NULL_HANDLE;
        }
        physDev     = VK_NULL_HANDLE;
        queueFamily = UINT32_MAX;
    }

    bool AllHandlesNull() const {
        return instance == VK_NULL_HANDLE && physDev == VK_NULL_HANDLE &&
               device == VK_NULL_HANDLE && queue == VK_NULL_HANDLE &&
               commandPool == VK_NULL_HANDLE;
    }
};

// -- Scratch images / buffers (duplicated from android_phase3_multicam_
// dynamic_descriptor_spatial_vulkan_render_jni.cpp) --------------------------

struct ScratchImage {
    VkImage        image   = VK_NULL_HANDLE;
    VkDeviceMemory memory  = VK_NULL_HANDLE;
    VkImageView    view    = VK_NULL_HANDLE;
    VkSampler      sampler = VK_NULL_HANDLE;

    void Destroy(VkDevice device) {
        if (device == VK_NULL_HANDLE) return;
        if (sampler != VK_NULL_HANDLE) { vkDestroySampler(device, sampler, nullptr); sampler = VK_NULL_HANDLE; }
        if (view != VK_NULL_HANDLE)    { vkDestroyImageView(device, view, nullptr);  view = VK_NULL_HANDLE; }
        if (image != VK_NULL_HANDLE)   { vkDestroyImage(device, image, nullptr);     image = VK_NULL_HANDLE; }
        if (memory != VK_NULL_HANDLE)  { vkFreeMemory(device, memory, nullptr);      memory = VK_NULL_HANDLE; }
    }
    bool IsNull() const {
        return image == VK_NULL_HANDLE && memory == VK_NULL_HANDLE &&
               view == VK_NULL_HANDLE && sampler == VK_NULL_HANDLE;
    }
};

struct ScratchBuffer {
    VkBuffer       buffer   = VK_NULL_HANDLE;
    VkDeviceMemory memory   = VK_NULL_HANDLE;
    VkDeviceSize   size     = 0;
    void*          mapped   = nullptr;
    bool           coherent = false;

    void Destroy(VkDevice device) {
        if (device == VK_NULL_HANDLE) return;
        if (mapped != nullptr && memory != VK_NULL_HANDLE) { vkUnmapMemory(device, memory); mapped = nullptr; }
        if (buffer != VK_NULL_HANDLE) { vkDestroyBuffer(device, buffer, nullptr); buffer = VK_NULL_HANDLE; }
        if (memory != VK_NULL_HANDLE) { vkFreeMemory(device, memory, nullptr);    memory = VK_NULL_HANDLE; }
        size = 0;
    }
    bool IsNull() const {
        return buffer == VK_NULL_HANDLE && memory == VK_NULL_HANDLE && mapped == nullptr;
    }
};

bool CreateDeviceImage(const VulkanScratch& vk,
                       uint32_t width,
                       uint32_t height,
                       VkImageUsageFlags usage,
                       ScratchImage& out,
                       std::string* outError) {
    VkImageCreateInfo imgCI{};
    imgCI.sType         = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO;
    imgCI.imageType     = VK_IMAGE_TYPE_2D;
    imgCI.format        = kColorFormat;
    imgCI.extent        = {width, height, 1};
    imgCI.mipLevels     = 1;
    imgCI.arrayLayers   = 1;
    imgCI.samples       = VK_SAMPLE_COUNT_1_BIT;
    imgCI.tiling        = VK_IMAGE_TILING_OPTIMAL;
    imgCI.usage         = usage;
    imgCI.sharingMode   = VK_SHARING_MODE_EXCLUSIVE;
    imgCI.initialLayout = VK_IMAGE_LAYOUT_UNDEFINED;
    if (vkCreateImage(vk.device, &imgCI, nullptr, &out.image) != VK_SUCCESS) {
        out.image = VK_NULL_HANDLE;
        *outError = "scratch_image_create_failed";
        return false;
    }
    VkMemoryRequirements req{};
    vkGetImageMemoryRequirements(vk.device, out.image, &req);
    uint32_t typeIndex = FindMemoryType(vk.memProps, req.memoryTypeBits, VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT);
    if (typeIndex == UINT32_MAX) typeIndex = FindMemoryType(vk.memProps, req.memoryTypeBits, 0);
    if (typeIndex == UINT32_MAX) {
        *outError = "scratch_image_memory_type_not_found";
        return false;
    }
    VkMemoryAllocateInfo alloc{};
    alloc.sType           = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
    alloc.allocationSize  = req.size;
    alloc.memoryTypeIndex = typeIndex;
    if (vkAllocateMemory(vk.device, &alloc, nullptr, &out.memory) != VK_SUCCESS) {
        out.memory = VK_NULL_HANDLE;
        *outError = "scratch_image_memory_alloc_failed";
        return false;
    }
    if (vkBindImageMemory(vk.device, out.image, out.memory, 0) != VK_SUCCESS) {
        *outError = "scratch_image_bind_failed";
        return false;
    }
    VkImageViewCreateInfo viewCI{};
    viewCI.sType                       = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO;
    viewCI.image                       = out.image;
    viewCI.viewType                    = VK_IMAGE_VIEW_TYPE_2D;
    viewCI.format                      = kColorFormat;
    viewCI.subresourceRange.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
    viewCI.subresourceRange.levelCount = 1;
    viewCI.subresourceRange.layerCount = 1;
    if (vkCreateImageView(vk.device, &viewCI, nullptr, &out.view) != VK_SUCCESS) {
        out.view = VK_NULL_HANDLE;
        *outError = "scratch_image_view_create_failed";
        return false;
    }
    return true;
}

bool CreateHostBuffer(const VulkanScratch& vk,
                      VkDeviceSize size,
                      VkBufferUsageFlags usage,
                      ScratchBuffer& out,
                      std::string* outError) {
    VkBufferCreateInfo bufCI{};
    bufCI.sType       = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO;
    bufCI.size        = size;
    bufCI.usage       = usage;
    bufCI.sharingMode = VK_SHARING_MODE_EXCLUSIVE;
    if (vkCreateBuffer(vk.device, &bufCI, nullptr, &out.buffer) != VK_SUCCESS) {
        out.buffer = VK_NULL_HANDLE;
        *outError = "scratch_buffer_create_failed";
        return false;
    }
    out.size = size;
    VkMemoryRequirements req{};
    vkGetBufferMemoryRequirements(vk.device, out.buffer, &req);
    uint32_t typeIndex = FindMemoryType(vk.memProps, req.memoryTypeBits,
                                        VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT);
    out.coherent = typeIndex != UINT32_MAX;
    if (typeIndex == UINT32_MAX) {
        typeIndex = FindMemoryType(vk.memProps, req.memoryTypeBits, VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT);
    }
    if (typeIndex == UINT32_MAX) {
        *outError = "scratch_buffer_memory_type_not_found";
        return false;
    }
    VkMemoryAllocateInfo alloc{};
    alloc.sType           = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
    alloc.allocationSize  = req.size;
    alloc.memoryTypeIndex = typeIndex;
    if (vkAllocateMemory(vk.device, &alloc, nullptr, &out.memory) != VK_SUCCESS) {
        out.memory = VK_NULL_HANDLE;
        *outError = "scratch_buffer_memory_alloc_failed";
        return false;
    }
    if (vkBindBufferMemory(vk.device, out.buffer, out.memory, 0) != VK_SUCCESS) {
        *outError = "scratch_buffer_bind_failed";
        return false;
    }
    if (vkMapMemory(vk.device, out.memory, 0, VK_WHOLE_SIZE, 0, &out.mapped) != VK_SUCCESS) {
        out.mapped = nullptr;
        *outError = "scratch_buffer_map_failed";
        return false;
    }
    return true;
}

void InvalidateIfNeeded(const VulkanScratch& vk, const ScratchBuffer& buf) {
    if (buf.coherent) return;
    VkMappedMemoryRange range{};
    range.sType  = VK_STRUCTURE_TYPE_MAPPED_MEMORY_RANGE;
    range.memory = buf.memory;
    range.offset = 0;
    range.size   = VK_WHOLE_SIZE;
    vkInvalidateMappedMemoryRanges(vk.device, 1, &range);
}

void FlushIfNeeded(const VulkanScratch& vk, const ScratchBuffer& buf) {
    if (buf.coherent) return;
    VkMappedMemoryRange range{};
    range.sType  = VK_STRUCTURE_TYPE_MAPPED_MEMORY_RANGE;
    range.memory = buf.memory;
    range.offset = 0;
    range.size   = VK_WHOLE_SIZE;
    vkFlushMappedMemoryRanges(vk.device, 1, &range);
}

// One-shot command buffer helper: allocate, run `record`, submit, wait idle,
// free. Used both for uploading the synthetic solid texture and for the
// camera image's UNDEFINED -> SHADER_READ_ONLY_OPTIMAL layout transition.
bool RunOneShotCommands(const VulkanScratch& vk,
                        const std::function<void(VkCommandBuffer)>& record,
                        std::string* outError) {
    VkCommandBufferAllocateInfo cbAI{};
    cbAI.sType              = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO;
    cbAI.commandPool        = vk.commandPool;
    cbAI.level              = VK_COMMAND_BUFFER_LEVEL_PRIMARY;
    cbAI.commandBufferCount = 1;
    VkCommandBuffer cb = VK_NULL_HANDLE;
    if (vkAllocateCommandBuffers(vk.device, &cbAI, &cb) != VK_SUCCESS) {
        *outError = "one_shot_command_buffer_alloc_failed";
        return false;
    }
    VkCommandBufferBeginInfo begin{};
    begin.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
    begin.flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
    bool ok = vkBeginCommandBuffer(cb, &begin) == VK_SUCCESS;
    if (!ok) *outError = "one_shot_command_buffer_begin_failed";
    if (ok) {
        record(cb);
        ok = vkEndCommandBuffer(cb) == VK_SUCCESS;
        if (!ok) *outError = "one_shot_command_buffer_end_failed";
    }
    if (ok) {
        VkSubmitInfo submit{};
        submit.sType              = VK_STRUCTURE_TYPE_SUBMIT_INFO;
        submit.commandBufferCount = 1;
        submit.pCommandBuffers    = &cb;
        ok = vkQueueSubmit(vk.queue, 1, &submit, VK_NULL_HANDLE) == VK_SUCCESS;
        if (!ok) *outError = "one_shot_submit_failed";
    }
    vkQueueWaitIdle(vk.queue);
    vkFreeCommandBuffers(vk.device, vk.commandPool, 1, &cb);
    return ok;
}

bool UploadSampledImage(const VulkanScratch& vk,
                        ScratchImage& img,
                        const uint8_t* rgba,
                        uint32_t width,
                        uint32_t height,
                        std::string* outError) {
    const VkDeviceSize bytes = static_cast<VkDeviceSize>(width) * height * 4;
    ScratchBuffer staging;
    if (!CreateHostBuffer(vk, bytes, VK_BUFFER_USAGE_TRANSFER_SRC_BIT, staging, outError)) {
        return false;
    }
    std::memcpy(staging.mapped, rgba, static_cast<size_t>(bytes));
    FlushIfNeeded(vk, staging);

    const bool ok = RunOneShotCommands(vk, [&](VkCommandBuffer cb) {
        VkImageMemoryBarrier toTransfer{};
        toTransfer.sType                       = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER;
        toTransfer.srcAccessMask               = 0;
        toTransfer.dstAccessMask               = VK_ACCESS_TRANSFER_WRITE_BIT;
        toTransfer.oldLayout                   = VK_IMAGE_LAYOUT_UNDEFINED;
        toTransfer.newLayout                   = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;
        toTransfer.srcQueueFamilyIndex         = VK_QUEUE_FAMILY_IGNORED;
        toTransfer.dstQueueFamilyIndex         = VK_QUEUE_FAMILY_IGNORED;
        toTransfer.image                       = img.image;
        toTransfer.subresourceRange.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
        toTransfer.subresourceRange.levelCount = 1;
        toTransfer.subresourceRange.layerCount = 1;
        vkCmdPipelineBarrier(cb, VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT,
                             0, 0, nullptr, 0, nullptr, 1, &toTransfer);

        VkBufferImageCopy region{};
        region.imageSubresource.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
        region.imageSubresource.layerCount = 1;
        region.imageExtent                 = {width, height, 1};
        vkCmdCopyBufferToImage(cb, staging.buffer, img.image, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &region);

        VkImageMemoryBarrier toSampled = toTransfer;
        toSampled.srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT;
        toSampled.dstAccessMask = VK_ACCESS_SHADER_READ_BIT;
        toSampled.oldLayout     = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;
        toSampled.newLayout     = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
        vkCmdPipelineBarrier(cb, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT,
                             0, 0, nullptr, 0, nullptr, 1, &toSampled);
    }, outError);
    staging.Destroy(vk.device);
    if (!ok) return false;

    VkSamplerCreateInfo samplerCI{};
    samplerCI.sType         = VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO;
    samplerCI.magFilter     = VK_FILTER_NEAREST;
    samplerCI.minFilter     = VK_FILTER_NEAREST;
    samplerCI.mipmapMode    = VK_SAMPLER_MIPMAP_MODE_NEAREST;
    samplerCI.addressModeU  = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE;
    samplerCI.addressModeV  = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE;
    samplerCI.addressModeW  = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE;
    samplerCI.maxAnisotropy = 1.0f;
    samplerCI.borderColor   = VK_BORDER_COLOR_FLOAT_TRANSPARENT_BLACK;
    if (vkCreateSampler(vk.device, &samplerCI, nullptr, &img.sampler) != VK_SUCCESS) {
        img.sampler = VK_NULL_HANDLE;
        *outError = "scratch_sampler_create_failed";
        return false;
    }
    return true;
}

bool CreateSolidTexture(const VulkanScratch& vk, Rgb c, ScratchImage& out, std::string* outError) {
    uint8_t data[2 * 2 * 4];
    for (int i = 0; i < 4; ++i) {
        data[i * 4 + 0] = c.r;
        data[i * 4 + 1] = c.g;
        data[i * 4 + 2] = c.b;
        data[i * 4 + 3] = 255;
    }
    if (!CreateDeviceImage(vk, 2, 2, VK_IMAGE_USAGE_SAMPLED_BIT | VK_IMAGE_USAGE_TRANSFER_DST_BIT, out, outError)) {
        return false;
    }
    return UploadSampledImage(vk, out, data, 2, 2, outError);
}

VulkanMultiCamSpatialLayerImage LayerOf(VkImageView view, VkSampler sampler) {
    VulkanMultiCamSpatialLayerImage layer;
    layer.imageView = view;
    layer.sampler   = sampler;
    return layer;
}

// -- Layout normalized -> pixel rect conversion (top-left origin, Y-down,
// same independent-edge-rounding rule as every Vulkan spatial sibling) ------

bool ConvertNormalizedRectToPixelRect(const NormalizedRect& rect,
                                      uint32_t canvasWidth,
                                      uint32_t canvasHeight,
                                      VulkanSpatialViewportRectPx* out,
                                      std::string* outError) {
    if (!std::isfinite(rect.x) || !std::isfinite(rect.y) ||
        !std::isfinite(rect.width) || !std::isfinite(rect.height)) {
        *outError = "single_cam_ingest_vulkan_rect_non_finite";
        return false;
    }
    if (rect.x < 0.0 || rect.y < 0.0 || rect.width <= 0.0 || rect.height <= 0.0 ||
        rect.x + rect.width > 1.0 + 1e-9 || rect.y + rect.height > 1.0 + 1e-9) {
        *outError = "single_cam_ingest_vulkan_rect_out_of_canvas";
        return false;
    }
    const double canvasW = static_cast<double>(canvasWidth);
    const double canvasH = static_cast<double>(canvasHeight);
    const long left   = std::lround(rect.x * canvasW);
    const long right  = std::lround(std::min(1.0, rect.x + rect.width) * canvasW);
    const long top    = std::lround(rect.y * canvasH);
    const long bottom = std::lround(std::min(1.0, rect.y + rect.height) * canvasH);
    if (right <= left || bottom <= top) {
        *outError = "single_cam_ingest_vulkan_rect_nonpositive_after_round";
        return false;
    }
    out->x      = static_cast<int32_t>(left);
    out->yTop   = static_cast<int32_t>(top);
    out->width  = static_cast<uint32_t>(right - left);
    out->height = static_cast<uint32_t>(bottom - top);
    return true;
}

std::string RectString(const VulkanSpatialViewportRectPx& r) {
    char buf[64];
    std::snprintf(buf, sizeof(buf), "%d,%d,%u,%u", r.x, r.yTop, r.width, r.height);
    return buf;
}

// -- Derived (never hardcoded) structural probe point (duplicated from the
// GLES single-cam-ingest sibling): a point inside the camera's (full-canvas)
// primary rect that is provably outside the synthetic secondary rect. -------

struct NormalizedPoint {
    double x;
    double y;
};

bool NormalizedPointInsideRect(double x, double y, const NormalizedRect& r) {
    return x >= r.x && x <= r.x + r.width && y >= r.y && y <= r.y + r.height;
}

NormalizedPoint RectCenter(const NormalizedRect& r) {
    return {r.x + r.width / 2.0, r.y + r.height / 2.0};
}

NormalizedPoint ComputePointInsideButOutside(const NormalizedRect& containerRect,
                                              const NormalizedRect& avoidRect) {
    const NormalizedPoint center = RectCenter(containerRect);
    if (!NormalizedPointInsideRect(center.x, center.y, avoidRect)) {
        return center;
    }
    constexpr double kInset = 0.05;
    const NormalizedPoint candidates[4] = {
        {kInset, kInset},
        {1.0 - kInset, kInset},
        {kInset, 1.0 - kInset},
        {1.0 - kInset, 1.0 - kInset},
    };
    for (const auto& candidate : candidates) {
        if (!NormalizedPointInsideRect(candidate.x, candidate.y, avoidRect)) {
            return candidate;
        }
    }
    return center;
}

// -- Pixel readback + ownership gating (top-left canvas coords, row 0 == top) -

const uint8_t* PixelAt(const std::vector<uint8_t>& px, uint32_t canvasWidth, uint32_t x, uint32_t yTop) {
    return &px[(static_cast<size_t>(yTop) * canvasWidth + x) * 4];
}

bool ColorNear(const uint8_t* p, Rgb expected) {
    return std::abs(static_cast<int>(p[0]) - expected.r) <= kColorTolerance &&
           std::abs(static_cast<int>(p[1]) - expected.g) <= kColorTolerance &&
           std::abs(static_cast<int>(p[2]) - expected.b) <= kColorTolerance;
}

bool RectContains(const VulkanSpatialViewportRectPx& r, uint32_t x, uint32_t y) {
    return static_cast<int64_t>(x) >= r.x &&
           static_cast<int64_t>(x) < static_cast<int64_t>(r.x) + r.width &&
           static_cast<int64_t>(y) >= r.yTop &&
           static_cast<int64_t>(y) < static_cast<int64_t>(r.yTop) + r.height;
}

std::string RgbString(const uint8_t* p) {
    char buf[32];
    std::snprintf(buf, sizeof(buf), "%u,%u,%u", p[0], p[1], p[2]);
    return buf;
}

// Camera (primary) pixels are never color-gated -- their content is
// unconstrained. Only the synthetic secondary rect (must be blue) and any
// pixel outside both rects (must be the green clear sentinel -- unreachable
// in practice since the primary viewport is always the full canvas, but
// gated defensively for parity with every other Vulkan spatial diagnostic).
struct OwnershipMismatches {
    uint32_t blueRegion    = 0;
    uint32_t sentinelRegion = 0;
    uint32_t bluePixels    = 0;
    uint32_t cameraPixels  = 0;
    uint32_t sentinelPixels = 0;
    uint32_t total() const { return blueRegion + sentinelRegion; }
};

OwnershipMismatches GateOwnership(const std::vector<uint8_t>& px,
                                  uint32_t canvasWidth,
                                  uint32_t canvasHeight,
                                  const VulkanSpatialViewportRectPx& primaryRect,
                                  const VulkanSpatialViewportRectPx& secondaryRect) {
    OwnershipMismatches m;
    for (uint32_t y = 0; y < canvasHeight; ++y) {
        for (uint32_t x = 0; x < canvasWidth; ++x) {
            const uint8_t* p = PixelAt(px, canvasWidth, x, y);
            if (RectContains(secondaryRect, x, y)) {
                ++m.bluePixels;
                if (!ColorNear(p, kBlue)) ++m.blueRegion;
            } else if (RectContains(primaryRect, x, y)) {
                ++m.cameraPixels;
            } else {
                ++m.sentinelPixels;
                if (!ColorNear(p, kGreen)) ++m.sentinelRegion;
            }
        }
    }
    return m;
}

uint64_t Checksum(const std::vector<uint8_t>& px) {
    uint64_t sum = 0;
    for (const uint8_t b : px) sum += b;
    return sum;
}

// -- JSON helpers -------------------------------------------------------------

std::string JsonEscape(const std::string& in) {
    std::string out;
    out.reserve(in.size() + 8);
    for (const char c : in) {
        switch (c) {
            case '"':  out += "\\\""; break;
            case '\\': out += "\\\\"; break;
            case '\n': out += "\\n";  break;
            case '\r': out += "\\r";  break;
            case '\t': out += "\\t";  break;
            default:
                if (static_cast<unsigned char>(c) < 0x20) {
                    char buf[8];
                    std::snprintf(buf, sizeof(buf), "\\u%04x", static_cast<unsigned>(c));
                    out += buf;
                } else {
                    out += c;
                }
        }
    }
    return out;
}

const char* BoolStr(bool v) { return v ? "true" : "false"; }

class DetailsBuilder {
public:
    void Str(const char* key, const std::string& value) {
        Raw(key, "\"" + JsonEscape(value) + "\"");
    }
    void Bool(const char* key, bool value) { Raw(key, BoolStr(value)); }
    void U64(const char* key, uint64_t value) { Raw(key, std::to_string(value)); }
    std::string Json() const {
        std::string out = "{";
        for (size_t i = 0; i < entries_.size(); ++i) {
            if (i != 0) out += ",";
            out += entries_[i];
        }
        out += "}";
        return out;
    }

private:
    void Raw(const char* key, const std::string& rawValue) {
        entries_.push_back("\"" + JsonEscape(key) + "\":" + rawValue);
    }
    std::vector<std::string> entries_;
};

std::string VersionString(uint32_t v) {
    return std::to_string(VK_VERSION_MAJOR(v)) + "." + std::to_string(VK_VERSION_MINOR(v)) + "." +
           std::to_string(VK_VERSION_PATCH(v));
}

} // namespace

extern "C" JNIEXPORT jstring JNICALL
Java_com_connects_vanguard_1media_1engine_bridge_VanguardNativeBridge_runAndroidDagPhase3SingleCamIngestVulkanSpatialRenderSmoke(
    JNIEnv* env,
    jobject /* this */,
    jobject jCameraYuvBuffer,
    jint width,
    jint height,
    jstring layoutModeJ,
    jstring pipAnchorJ,
    jdouble pipCenterX,
    jdouble pipCenterY,
    jdouble pipWidthFraction,
    jdouble pipAspectRatio,
    jdouble pipMarginFraction,
    jstring splitDirectionJ,
    jdouble splitRatio) {

    std::string failureReason;
    auto fail = [&failureReason](const std::string& reason) {
        if (failureReason.empty()) {
            failureReason = reason;
        }
    };

    DetailsBuilder details;
    details.Str("proofBoundary", kProofBoundary);
    details.Str("syntheticLayerSource", "vulkan_scratch_image_not_ahardwarebuffer");
    details.U64("canvasWidth", width > 0 ? static_cast<uint64_t>(width) : 0);
    details.U64("canvasHeight", height > 0 ? static_cast<uint64_t>(height) : 0);

    bool descriptorParseOk = false;
    bool descriptorRejectedBeforeVulkanOk = false;
    bool vulkanSetupOk = false;
    bool cameraImportOk = false;
    bool syntheticImportOk = false;
    bool layoutConvertOk = false;
    bool renderReadbackOk = false;
    bool helperResourcesReleasedOk = false;
    bool diagnosticTeardownOk = false;
    bool vulkanUnsupported = false;
    bool cameraIngestUnsupported = false;
    bool vulkanScratchSetupAttempted = false;

    if (!jCameraYuvBuffer || width <= 0 || height <= 0) {
        fail("invalid_arguments");
        details.Bool("descriptorParseOk", false);
        details.Bool("descriptorRejectedBeforeVulkanOk", false);
        std::ostringstream oss;
        oss << "{\"pass\":false,\"status\":\"FAIL\",\"marker\":\"" << kFailMarker << "\","
            << "\"proofBoundary\":\"" << kProofBoundary << "\","
            << "\"failureReason\":\"" << JsonEscape(failureReason) << "\","
            << "\"vulkanUnsupported\":false,\"cameraIngestUnsupported\":false,"
            << "\"descriptorParseOk\":false,\"descriptorRejectedBeforeVulkanOk\":false,"
            << "\"vulkanSetupOk\":false,\"cameraImportOk\":false,\"syntheticImportOk\":false,"
            << "\"layoutConvertOk\":false,\"renderReadbackOk\":false,"
            << "\"helperResourcesReleasedOk\":false,\"diagnosticTeardownOk\":false,"
            << "\"allNativeLanesPass\":false,\"nativeAllLanesPass\":false,"
            << "\"details\":" << details.Json() << "}";
        return env->NewStringUTF(oss.str().c_str());
    }

    const std::string layoutModeRaw = JStringToStdString(env, layoutModeJ);
    const std::string pipAnchorRaw = JStringToStdString(env, pipAnchorJ);
    const std::string splitDirectionRaw = JStringToStdString(env, splitDirectionJ);
    details.Str("layoutModeRaw", layoutModeRaw);
    details.Str("pipAnchorRaw", pipAnchorRaw);
    details.Str("splitDirectionRaw", splitDirectionRaw);

    // -- Strict descriptor resolution -- runs first, lexically before any
    // AHardwareBuffer/Vulkan side effect below, so an unrecognized string's
    // own rejection can be proven to happen with zero native side effects.
    const ResolvedDescriptor resolved =
        ResolveDescriptorStrict(layoutModeRaw, pipAnchorRaw, splitDirectionRaw);
    descriptorParseOk = resolved.ok;
    details.Bool("descriptorParseOk", descriptorParseOk);
    details.Str("layoutModeResolved", descriptorParseOk ? LayoutModeName(resolved.mode) : "");
    details.Str("pipAnchorResolved", descriptorParseOk ? AnchorName(resolved.anchor) : "");
    details.Str("splitDirectionResolved", descriptorParseOk ? SplitDirectionName(resolved.direction) : "");
    details.Str("rejectionReason", resolved.rejectionReason);
    if (!descriptorParseOk) {
        fail("descriptor_rejected:" + resolved.rejectionReason);
    }

    VulkanScratch vk;
    std::unique_ptr<VulkanHardwareBufferImports> ahbImports;
    HardwareBufferHandle cameraHandle = kInvalidHardwareBufferHandle;
    ScratchImage solidBlue, colorTarget;
    ScratchBuffer readback;
    AHardwareBuffer* ahbCamera = nullptr;

    if (descriptorParseOk) {
        vulkanScratchSetupAttempted = true;
        std::string setupError;
        vulkanSetupOk = vk.Setup(&setupError, &vulkanUnsupported);
        details.Bool("vulkanSetupOk", vulkanSetupOk);
        if (!vulkanSetupOk) {
            fail((vulkanUnsupported ? "vulkan_unsupported:" : "vulkan_setup_failed:") + setupError);
            details.Str("vulkanSetupError", setupError);
        } else {
            details.Str("deviceName", vk.deviceName);
            details.U64("deviceType", vk.deviceType);
            details.Str("apiVersion", VersionString(vk.apiVersion));
            details.U64("driverVersion", vk.driverVersion);
            details.U64("queueFamilyIndex", vk.queueFamily);
        }
    }

    descriptorRejectedBeforeVulkanOk = !descriptorParseOk && !vulkanScratchSetupAttempted;
    details.Bool("descriptorRejectedBeforeVulkanOk", descriptorRejectedBeforeVulkanOk);
    if (!vulkanScratchSetupAttempted) {
        details.Str("vulkanSetupState", "not_run");
        details.Str("cameraImportState", "not_run");
    }

    if (vulkanSetupOk) {
        ahbImports = std::make_unique<VulkanHardwareBufferImports>();
        const bool ahbHelperInitOk =
            ahbImports->initialize(static_cast<void*>(vk.device), static_cast<void*>(vk.physDev));
        details.Bool("ahbHelperInitOk", ahbHelperInitOk);

        FnAHardwareBuffer_fromHardwareBuffer fromHardwareBufferFn = nullptr;
        if (ahbHelperInitOk) {
            fromHardwareBufferFn = ResolveFromHardwareBufferFn();
        }
        details.Bool("fromHardwareBufferSymbolResolved", fromHardwareBufferFn != nullptr);

        if (!ahbHelperInitOk) {
            cameraIngestUnsupported = true;
            fail("ahb_imports_init_failed");
        } else if (!fromHardwareBufferFn) {
            cameraIngestUnsupported = true;
            fail("hardware_buffer_symbols_unavailable");
        } else {
            ahbCamera = fromHardwareBufferFn(env, jCameraYuvBuffer);
            if (!ahbCamera) {
                cameraIngestUnsupported = true;
                fail("hardware_buffer_from_jobject_failed");
            } else {
                HardwareBufferDescriptor cameraDesc{};
                const HardwareBufferImportResult importRes =
                    ahbImports->importBuffer(ahbCamera, /*acquireFenceFd=*/-1, &cameraHandle, &cameraDesc);
                details.U64("cameraImportResultCode", static_cast<uint64_t>(importRes));
                if (importRes != HardwareBufferImportResult::kSuccess) {
                    cameraIngestUnsupported = true;
                    fail("yuv_ahb_import_unsupported_format");
                } else {
                    const VulkanHardwareBufferImage* camImage = ahbImports->getImage(cameraHandle);
                    const bool imageHandlesOk = camImage != nullptr &&
                        camImage->image != VK_NULL_HANDLE &&
                        camImage->imageView != VK_NULL_HANDLE &&
                        camImage->sampler != VK_NULL_HANDLE;
                    details.Bool("cameraImageHandlesOk", imageHandlesOk);
                    if (!imageHandlesOk) {
                        cameraIngestUnsupported = true;
                        fail("camera_import_image_handles_null");
                    } else {
                        std::string transitionError;
                        const bool transitionOk = RunOneShotCommands(vk, [&](VkCommandBuffer cb) {
                            camImage->recordLayoutTransition(
                                cb, VK_IMAGE_LAYOUT_UNDEFINED, VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
                                VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT, VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT,
                                0, VK_ACCESS_SHADER_READ_BIT);
                        }, &transitionError);
                        details.Bool("cameraLayoutTransitionOk", transitionOk);
                        if (!transitionOk) {
                            cameraIngestUnsupported = true;
                            fail("camera_layout_transition_failed:" + transitionError);
                        } else {
                            cameraImportOk = true;
                        }
                    }
                }
            }
        }
        details.Bool("cameraImportOk", cameraImportOk);
    }

    VulkanMultiCamSpatialCompositor compositor;

    if (cameraImportOk) {
        std::string err;
        syntheticImportOk =
            CreateSolidTexture(vk, kBlue, solidBlue, &err) &&
            CreateDeviceImage(vk, static_cast<uint32_t>(width), static_cast<uint32_t>(height),
                              VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | VK_IMAGE_USAGE_TRANSFER_SRC_BIT,
                              colorTarget, &err) &&
            CreateHostBuffer(vk, static_cast<VkDeviceSize>(width) * height * 4,
                             VK_BUFFER_USAGE_TRANSFER_DST_BIT, readback, &err);
        details.Bool("syntheticImportOk", syntheticImportOk);
        details.Bool("readbackMemoryCoherent", readback.coherent);
        if (!syntheticImportOk) {
            fail("synthetic_vulkan_resource_creation_failed:" + err);
            details.Str("syntheticResourceError", err);
        }
    } else if (vulkanSetupOk) {
        details.Str("syntheticImportState", "not_run");
    }

    if (syntheticImportOk) {
        const VulkanHardwareBufferImage* camImage = ahbImports->getImage(cameraHandle);
        MultiCamLayout layout{};
        layout.mode         = resolved.mode;
        layout.canvasWidth  = static_cast<double>(width);
        layout.canvasHeight = static_cast<double>(height);
        layout.pip.anchor          = resolved.anchor;
        layout.pip.centerX         = pipCenterX;
        layout.pip.centerY         = pipCenterY;
        layout.pip.normalizedWidth = pipWidthFraction;
        layout.pip.aspectRatio     = pipAspectRatio;
        layout.pip.marginFraction  = pipMarginFraction;
        layout.pip.cornerRadiusFractionOfCanvasWidth = 0.0;  // hard-set, never caller-supplied
        layout.pip.opacity         = 1.0;                    // hard-set, never caller-supplied
        layout.split.direction  = resolved.direction;
        layout.split.splitRatio = splitRatio;

        const MultiCamLayoutResult layoutResult = ComputeMultiCamLayout(layout);
        VulkanSpatialViewportRectPx primaryRect;
        VulkanSpatialViewportRectPx secondaryRect;
        std::string convertErr;
        layoutConvertOk =
            ConvertNormalizedRectToPixelRect(layoutResult.primaryViewport, width, height, &primaryRect, &convertErr) &&
            ConvertNormalizedRectToPixelRect(layoutResult.secondaryViewport, width, height, &secondaryRect, &convertErr);
        details.Bool("layoutConvertOk", layoutConvertOk);
        if (!layoutConvertOk) {
            fail("layout_rect_conversion_failed:" + convertErr);
            details.Str("layoutConvertError", convertErr);
            details.Str("renderReadbackState", "not_run");
        } else {
            details.Str("primaryRectPx", RectString(primaryRect));
            details.Str("secondaryRectPx", RectString(secondaryRect));

            VulkanMultiCamSpatialRenderTarget target;
            target.device                  = vk.device;
            target.queue                   = vk.queue;
            target.commandPool             = vk.commandPool;
            target.colorImage              = colorTarget.image;
            target.colorImageView          = colorTarget.view;
            target.colorFormat             = kColorFormat;
            target.readbackBuffer          = readback.buffer;
            target.readbackBufferSizeBytes = readback.size;
            target.extentWidth             = static_cast<uint32_t>(width);
            target.extentHeight            = static_cast<uint32_t>(height);
            target.clearColor = {{kGreen.r / 255.0f, kGreen.g / 255.0f, kGreen.b / 255.0f, 1.0f}};

            std::string renderErr;
            const bool renderOk = compositor.renderSpatialComposite(
                target, LayerOf(camImage->imageView, camImage->sampler), LayerOf(solidBlue.view, solidBlue.sampler),
                primaryRect, secondaryRect, &renderErr);

            if (renderOk) {
                InvalidateIfNeeded(vk, readback);
                std::vector<uint8_t> px(static_cast<size_t>(readback.size), 0);
                std::memcpy(px.data(), readback.mapped, static_cast<size_t>(readback.size));

                const OwnershipMismatches m = GateOwnership(
                    px, static_cast<uint32_t>(width), static_cast<uint32_t>(height), primaryRect, secondaryRect);
                details.U64("blueRegionPixels", m.bluePixels);
                details.U64("cameraRegionPixels", m.cameraPixels);
                details.U64("sentinelRegionPixels", m.sentinelPixels);
                details.U64("blueRegionMismatches", m.blueRegion);
                details.U64("sentinelRegionMismatches", m.sentinelRegion);
                details.Str("checksum", std::to_string(Checksum(px)));

                const NormalizedPoint cameraProbe =
                    ComputePointInsideButOutside(layoutResult.primaryViewport, layoutResult.secondaryViewport);
                long probeX = std::lround(cameraProbe.x * width);
                long probeY = std::lround(cameraProbe.y * height);
                probeX = std::min<long>(std::max<long>(probeX, 0), width - 1);
                probeY = std::min<long>(std::max<long>(probeY, 0), height - 1);
                const uint8_t* probePixel = PixelAt(px, static_cast<uint32_t>(width),
                                                    static_cast<uint32_t>(probeX), static_cast<uint32_t>(probeY));
                const bool cameraProbeAlphaOk = probePixel[3] >= 250;
                details.Str("probeCameraRegion", RgbString(probePixel));
                details.Bool("cameraProbeAlphaOk", cameraProbeAlphaOk);
                details.Str("probeSecondaryCenter",
                            RgbString(PixelAt(px, static_cast<uint32_t>(width),
                                              static_cast<uint32_t>(secondaryRect.x) + secondaryRect.width / 2,
                                              static_cast<uint32_t>(secondaryRect.yTop) + secondaryRect.height / 2)));

                renderReadbackOk = m.total() == 0 && cameraProbeAlphaOk;
                if (!renderReadbackOk) fail("pixel_ownership_or_structural_probe_mismatch");
            } else {
                fail("render_failed:" + renderErr);
                details.Str("renderError", renderErr);
            }
        }

        const uint64_t created  = compositor.temporaryObjectsCreated();
        const uint64_t released = compositor.temporaryObjectsReleased();
        details.U64("helperTemporaryObjectsCreated", created);
        details.U64("helperTemporaryObjectsReleased", released);
        helperResourcesReleasedOk = created > 0 && created == released;
        if (!helperResourcesReleasedOk) fail("helper_temporary_objects_not_released");
    } else if (vulkanSetupOk) {
        details.Str("layoutConvertState", "not_run");
        details.Str("renderReadbackState", "not_run");
    }

    // -- Teardown: every object this diagnostic created, in reverse order. --
    if (vk.device != VK_NULL_HANDLE) {
        vkDeviceWaitIdle(vk.device);
    }
    readback.Destroy(vk.device);
    colorTarget.Destroy(vk.device);
    solidBlue.Destroy(vk.device);
    bool cameraReleaseOk = true;
    if (ahbImports && cameraHandle != kInvalidHardwareBufferHandle) {
        int releaseFence = -1;
        cameraReleaseOk =
            ahbImports->releaseBuffer(cameraHandle, &releaseFence) == HardwareBufferImportResult::kSuccess;
        if (releaseFence >= 0) {
            close(releaseFence);
        }
    }
    if (ahbImports) {
        ahbImports->shutdown();
        ahbImports.reset();
    }
    const bool hadDevice = vk.device != VK_NULL_HANDLE;
    vk.Teardown();
    diagnosticTeardownOk = hadDevice && vk.teardownWaitIdleOk && vk.AllHandlesNull() &&
        readback.IsNull() && colorTarget.IsNull() && solidBlue.IsNull() && cameraReleaseOk;
    details.Bool("cameraReleaseOk", cameraReleaseOk);
    details.Bool("teardownWaitIdleOk", vk.teardownWaitIdleOk);
    details.Bool("teardownHandlesNull", vk.AllHandlesNull() && readback.IsNull() && colorTarget.IsNull() &&
                                        solidBlue.IsNull());
    if (vulkanScratchSetupAttempted && hadDevice && !diagnosticTeardownOk) fail("diagnostic_teardown_incomplete");
    if (!vulkanScratchSetupAttempted) {
        details.Str("diagnosticTeardownState", "not_run");
    }

    details.Bool("vulkanUnsupported", vulkanUnsupported);
    details.Bool("cameraIngestUnsupported", cameraIngestUnsupported);

    const bool allGatesPass =
        descriptorParseOk && vulkanSetupOk && cameraImportOk && syntheticImportOk &&
        layoutConvertOk && renderReadbackOk &&
        helperResourcesReleasedOk && diagnosticTeardownOk;

    const bool anyUnsupported = vulkanUnsupported || cameraIngestUnsupported;
    const char* status = allGatesPass ? "PASS" : (anyUnsupported ? "UNSUPPORTED" : "FAIL");

    std::ostringstream oss;
    oss << "{"
        << "\"pass\":" << BoolStr(allGatesPass) << ","
        << "\"status\":\"" << status << "\","
        << "\"marker\":\"" << (allGatesPass ? kPassMarker : kFailMarker) << "\","
        << "\"proofBoundary\":\"" << kProofBoundary << "\","
        << "\"failureReason\":\"" << JsonEscape(failureReason) << "\","
        << "\"vulkanUnsupported\":" << BoolStr(vulkanUnsupported) << ","
        << "\"cameraIngestUnsupported\":" << BoolStr(cameraIngestUnsupported) << ","
        << "\"descriptorParseOk\":" << BoolStr(descriptorParseOk) << ","
        << "\"descriptorRejectedBeforeVulkanOk\":" << BoolStr(descriptorRejectedBeforeVulkanOk) << ","
        << "\"vulkanSetupOk\":" << BoolStr(vulkanSetupOk) << ","
        << "\"cameraImportOk\":" << BoolStr(cameraImportOk) << ","
        << "\"syntheticImportOk\":" << BoolStr(syntheticImportOk) << ","
        << "\"layoutConvertOk\":" << BoolStr(layoutConvertOk) << ","
        << "\"renderReadbackOk\":" << BoolStr(renderReadbackOk) << ","
        << "\"helperResourcesReleasedOk\":" << BoolStr(helperResourcesReleasedOk) << ","
        << "\"diagnosticTeardownOk\":" << BoolStr(diagnosticTeardownOk) << ","
        << "\"helperTemporaryObjectsCreated\":" << compositor.temporaryObjectsCreated() << ","
        << "\"helperTemporaryObjectsReleased\":" << compositor.temporaryObjectsReleased() << ","
        << "\"allNativeLanesPass\":" << BoolStr(allGatesPass) << ","
        << "\"nativeAllLanesPass\":" << BoolStr(allGatesPass) << ","
        << "\"details\":" << details.Json()
        << "}";

    const std::string resultStr = oss.str();
    return env->NewStringUTF(resultStr.c_str());
}
