// android_phase5_beauty_v2_vulkan_render_jni.cpp
// P5-BEAUTY-V2-VULKAN-RENDER: VulkanBeautyV2Compositor shader/raster + CPU
// reference parity diagnostic proof diagnostic JNI bridge.
//
// Android-only translation unit added via the CMake target_sources block.
// This is the composition root for the private
// vanguard::render::VulkanBeautyV2Compositor raster helper: it owns a
// temporary VkInstance/VkDevice/VkQueue/VkCommandPool, synthetic
// VK_FORMAT_R8G8B8A8_UNORM sampled source images (clamp-to-edge samplers), a
// 64x64 offscreen color attachment, and a host-visible readback buffer
// created solely for proof on the calling thread. It runs the
// None/Soft/Strong/Max intensity presets through the private Vulkan beauty
// helper (blur_h, blur_v, composite; fused highpass, adaptive smoothing
// gate, tone compression, midtone lift, detail add-back, alpha
// preservation), reads the pixels back from the readback buffer, compares
// against the pure CPU reference in
// android_phase5_beauty_v2_vulkan_render_probe.h/.cpp (which quantizes Pass
// 1/2 intermediates to 8-bit UNORM, mirroring the
// VK_FORMAT_R8G8B8A8_UNORM intermediate images), proves helper temporary
// object created == released, and destroys every Vulkan object it created
// before returning a single flat JSON string.
//
// Runtime support: Android guarantees libvulkan from API 24 but not a usable
// GPU driver, so vkCreateInstance failure, zero physical devices, no
// suitable graphics queue family, or a missing RGBA8 optimal-tiling feature
// set report status "UNSUPPORTED" with a fail-shaped payload instead of
// crashing.
//
// Non-claim: shader/raster + CPU-parity proof only. No MediaCodec decode, no
// AHardwareBuffer/external image import, no production export/playback
// route, no AndroidTimelineExportSession/AndroidEditorPlaybackCoordinator
// change, no production VulkanBackend mutation, no app/editor/product UI.
// Proof boundary:
// native_vulkan_beauty_v2_compositor_shader_raster_only_no_decode_no_export_no_product
//
// JNI entry point (matching VanguardNativeBridge.kt declaration):
//   runAndroidDagPhase5BeautyV2VulkanRenderSmoke -> jstring (JSON)

#include <jni.h>

#include <vulkan/vulkan.h>

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <limits>
#include <sstream>
#include <string>
#include <type_traits>
#include <vector>

#include "android_phase5_beauty_v2_vulkan_render_probe.h"
#include "vulkan_beauty_v2_compositor.h"

namespace {

using vanguard::render::ComputeVulkanBeautyV2ParametersFromIntensity;
using vanguard::render::ValidateVulkanBeautyV2Parameters;
using vanguard::render::VulkanBeautyV2Compositor;
using vanguard::render::VulkanBeautyV2Parameters;
using vanguard::render::VulkanBeautyV2RenderTarget;
using vanguard::render::VulkanBeautyV2SourceImage;
using vanguard_probe_beauty_v2_vulkan::CompareImages;
using vanguard_probe_beauty_v2_vulkan::ComputeCpuReference;
using vanguard_probe_beauty_v2_vulkan::ComputeLumaVariance;
using vanguard_probe_beauty_v2_vulkan::ComputeMeanLuma;
using vanguard_probe_beauty_v2_vulkan::kProbeHeight;
using vanguard_probe_beauty_v2_vulkan::kProbePixelCount;
using vanguard_probe_beauty_v2_vulkan::kProbeWidth;
using vanguard_probe_beauty_v2_vulkan::LumaStepDelta;
using vanguard_probe_beauty_v2_vulkan::MakeFlatProbe;
using vanguard_probe_beauty_v2_vulkan::MakeGradientProbe;
using vanguard_probe_beauty_v2_vulkan::MakeMidtoneProbe;
using vanguard_probe_beauty_v2_vulkan::MakeNoiseProbe;
using vanguard_probe_beauty_v2_vulkan::MakeStepEdgeProbe;
using vanguard_probe_beauty_v2_vulkan::ParityResult;
using vanguard_probe_beauty_v2_vulkan::ProbeImage;
using vanguard_probe_beauty_v2_vulkan::Rgba8;

constexpr const char* kProofBoundary =
    "native_vulkan_beauty_v2_compositor_shader_raster_only_no_decode_no_export_no_product";
constexpr const char* kPassMarker = "ANDROID_DAG_PHASE5_BEAUTY_V2_VULKAN_RENDER_PHYSICAL_SMOKE_PASS";
constexpr const char* kFailMarker = "ANDROID_DAG_PHASE5_BEAUTY_V2_VULKAN_RENDER_PHYSICAL_SMOKE_FAIL";

constexpr uint32_t kCanvasWidth  = static_cast<uint32_t>(kProbeWidth);
constexpr uint32_t kCanvasHeight = static_cast<uint32_t>(kProbeHeight);
constexpr VkFormat kColorFormat  = VK_FORMAT_R8G8B8A8_UNORM;
constexpr VkDeviceSize kReadbackBytes =
    static_cast<VkDeviceSize>(kCanvasWidth) * kCanvasHeight * 4;

constexpr const char* kErrInvalidDimensions = "vulkan_beauty_v2_invalid_dimensions";
constexpr const char* kErrInvalidImage      = "vulkan_beauty_v2_invalid_image";
constexpr const char* kErrInvalidIntensity  = "vulkan_beauty_v2_invalid_intensity";
constexpr const char* kErrInvalidParameters = "vulkan_beauty_v2_invalid_parameters";

static_assert(sizeof(Rgba8) == 4, "Rgba8 must be a tightly packed 4-byte RGBA8 pixel");

// Struct parity: the native parameter struct must mirror the frozen
// field-for-field list (name, type, default) already verified for
// GlesBeautyV2Parameters, without this translation unit including
// gles_beauty_v2_compositor.h (vanguard_render_vulkan and its diagnostics
// must not depend on GLES). Checked at compile time; the runtime lane
// re-reports the result alongside the preset ramp table verification.
static_assert(std::is_same<decltype(VulkanBeautyV2Parameters::radius), int32_t>::value, "radius");
static_assert(std::is_same<decltype(VulkanBeautyV2Parameters::sigma), float>::value, "sigma");
static_assert(std::is_same<decltype(VulkanBeautyV2Parameters::rangeSigma), float>::value, "rangeSigma");
static_assert(std::is_same<decltype(VulkanBeautyV2Parameters::smoothStrength), float>::value, "smoothStrength");
static_assert(std::is_same<decltype(VulkanBeautyV2Parameters::sharpenStrength), float>::value, "sharpenStrength");
static_assert(std::is_same<decltype(VulkanBeautyV2Parameters::theta), float>::value, "theta");
static_assert(std::is_same<decltype(VulkanBeautyV2Parameters::detailDamping), float>::value, "detailDamping");
static_assert(std::is_same<decltype(VulkanBeautyV2Parameters::toneStrength), float>::value, "toneStrength");
static_assert(std::is_same<decltype(VulkanBeautyV2Parameters::midtoneLift), float>::value, "midtoneLift");
static_assert(std::is_standard_layout<VulkanBeautyV2Parameters>::value, "standard layout");
constexpr bool kStructParityCompileTimeOk = true;

// ── Vulkan scratch context (owned entirely by this diagnostic) ──────────────

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

    // Returns false with *outUnsupported == true when Vulkan is structurally
    // unavailable on this device (no crash), or *outUnsupported == false for
    // a genuine failure.
    bool Setup(std::string* outError, bool* outUnsupported) {
        *outUnsupported = false;
        VkApplicationInfo appInfo{};
        appInfo.sType              = VK_STRUCTURE_TYPE_APPLICATION_INFO;
        appInfo.pApplicationName   = "VanguardBeautyV2VulkanSmoke";
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
            *outError = "vulkan_no_suitable_graphics_device";
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

        VkDeviceCreateInfo deviceCI{};
        deviceCI.sType                = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO;
        deviceCI.queueCreateInfoCount = 1;
        deviceCI.pQueueCreateInfos    = &queueCI;
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
        poolCI.flags            = VK_COMMAND_POOL_CREATE_TRANSIENT_BIT;
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

    // Destroys pool -> device -> instance. Safe to call repeatedly.
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

// ── Scratch images / buffers ────────────────────────────────────────────────

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
    viewCI.sType                           = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO;
    viewCI.image                           = out.image;
    viewCI.viewType                        = VK_IMAGE_VIEW_TYPE_2D;
    viewCI.format                          = kColorFormat;
    viewCI.subresourceRange.aspectMask     = VK_IMAGE_ASPECT_COLOR_BIT;
    viewCI.subresourceRange.levelCount     = 1;
    viewCI.subresourceRange.layerCount     = 1;
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

void FlushIfNeeded(const VulkanScratch& vk, const ScratchBuffer& buf) {
    if (buf.coherent) return;
    VkMappedMemoryRange range{};
    range.sType  = VK_STRUCTURE_TYPE_MAPPED_MEMORY_RANGE;
    range.memory = buf.memory;
    range.offset = 0;
    range.size   = VK_WHOLE_SIZE;
    vkFlushMappedMemoryRanges(vk.device, 1, &range);
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

// Uploads tightly packed RGBA8 rows (row 0 == top) into `img` through a
// temporary staging buffer and one-time command buffer, leaving the image in
// SHADER_READ_ONLY_OPTIMAL, then creates its NEAREST / CLAMP_TO_EDGE
// sampler: the frozen contract's "clamp-to-edge samplers" requirement.
bool UploadSampledImage(const VulkanScratch& vk,
                        ScratchImage& img,
                        const uint8_t* rgba,
                        uint32_t width,
                        uint32_t height,
                        std::string* outError) {
    const VkDeviceSize bytes = static_cast<VkDeviceSize>(width) * height * 4;
    ScratchBuffer staging;
    bool ok = CreateHostBuffer(vk, bytes, VK_BUFFER_USAGE_TRANSFER_SRC_BIT, staging, outError);
    VkCommandBuffer cb = VK_NULL_HANDLE;
    if (ok) {
        std::memcpy(staging.mapped, rgba, static_cast<size_t>(bytes));
        FlushIfNeeded(vk, staging);

        VkCommandBufferAllocateInfo cbAI{};
        cbAI.sType              = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO;
        cbAI.commandPool        = vk.commandPool;
        cbAI.level              = VK_COMMAND_BUFFER_LEVEL_PRIMARY;
        cbAI.commandBufferCount = 1;
        if (vkAllocateCommandBuffers(vk.device, &cbAI, &cb) != VK_SUCCESS) {
            cb = VK_NULL_HANDLE;
            *outError = "upload_command_buffer_alloc_failed";
            ok = false;
        }
    }
    if (ok) {
        VkCommandBufferBeginInfo begin{};
        begin.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
        begin.flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
        ok = vkBeginCommandBuffer(cb, &begin) == VK_SUCCESS;
        if (!ok) *outError = "upload_command_buffer_begin_failed";
    }
    if (ok) {
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

        ok = vkEndCommandBuffer(cb) == VK_SUCCESS;
        if (!ok) *outError = "upload_command_buffer_end_failed";
    }
    if (ok) {
        VkSubmitInfo submit{};
        submit.sType              = VK_STRUCTURE_TYPE_SUBMIT_INFO;
        submit.commandBufferCount = 1;
        submit.pCommandBuffers    = &cb;
        ok = vkQueueSubmit(vk.queue, 1, &submit, VK_NULL_HANDLE) == VK_SUCCESS;
        if (!ok) *outError = "upload_submit_failed";
    }
    // Drain before releasing the staging buffer / command buffer on every path.
    vkQueueWaitIdle(vk.queue);
    if (cb != VK_NULL_HANDLE) {
        vkFreeCommandBuffers(vk.device, vk.commandPool, 1, &cb);
    }
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
    if (vkCreateSampler(vk.device, &samplerCI, nullptr, &img.sampler) != VK_SUCCESS) {
        img.sampler = VK_NULL_HANDLE;
        *outError = "scratch_sampler_create_failed";
        return false;
    }
    return true;
}

// Creates a sampled source image (SAMPLED_BIT | TRANSFER_DST_BIT) and
// uploads `probe`'s pixels into it.
bool CreateProbeSourceImage(const VulkanScratch& vk, const ProbeImage& probe, ScratchImage& out,
                            std::string* outError) {
    if (!CreateDeviceImage(vk, kCanvasWidth, kCanvasHeight,
                           VK_IMAGE_USAGE_SAMPLED_BIT | VK_IMAGE_USAGE_TRANSFER_DST_BIT, out, outError)) {
        return false;
    }
    return UploadSampledImage(vk, out, reinterpret_cast<const uint8_t*>(probe.data()),
                              kCanvasWidth, kCanvasHeight, outError);
}

void ReadBackProbe(const VulkanScratch& vk, const ScratchBuffer& buf, ProbeImage& outPixels) {
    InvalidateIfNeeded(vk, buf);
    outPixels.assign(static_cast<size_t>(kProbePixelCount), Rgba8{});
    std::memcpy(outPixels.data(), buf.mapped, static_cast<size_t>(kReadbackBytes));
}

// ── JSON helpers (self-contained per diagnostic-JNI precedent) ─────────────

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
    void Int(const char* key, int64_t value) { Raw(key, std::to_string(value)); }
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

// Expects DrawBeautyV2 to reject `source`/`params` against `target` with
// exactly `expectedError`.
bool ExpectRejected(VulkanBeautyV2Compositor& compositor,
                    const VulkanBeautyV2RenderTarget& target,
                    const VulkanBeautyV2SourceImage& source,
                    const VulkanBeautyV2Parameters& params,
                    const char* expectedError,
                    std::string* outActual) {
    std::string err;
    const bool drew = compositor.DrawBeautyV2(target, source, params, &err);
    *outActual = err;
    return !drew && err == expectedError;
}

std::string VersionString(uint32_t v) {
    return std::to_string(VK_VERSION_MAJOR(v)) + "." + std::to_string(VK_VERSION_MINOR(v)) + "." +
           std::to_string(VK_VERSION_PATCH(v));
}

} // namespace

extern "C" JNIEXPORT jstring JNICALL
Java_com_connects_vanguard_1media_1engine_bridge_VanguardNativeBridge_runAndroidDagPhase5BeautyV2VulkanRenderSmoke(
    JNIEnv* env,
    jobject /* this */) {

    std::string failureReason;
    auto fail = [&failureReason](const std::string& reason) {
        if (failureReason.empty()) {
            failureReason = reason;
        }
    };
    DetailsBuilder details;
    details.Str("proofBoundary", kProofBoundary);
    details.U64("canvasWidth", kCanvasWidth);
    details.U64("canvasHeight", kCanvasHeight);
    details.Str("shaderSource", "new_glsl_compiler_generated_spv_beauty_v2_blur_and_composite_reused_passthrough_vert");
    details.Str("samplerAddressMode", "clamp_to_edge_nearest");

    // Gate flags (all default false; every lane must set its own true).
    bool vulkanSetupOk = false;
    bool invalidImageRejectedOk = false;
    bool invalidDimensionsRejectedOk = false;
    bool invalidIntensityRejectedOk = false;
    bool invalidParameterRejectedOk = false;
    bool nonePresetFlatIdentityOk = false;
    bool nonePresetGradientMinimumRampOk = false;
    bool softPresetCpuParityOk = false;
    bool softPresetSmoothingObservedOk = false;
    bool strongPresetCpuParityOk = false;
    bool strongPresetEdgePreservationOk = false;
    bool maxPresetCpuParityOk = false;
    bool maxPresetBoundsOk = false;
    bool maxPresetMidtoneLiftOk = false;
    bool helperResourcesReleasedOk = false;
    bool diagnosticTeardownOk = false;
    bool structParityOk = false;
    bool canonical = false;
    bool unsupported = false;
    bool noVulkanObjectsAfterValidation = false;

    VulkanScratch vk;
    ScratchImage validImg, colorTarget;
    ScratchBuffer readback;

    {
        std::string setupError;
        vulkanSetupOk = vk.Setup(&setupError, &unsupported);
        details.Bool("vulkanDeviceInitOk", vulkanSetupOk);
        details.Bool("vulkanUnsupported", unsupported);
        if (!vulkanSetupOk) {
            fail((unsupported ? "vulkan_unsupported:" : "vulkan_setup_failed:") + setupError);
            details.Str("vulkanSetupError", setupError);
        }
    }

    if (vulkanSetupOk) {
        details.Str("deviceName", vk.deviceName);
        details.U64("deviceType", vk.deviceType);
        details.Str("apiVersion", VersionString(vk.apiVersion));
        details.U64("driverVersion", vk.driverVersion);
        details.U64("queueFamilyIndex", vk.queueFamily);

        std::string err;
        const ProbeImage flatValidProbe = MakeFlatProbe(128, 128, 128, 255);
        bool ok = CreateProbeSourceImage(vk, flatValidProbe, validImg, &err) &&
                  CreateDeviceImage(vk, kCanvasWidth, kCanvasHeight,
                                    VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | VK_IMAGE_USAGE_TRANSFER_SRC_BIT,
                                    colorTarget, &err) &&
                  CreateHostBuffer(vk, kReadbackBytes, VK_BUFFER_USAGE_TRANSFER_DST_BIT, readback, &err);
        details.Bool("syntheticResourcesOk", ok);
        details.Bool("readbackMemoryCoherent", readback.coherent);
        if (!ok) {
            vulkanSetupOk = false;
            fail("synthetic_vulkan_resource_creation_failed:" + err);
            details.Str("syntheticResourceError", err);
        }
    }

    VulkanBeautyV2Compositor compositor;
    VulkanBeautyV2RenderTarget target;
    VulkanBeautyV2SourceImage validSource;

    if (vulkanSetupOk) {
        target.physicalDevice          = vk.physDev;
        target.device                  = vk.device;
        target.queue                   = vk.queue;
        target.commandPool             = vk.commandPool;
        target.colorImage              = colorTarget.image;
        target.colorImageView          = colorTarget.view;
        target.colorFormat             = kColorFormat;
        target.readbackBuffer          = readback.buffer;
        target.readbackBufferSizeBytes = readback.size;
        target.extentWidth             = kCanvasWidth;
        target.extentHeight            = kCanvasHeight;

        validSource.imageView = validImg.view;
        validSource.sampler   = validImg.sampler;

        const VulkanBeautyV2Parameters defaultParams; // struct defaults; already valid.

        // ── Lane 1: fail-closed validation (no Vulkan work created) ────────
        {
            std::string err;

            {
                VulkanBeautyV2SourceImage nullView = validSource;
                nullView.imageView = VK_NULL_HANDLE;
                bool ok = ExpectRejected(compositor, target, nullView, defaultParams, kErrInvalidImage, &err);
                VulkanBeautyV2SourceImage nullSampler = validSource;
                nullSampler.sampler = VK_NULL_HANDLE;
                ok = ok && ExpectRejected(compositor, target, nullSampler, defaultParams, kErrInvalidImage, &err);
                invalidImageRejectedOk = ok;
                details.Str("invalidImageError", err);
            }

            {
                bool ok = true;
                VulkanBeautyV2RenderTarget t = target; t.physicalDevice = VK_NULL_HANDLE;
                ok = ok && ExpectRejected(compositor, t, validSource, defaultParams, kErrInvalidDimensions, &err);
                t = target; t.device = VK_NULL_HANDLE;
                ok = ok && ExpectRejected(compositor, t, validSource, defaultParams, kErrInvalidDimensions, &err);
                t = target; t.queue = VK_NULL_HANDLE;
                ok = ok && ExpectRejected(compositor, t, validSource, defaultParams, kErrInvalidDimensions, &err);
                t = target; t.commandPool = VK_NULL_HANDLE;
                ok = ok && ExpectRejected(compositor, t, validSource, defaultParams, kErrInvalidDimensions, &err);
                t = target; t.colorImage = VK_NULL_HANDLE;
                ok = ok && ExpectRejected(compositor, t, validSource, defaultParams, kErrInvalidDimensions, &err);
                t = target; t.colorImageView = VK_NULL_HANDLE;
                ok = ok && ExpectRejected(compositor, t, validSource, defaultParams, kErrInvalidDimensions, &err);
                t = target; t.colorFormat = VK_FORMAT_R8G8B8A8_SRGB;
                ok = ok && ExpectRejected(compositor, t, validSource, defaultParams, kErrInvalidDimensions, &err);
                t = target; t.readbackBuffer = VK_NULL_HANDLE;
                ok = ok && ExpectRejected(compositor, t, validSource, defaultParams, kErrInvalidDimensions, &err);
                t = target; t.readbackBufferSizeBytes = kReadbackBytes - 4;
                ok = ok && ExpectRejected(compositor, t, validSource, defaultParams, kErrInvalidDimensions, &err);
                t = target; t.extentWidth = 0;
                ok = ok && ExpectRejected(compositor, t, validSource, defaultParams, kErrInvalidDimensions, &err);
                t = target; t.extentHeight = 0;
                ok = ok && ExpectRejected(compositor, t, validSource, defaultParams, kErrInvalidDimensions, &err);
                invalidDimensionsRejectedOk = ok;
                details.Str("invalidDimensionsError", err);
            }

            {
                const float kNan = std::numeric_limits<float>::quiet_NaN();
                const float kInf = std::numeric_limits<float>::infinity();
                VulkanBeautyV2Parameters outParams;
                std::string intensityErr;
                bool intensityOk =
                    !ComputeVulkanBeautyV2ParametersFromIntensity(-0.01f, kCanvasWidth, kCanvasHeight, &outParams, &intensityErr) &&
                    intensityErr == kErrInvalidIntensity;
                intensityOk = intensityOk &&
                    !ComputeVulkanBeautyV2ParametersFromIntensity(1.01f, kCanvasWidth, kCanvasHeight, &outParams, &intensityErr) &&
                    intensityErr == kErrInvalidIntensity;
                intensityOk = intensityOk &&
                    !ComputeVulkanBeautyV2ParametersFromIntensity(kNan, kCanvasWidth, kCanvasHeight, &outParams, &intensityErr) &&
                    intensityErr == kErrInvalidIntensity;
                intensityOk = intensityOk &&
                    !ComputeVulkanBeautyV2ParametersFromIntensity(kInf, kCanvasWidth, kCanvasHeight, &outParams, &intensityErr) &&
                    intensityErr == kErrInvalidIntensity;
                details.Str("invalidIntensityError", intensityErr);
                invalidIntensityRejectedOk = intensityOk;
            }

            {
                const float kNan = std::numeric_limits<float>::quiet_NaN();
                std::string paramErr;
                VulkanBeautyV2Parameters badRadius = defaultParams;
                badRadius.radius = 0;
                bool paramOk = !ValidateVulkanBeautyV2Parameters(badRadius, kCanvasWidth, kCanvasHeight, &paramErr) &&
                               paramErr == kErrInvalidParameters;
                VulkanBeautyV2Parameters badSigma = defaultParams;
                badSigma.sigma = kNan;
                paramOk = paramOk &&
                    !ValidateVulkanBeautyV2Parameters(badSigma, kCanvasWidth, kCanvasHeight, &paramErr) &&
                    paramErr == kErrInvalidParameters;
                VulkanBeautyV2Parameters badRangeSigma = defaultParams;
                badRangeSigma.rangeSigma = 0.0f;
                paramOk = paramOk &&
                    !ValidateVulkanBeautyV2Parameters(badRangeSigma, kCanvasWidth, kCanvasHeight, &paramErr) &&
                    paramErr == kErrInvalidParameters;
                VulkanBeautyV2Parameters badSmooth = defaultParams;
                badSmooth.smoothStrength = -0.1f;
                paramOk = paramOk &&
                    !ValidateVulkanBeautyV2Parameters(badSmooth, kCanvasWidth, kCanvasHeight, &paramErr) &&
                    paramErr == kErrInvalidParameters;
                std::string drawParamErr;
                paramOk = paramOk &&
                    ExpectRejected(compositor, target, validSource, badRadius, kErrInvalidParameters, &drawParamErr);
                details.Str("invalidParameterError", drawParamErr.empty() ? paramErr : drawParamErr);
                invalidParameterRejectedOk = paramOk;
            }

            noVulkanObjectsAfterValidation =
                compositor.temporaryObjectsCreated() == 0 && compositor.temporaryObjectsReleased() == 0;
            details.Bool("noVulkanObjectsAfterValidation", noVulkanObjectsAfterValidation);
            if (!noVulkanObjectsAfterValidation) {
                invalidImageRejectedOk = false;
                invalidDimensionsRejectedOk = false;
                invalidIntensityRejectedOk = false;
                invalidParameterRejectedOk = false;
            }
            if (!invalidImageRejectedOk)      fail("invalid_image_not_rejected");
            if (!invalidDimensionsRejectedOk) fail("invalid_dimensions_not_rejected");
            if (!invalidIntensityRejectedOk)  fail("invalid_intensity_not_rejected");
            if (!invalidParameterRejectedOk)  fail("invalid_parameter_not_rejected");
        }

        // ── Lane 2: None minimum ramp (t=0.0) — full 3-pass pipeline, never ─
        // an early bypass.
        {
            VulkanBeautyV2Parameters noneParams;
            std::string rampErr;
            const bool rampOk =
                ComputeVulkanBeautyV2ParametersFromIntensity(0.0f, kCanvasWidth, kCanvasHeight, &noneParams, &rampErr);
            details.Bool("noneRampComputeOk", rampOk);
            details.Int("noneRadius", noneParams.radius);

            if (rampOk) {
                const ProbeImage flatProbe = MakeFlatProbe(210, 90, 60, 255);
                ScratchImage flatImg;
                std::string err;
                bool flatOk = CreateProbeSourceImage(vk, flatProbe, flatImg, &err);
                ProbeImage gpuFlat;
                if (flatOk) {
                    VulkanBeautyV2SourceImage src{flatImg.view, flatImg.sampler};
                    std::string drawErr;
                    flatOk = compositor.DrawBeautyV2(target, src, noneParams, &drawErr);
                    if (flatOk) {
                        ReadBackProbe(vk, readback, gpuFlat);
                    } else {
                        details.Str("noneFlatDrawError", drawErr);
                    }
                } else {
                    details.Str("noneFlatUploadError", err);
                }
                flatImg.Destroy(vk.device);
                if (flatOk) {
                    const ParityResult identity = CompareImages(gpuFlat, flatProbe);
                    nonePresetFlatIdentityOk = identity.maxDeltaR == 0 && identity.maxDeltaG == 0 &&
                                               identity.maxDeltaB == 0 && identity.maxDeltaA == 0;
                    details.Int("noneFlatMaxDelta", std::max({identity.maxDeltaR, identity.maxDeltaG,
                                                              identity.maxDeltaB, identity.maxDeltaA}));
                }

                const ProbeImage gradientProbe = MakeGradientProbe();
                ScratchImage gradImg;
                std::string gErr;
                bool gradOk = CreateProbeSourceImage(vk, gradientProbe, gradImg, &gErr);
                ProbeImage gpuGrad;
                if (gradOk) {
                    VulkanBeautyV2SourceImage src{gradImg.view, gradImg.sampler};
                    std::string drawErr;
                    gradOk = compositor.DrawBeautyV2(target, src, noneParams, &drawErr);
                    if (gradOk) {
                        ReadBackProbe(vk, readback, gpuGrad);
                    } else {
                        details.Str("noneGradientDrawError", drawErr);
                    }
                } else {
                    details.Str("noneGradientUploadError", gErr);
                }
                gradImg.Destroy(vk.device);
                if (gradOk) {
                    const ProbeImage cpuGrad = ComputeCpuReference(gradientProbe, noneParams);
                    const ParityResult parity = CompareImages(gpuGrad, cpuGrad);
                    nonePresetGradientMinimumRampOk = parity.withinTolerance;
                    details.Int("noneGradientMaxDelta", std::max({parity.maxDeltaR, parity.maxDeltaG,
                                                                  parity.maxDeltaB, parity.maxDeltaA}));
                    details.Str("noneGradientMae", std::to_string(parity.meanAbsoluteError));
                }
            }
            if (!nonePresetFlatIdentityOk) fail("none_preset_flat_identity_failed");
            if (!nonePresetGradientMinimumRampOk) fail("none_preset_gradient_minimum_ramp_failed");
        }

        // Shared preset-lane helper: ramp -> upload -> draw -> readback ->
        // CPU-reference parity compare. Returns false (leaving *outParity
        // default-constructed) if the ramp, upload, draw, or readback step
        // failed.
        auto runPresetParityLane = [&](float intensity, const ProbeImage& inputProbe,
                                       ProbeImage* outGpu, ParityResult* outParity,
                                       VulkanBeautyV2Parameters* outParams,
                                       const char* label) -> bool {
            std::string rampErr;
            if (!ComputeVulkanBeautyV2ParametersFromIntensity(intensity, kCanvasWidth, kCanvasHeight, outParams, &rampErr)) {
                details.Str((std::string(label) + "RampError").c_str(), rampErr);
                return false;
            }
            ScratchImage img;
            std::string uploadErr;
            if (!CreateProbeSourceImage(vk, inputProbe, img, &uploadErr)) {
                details.Str((std::string(label) + "UploadError").c_str(), uploadErr);
                img.Destroy(vk.device);
                return false;
            }
            VulkanBeautyV2SourceImage src{img.view, img.sampler};
            std::string drawErr;
            const bool drawOk = compositor.DrawBeautyV2(target, src, *outParams, &drawErr);
            if (drawOk) {
                ReadBackProbe(vk, readback, *outGpu);
            }
            img.Destroy(vk.device);
            if (!drawOk) {
                details.Str((std::string(label) + "DrawError").c_str(), drawErr);
                return false;
            }
            const ProbeImage cpuRef = ComputeCpuReference(inputProbe, *outParams);
            *outParity = CompareImages(*outGpu, cpuRef);
            details.Int((std::string(label) + "MaxDelta").c_str(),
                        std::max({outParity->maxDeltaR, outParity->maxDeltaG,
                                  outParity->maxDeltaB, outParity->maxDeltaA}));
            details.Str((std::string(label) + "Mae").c_str(), std::to_string(outParity->meanAbsoluteError));
            return true;
        };

        // ── Lane 3: Soft (t=0.5) CPU parity + smoothing telemetry ───────────
        {
            const ProbeImage noiseProbe = MakeNoiseProbe();
            ProbeImage gpuSoft;
            ParityResult softParity;
            VulkanBeautyV2Parameters softParams;
            const bool ran = runPresetParityLane(0.5f, noiseProbe, &gpuSoft, &softParity, &softParams, "soft");
            softPresetCpuParityOk = ran && softParity.withinTolerance;
            if (ran) {
                softPresetSmoothingObservedOk = ComputeLumaVariance(gpuSoft) < ComputeLumaVariance(noiseProbe);
            }
            details.Bool("softPresetSmoothingObservedOk", softPresetSmoothingObservedOk);
            if (!softPresetCpuParityOk) fail("soft_preset_cpu_parity_failed");
        }

        // ── Lane 4: Strong (t=0.75) CPU parity + edge-preservation telemetry ─
        {
            const ProbeImage stepProbe = MakeStepEdgeProbe();
            ProbeImage gpuStrong;
            ParityResult strongParity;
            VulkanBeautyV2Parameters strongParams;
            const bool ran = runPresetParityLane(0.75f, stepProbe, &gpuStrong, &strongParity, &strongParams, "strong");
            strongPresetCpuParityOk = ran && strongParity.withinTolerance;
            if (ran) {
                const int stepDelta =
                    LumaStepDelta(gpuStrong, kProbeWidth / 2 - 2, kProbeWidth / 2 + 1, kProbeHeight / 2);
                strongPresetEdgePreservationOk = stepDelta >= 100;
                details.Int("strongPresetStepDelta", stepDelta);
            }
            if (!strongPresetCpuParityOk) fail("strong_preset_cpu_parity_failed");
        }

        // ── Lane 5: Max (t=1.0) CPU parity + bounds + midtone-lift gates ────
        {
            const ProbeImage midtoneProbe = MakeMidtoneProbe();
            ProbeImage gpuMax;
            ParityResult maxParity;
            VulkanBeautyV2Parameters maxParams;
            const bool ran = runPresetParityLane(1.0f, midtoneProbe, &gpuMax, &maxParity, &maxParams, "max");
            maxPresetCpuParityOk = ran && maxParity.withinTolerance;
            if (ran) {
                bool boundsOk = true;
                for (const Rgba8& p : gpuMax) {
                    if (p.r > 255 || p.g > 255 || p.b > 255 || p.a > 255) {
                        boundsOk = false;
                        break;
                    }
                }
                maxPresetBoundsOk = boundsOk;
                const double lumaIn = ComputeMeanLuma(midtoneProbe);
                const double lumaOut = ComputeMeanLuma(gpuMax);
                maxPresetMidtoneLiftOk = lumaOut > lumaIn;
                details.Str("maxPresetMeanLumaIn", std::to_string(lumaIn));
                details.Str("maxPresetMeanLumaOut", std::to_string(lumaOut));
            }
            if (!maxPresetCpuParityOk)   fail("max_preset_cpu_parity_failed");
            if (!maxPresetBoundsOk)      fail("max_preset_bounds_failed");
            if (!maxPresetMidtoneLiftOk) fail("max_preset_midtone_lift_failed");
        }

        // ── Lane 6 (helper half): every temporary helper object released ───
        // Validation-only failures created nothing (checked above); every
        // render created objects and must have released exactly as many.
        {
            const uint64_t created  = compositor.temporaryObjectsCreated();
            const uint64_t released = compositor.temporaryObjectsReleased();
            details.U64("helperTemporaryObjectsCreated", created);
            details.U64("helperTemporaryObjectsReleased", released);
            helperResourcesReleasedOk = noVulkanObjectsAfterValidation && created > 0 && created == released;
            if (!helperResourcesReleasedOk) fail("helper_temporary_objects_not_released");
        }

        // ── Lane 7: struct parity + preset ramp table verification ─────────
        {
            auto near = [](float a, float b, float eps) { return std::fabs(a - b) <= eps; };
            struct Expected {
                float t; int32_t radius; float sigma; float rangeSigma; float smoothStrength;
                float theta; float sharpenStrength; float detailDamping; float toneStrength; float midtoneLift;
            };
            const Expected table[4] = {
                {0.00f, 1,  1.000f, 0.20f, 0.00f, 0.0200f, 0.35f, 1.000f, 0.000f, 0.000f},
                {0.50f, 7,  4.750f, 0.14f, 0.70f, 0.0350f, 0.25f, 0.750f, 0.150f, 0.030f},
                {0.75f, 9,  6.625f, 0.11f, 1.05f, 0.0425f, 0.20f, 0.625f, 0.225f, 0.045f},
                {1.00f, 12, 8.500f, 0.08f, 1.40f, 0.0500f, 0.15f, 0.500f, 0.300f, 0.060f},
            };
            bool tableOk = true;
            for (const Expected& e : table) {
                VulkanBeautyV2Parameters p;
                std::string rampErr;
                const bool ok =
                    ComputeVulkanBeautyV2ParametersFromIntensity(e.t, kCanvasWidth, kCanvasHeight, &p, &rampErr) &&
                    p.radius == e.radius && near(p.sigma, e.sigma, 1e-3f) && near(p.rangeSigma, e.rangeSigma, 1e-3f) &&
                    near(p.smoothStrength, e.smoothStrength, 1e-3f) && near(p.theta, e.theta, 1e-3f) &&
                    near(p.sharpenStrength, e.sharpenStrength, 1e-3f) && near(p.detailDamping, e.detailDamping, 1e-3f) &&
                    near(p.toneStrength, e.toneStrength, 1e-3f) && near(p.midtoneLift, e.midtoneLift, 1e-3f) &&
                    ValidateVulkanBeautyV2Parameters(p, kCanvasWidth, kCanvasHeight, &rampErr);
                tableOk = tableOk && ok;
            }
            details.Bool("presetRampTableOk", tableOk);
            details.U64("paramsStructSizeBytes", sizeof(VulkanBeautyV2Parameters));
            details.Str("paramsStructFields",
                        "radius,sigma,rangeSigma,smoothStrength,sharpenStrength,theta,detailDamping,toneStrength,midtoneLift");

            structParityOk = kStructParityCompileTimeOk && tableOk;
            if (!structParityOk) fail("struct_parity_failed");
        }
    }

    // ── Teardown: every object this diagnostic created ─────────────────────
    if (vk.device != VK_NULL_HANDLE) {
        vkDeviceWaitIdle(vk.device);
    }
    readback.Destroy(vk.device);
    colorTarget.Destroy(vk.device);
    validImg.Destroy(vk.device);
    const bool hadDevice = vk.device != VK_NULL_HANDLE;
    vk.Teardown();
    diagnosticTeardownOk = hadDevice && vk.teardownWaitIdleOk && vk.AllHandlesNull() &&
                           readback.IsNull() && colorTarget.IsNull() && validImg.IsNull();
    details.Bool("teardownWaitIdleOk", vk.teardownWaitIdleOk);
    details.Bool("teardownHandlesNull", vk.AllHandlesNull() && readback.IsNull() && colorTarget.IsNull());
    if (hadDevice && !diagnosticTeardownOk) fail("diagnostic_teardown_incomplete");

    // Primary gates exclude the telemetry-only softPresetSmoothingObservedOk
    // and strongPresetEdgePreservationOk booleans.
    const bool lanesPass =
        vulkanSetupOk &&
        invalidImageRejectedOk && invalidDimensionsRejectedOk &&
        invalidIntensityRejectedOk && invalidParameterRejectedOk &&
        nonePresetFlatIdentityOk && nonePresetGradientMinimumRampOk &&
        softPresetCpuParityOk && strongPresetCpuParityOk &&
        maxPresetCpuParityOk && maxPresetBoundsOk && maxPresetMidtoneLiftOk &&
        helperResourcesReleasedOk && diagnosticTeardownOk && structParityOk;
    // Canonical route: every lane ran through the private helper against the
    // diagnostic-owned Vulkan device/images with no lane skipped or
    // substituted.
    canonical = lanesPass && failureReason.empty();
    const bool allNativeLanesPass = lanesPass && canonical;

    const char* status = allNativeLanesPass ? "PASS" : (unsupported ? "UNSUPPORTED" : "FAIL");

    std::ostringstream oss;
    oss << "{"
        << "\"pass\":" << BoolStr(allNativeLanesPass) << ","
        << "\"status\":\"" << status << "\","
        << "\"marker\":\"" << (allNativeLanesPass ? kPassMarker : kFailMarker) << "\","
        << "\"proofBoundary\":\"" << kProofBoundary << "\","
        << "\"failureReason\":\"" << JsonEscape(failureReason) << "\","
        << "\"vulkanSetupOk\":" << BoolStr(vulkanSetupOk) << ","
        << "\"invalidImageRejectedOk\":" << BoolStr(invalidImageRejectedOk) << ","
        << "\"invalidDimensionsRejectedOk\":" << BoolStr(invalidDimensionsRejectedOk) << ","
        << "\"invalidIntensityRejectedOk\":" << BoolStr(invalidIntensityRejectedOk) << ","
        << "\"invalidParameterRejectedOk\":" << BoolStr(invalidParameterRejectedOk) << ","
        << "\"nonePresetFlatIdentityOk\":" << BoolStr(nonePresetFlatIdentityOk) << ","
        << "\"nonePresetGradientMinimumRampOk\":" << BoolStr(nonePresetGradientMinimumRampOk) << ","
        << "\"softPresetCpuParityOk\":" << BoolStr(softPresetCpuParityOk) << ","
        << "\"softPresetSmoothingObservedOk\":" << BoolStr(softPresetSmoothingObservedOk) << ","
        << "\"strongPresetCpuParityOk\":" << BoolStr(strongPresetCpuParityOk) << ","
        << "\"strongPresetEdgePreservationOk\":" << BoolStr(strongPresetEdgePreservationOk) << ","
        << "\"maxPresetCpuParityOk\":" << BoolStr(maxPresetCpuParityOk) << ","
        << "\"maxPresetBoundsOk\":" << BoolStr(maxPresetBoundsOk) << ","
        << "\"maxPresetMidtoneLiftOk\":" << BoolStr(maxPresetMidtoneLiftOk) << ","
        << "\"helperResourcesReleasedOk\":" << BoolStr(helperResourcesReleasedOk) << ","
        << "\"diagnosticTeardownOk\":" << BoolStr(diagnosticTeardownOk) << ","
        << "\"structParityOk\":" << BoolStr(structParityOk) << ","
        << "\"canonical\":" << BoolStr(canonical) << ","
        << "\"allNativeLanesPass\":" << BoolStr(allNativeLanesPass) << ","
        << "\"nativeAllLanesPass\":" << BoolStr(allNativeLanesPass) << ","
        << "\"details\":" << details.Json()
        << "}";

    const std::string resultStr = oss.str();
    return env->NewStringUTF(resultStr.c_str());
}
