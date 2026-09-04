// P3-MULTICAM-NODE-VULKAN-DYNAMIC-DESCRIPTOR-SPATIAL-RENDER: proves that a
// caller-supplied Dart layout descriptor's primitive fields (layoutMode,
// pipAnchor, pipCenterX, pipCenterY, pipWidthFraction, pipAspectRatio,
// pipMarginFraction, splitDirection, splitRatio) drive native Vulkan
// spatial rendering via vanguard::compositors::ComputeMultiCamLayout(),
// mirroring android_phase3_multicam_spatial_vulkan_render_jni.cpp's
// synchronous offscreen/readback proof (temporary VkInstance/VkDevice/
// VkQueue/VkCommandPool, synthetic solid red/blue RGBA8 sampled images, a
// 64x64 offscreen color attachment, a green clear sentinel, and the private
// vanguard::render::VulkanMultiCamSpatialCompositor raster helper) while
// reusing android_phase3_multicam_dynamic_descriptor_spatial_render_jni.cpp's
// strict Dart-descriptor-string -> native MultiCam* enum resolution policy:
// an unrecognized layoutMode/pipAnchor/splitDirection string FAILS CLOSED
// with an explicit reason before any Vulkan object is created (not even
// VulkanScratch::Setup() runs), exactly like that GLES sibling fails closed
// before any AHardwareBuffer import or GLES work begins.
//
// One JSON-object diagnostic call per invocation, driven entirely by the
// nine primitive arguments Kotlin forwards from the caller's Dart
// descriptor map -- no hardcoded descriptor values live in this file:
//   1. Strict descriptor resolution: layoutMode/pipAnchor/splitDirection are
//      resolved against the exact accepted string sets. Any rejection
//      returns a fail-shaped JSON here, before VulkanScratch::Setup() or any
//      other Vulkan object/resource creation -- proven by the
//      descriptorRejectedBeforeVulkanOk gate and zero/not_run detail
//      entries.
//   2. A well-formed descriptor creates the temporary Vulkan scratch
//      context and synthetic solid red/blue sampled images, builds a
//      MultiCamLayout from the caller's primitives (cornerRadius/opacity
//      hard-set to 0.0/1.0 -- never caller-supplied), evaluates the
//      already-verified ComputeMultiCamLayout(), converts both normalized
//      viewports to Vulkan pixel rects, renders (red primary, blue
//      secondary), and gates every readback pixel against its expected
//      owner (blue secondary rect, red primary rect, green clear sentinel
//      elsewhere).
//
// Non-claim: two-texture layout raster + readback proof only, using the
// existing AOT passthrough SPIR-V (no new shaders). No GLES, no camera
// open, no OES / AHardwareBuffer / YUV import, no secondary opacity, no
// corner radius, no crop, no recording / export, no app / editor / product
// wiring.
//
// JNI entry point (matching VanguardNativeBridge.kt declaration):
//   runAndroidDagPhase3MultiCamDynamicDescriptorSpatialVulkanRenderSmoke(
//       layoutMode: String, pipAnchor: String, pipCenterX: Double,
//       pipCenterY: Double, pipWidthFraction: Double, pipAspectRatio: Double,
//       pipMarginFraction: Double, splitDirection: String,
//       splitRatio: Double) -> jstring (JSON)

#include <jni.h>

#include <vulkan/vulkan.h>

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <sstream>
#include <string>
#include <vector>

#include "vanguard/compositors/multi_cam_compositor_node.h"
#include "vulkan_multicam_spatial_compositor.h"

namespace {

using vanguard::compositors::ComputeMultiCamLayout;
using vanguard::compositors::MultiCamLayout;
using vanguard::compositors::MultiCamLayoutMode;
using vanguard::compositors::MultiCamLayoutResult;
using vanguard::compositors::MultiCamPiPAnchor;
using vanguard::compositors::MultiCamSplitDirection;
using vanguard::compositors::NormalizedRect;
using vanguard::render::VulkanMultiCamSpatialCompositor;
using vanguard::render::VulkanMultiCamSpatialLayerImage;
using vanguard::render::VulkanMultiCamSpatialRenderTarget;
using vanguard::render::VulkanSpatialViewportRectPx;

constexpr const char* kProofBoundary =
    "native_multicam_dynamic_descriptor_spatial_vulkan_render_readback_only_no_gles_no_camera_no_oes_"
    "no_ahb_no_opacity_no_corner_radius_no_recording_no_product";
constexpr const char* kPassMarker = "ANDROID_DAG_PHASE3_MULTICAM_DYNAMIC_DESCRIPTOR_SPATIAL_VULKAN_RENDER_PASS";
constexpr const char* kFailMarker = "ANDROID_DAG_PHASE3_MULTICAM_DYNAMIC_DESCRIPTOR_SPATIAL_VULKAN_RENDER_FAIL";

constexpr uint32_t kCanvasWidth    = 64;
constexpr uint32_t kCanvasHeight   = 64;
constexpr int      kColorTolerance = 8;
constexpr VkFormat kColorFormat    = VK_FORMAT_R8G8B8A8_UNORM;
constexpr VkDeviceSize kReadbackBytes =
    static_cast<VkDeviceSize>(kCanvasWidth) * kCanvasHeight * 4;

struct Rgb {
    uint8_t r;
    uint8_t g;
    uint8_t b;
};

constexpr Rgb kRed   = {255, 0, 0};   // primary layer
constexpr Rgb kBlue  = {0, 0, 255};   // secondary layer
constexpr Rgb kGreen = {0, 255, 0};   // clear sentinel: only where no layer draws

std::string JStringToStdString(JNIEnv* env, jstring value) {
    if (!value) return std::string();
    const char* chars = env->GetStringUTFChars(value, nullptr);
    if (!chars) return std::string();
    std::string result(chars);
    env->ReleaseStringUTFChars(value, chars);
    return result;
}

// -- Vulkan scratch context (owned entirely by this diagnostic) --------------
// Identical shape/behavior to android_phase3_multicam_spatial_vulkan_render_
// jni.cpp's own VulkanScratch: a private per-translation-unit copy, not a
// shared header, matching that file's own "private source" scoping note.

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

    bool Setup(std::string* outError, bool* outUnsupported) {
        *outUnsupported = false;
        VkApplicationInfo appInfo{};
        appInfo.sType              = VK_STRUCTURE_TYPE_APPLICATION_INFO;
        appInfo.pApplicationName   = "VanguardMultiCamDynamicDescriptorVulkanSmoke";
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

// -- Scratch images / buffers ------------------------------------------------

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

VulkanMultiCamSpatialLayerImage LayerOf(const ScratchImage& img) {
    VulkanMultiCamSpatialLayerImage layer;
    layer.imageView = img.view;
    layer.sampler   = img.sampler;
    return layer;
}

// -- Strict Dart-descriptor-string -> native MultiCam* enum resolution ------
// Reused verbatim policy from android_phase3_multicam_dynamic_descriptor_
// spatial_render_jni.cpp (private per-translation-unit copy, not a shared
// header): every resolver reports ok=false for any string outside the exact
// accepted set instead of silently substituting a default, since this route
// performs real GPU rendering that must never proceed on a silently-
// reinterpreted layout.

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

// Combines all three strict resolvers into one fail-closed descriptor
// resolution: the first unrecognized field short-circuits with its own
// reason string before the remaining fields are even inspected.
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

// -- Layout normalized -> pixel rect conversion ------------------------------
// Top-left-origin, Y-down convention (Vulkan framebuffer convention), same
// exact independent-edge-rounding rule as android_phase3_multicam_spatial_
// vulkan_render_jni.cpp's own converter.

bool ConvertNormalizedRectToPixelRect(const NormalizedRect& rect,
                                      VulkanSpatialViewportRectPx* out,
                                      std::string* outError) {
    if (!std::isfinite(rect.x) || !std::isfinite(rect.y) ||
        !std::isfinite(rect.width) || !std::isfinite(rect.height)) {
        *outError = "multicam_dynamic_descriptor_vulkan_rect_non_finite";
        return false;
    }
    if (rect.x < 0.0 || rect.y < 0.0 || rect.width <= 0.0 || rect.height <= 0.0 ||
        rect.x + rect.width > 1.0 + 1e-9 || rect.y + rect.height > 1.0 + 1e-9) {
        *outError = "multicam_dynamic_descriptor_vulkan_rect_out_of_canvas";
        return false;
    }
    const double canvasW = static_cast<double>(kCanvasWidth);
    const double canvasH = static_cast<double>(kCanvasHeight);
    const long left   = std::lround(rect.x * canvasW);
    const long right  = std::lround(std::min(1.0, rect.x + rect.width) * canvasW);
    const long top    = std::lround(rect.y * canvasH);
    const long bottom = std::lround(std::min(1.0, rect.y + rect.height) * canvasH);
    if (right <= left || bottom <= top) {
        *outError = "multicam_dynamic_descriptor_vulkan_rect_nonpositive_after_round";
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

// -- Pixel readback + ownership gating (top-left canvas coords, row 0 == top) -

const uint8_t* PixelAt(const std::vector<uint8_t>& px, uint32_t x, uint32_t yTop) {
    return &px[(static_cast<size_t>(yTop) * kCanvasWidth + x) * 4];
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

uint64_t Checksum(const std::vector<uint8_t>& px) {
    uint64_t sum = 0;
    for (const uint8_t b : px) sum += b;
    return sum;
}

std::string RgbString(const uint8_t* p) {
    char buf[32];
    std::snprintf(buf, sizeof(buf), "%u,%u,%u", p[0], p[1], p[2]);
    return buf;
}

struct OwnershipMismatches {
    uint32_t blueRegion  = 0;
    uint32_t redRegion   = 0;
    uint32_t greenRegion = 0;
    uint32_t bluePixels  = 0;
    uint32_t redPixels   = 0;
    uint32_t greenPixels = 0;
    uint32_t total() const { return blueRegion + redRegion + greenRegion; }
};

OwnershipMismatches GateOwnership(const std::vector<uint8_t>& px,
                                  const VulkanSpatialViewportRectPx& primaryRect,
                                  const VulkanSpatialViewportRectPx& secondaryRect) {
    OwnershipMismatches m;
    for (uint32_t y = 0; y < kCanvasHeight; ++y) {
        for (uint32_t x = 0; x < kCanvasWidth; ++x) {
            const uint8_t* p = PixelAt(px, x, y);
            if (RectContains(secondaryRect, x, y)) {
                ++m.bluePixels;
                if (!ColorNear(p, kBlue)) ++m.blueRegion;
            } else if (RectContains(primaryRect, x, y)) {
                ++m.redPixels;
                if (!ColorNear(p, kRed)) ++m.redRegion;
            } else {
                ++m.greenPixels;
                if (!ColorNear(p, kGreen)) ++m.greenRegion;
            }
        }
    }
    return m;
}

// -- JSON helpers ------------------------------------------------------------

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

struct RenderContext {
    const VulkanScratch* vk = nullptr;
    VulkanMultiCamSpatialCompositor* compositor = nullptr;
    VulkanMultiCamSpatialRenderTarget target;
    const ScratchBuffer* readback = nullptr;
    const ScratchImage* primaryImage = nullptr;
    const ScratchImage* secondaryImage = nullptr;
};

bool RenderAndRead(RenderContext& ctx,
                   const VulkanSpatialViewportRectPx& primaryRect,
                   const VulkanSpatialViewportRectPx& secondaryRect,
                   std::vector<uint8_t>& outPixels,
                   std::string* outError) {
    if (!ctx.compositor->renderSpatialComposite(ctx.target, LayerOf(*ctx.primaryImage),
                                                LayerOf(*ctx.secondaryImage), primaryRect,
                                                secondaryRect, outError)) {
        return false;
    }
    InvalidateIfNeeded(*ctx.vk, *ctx.readback);
    outPixels.assign(static_cast<size_t>(kReadbackBytes), 0);
    std::memcpy(outPixels.data(), ctx.readback->mapped, static_cast<size_t>(kReadbackBytes));
    return true;
}

std::string VersionString(uint32_t v) {
    return std::to_string(VK_VERSION_MAJOR(v)) + "." + std::to_string(VK_VERSION_MINOR(v)) + "." +
           std::to_string(VK_VERSION_PATCH(v));
}

} // namespace

extern "C" JNIEXPORT jstring JNICALL
Java_com_connects_vanguard_1media_1engine_bridge_VanguardNativeBridge_runAndroidDagPhase3MultiCamDynamicDescriptorSpatialVulkanRenderSmoke(
    JNIEnv* env,
    jobject /* this */,
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
    details.U64("canvasWidth", kCanvasWidth);
    details.U64("canvasHeight", kCanvasHeight);
    details.Str("shaderSource", "aot_passthrough_vert_frag_spv_no_new_shaders");
    details.Str("drawModel", "opaque_primary_rect_then_opaque_secondary_rect_paint_over");

    const std::string layoutModeRaw = JStringToStdString(env, layoutModeJ);
    const std::string pipAnchorRaw = JStringToStdString(env, pipAnchorJ);
    const std::string splitDirectionRaw = JStringToStdString(env, splitDirectionJ);
    details.Str("layoutModeRaw", layoutModeRaw);
    details.Str("pipAnchorRaw", pipAnchorRaw);
    details.Str("splitDirectionRaw", splitDirectionRaw);

    bool descriptorParseOk = false;
    bool descriptorRejectedBeforeVulkanOk = false;
    bool vulkanSetupOk = false;
    bool syntheticImportOk = false;
    bool layoutConvertOk = false;
    bool renderReadbackOk = false;
    bool helperResourcesReleasedOk = false;
    bool diagnosticTeardownOk = false;
    bool unsupported = false;
    bool vulkanScratchSetupAttempted = false;

    // -- Strict descriptor resolution -- runs first, lexically before any
    // Vulkan object is created below, so an unrecognized string's own
    // rejection can be proven to happen with zero Vulkan side effects.
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
    ScratchImage solidRed, solidBlue, colorTarget;
    ScratchBuffer readback;

    if (descriptorParseOk) {
        vulkanScratchSetupAttempted = true;
        std::string setupError;
        vulkanSetupOk = vk.Setup(&setupError, &unsupported);
        details.Bool("vulkanSetupOk", vulkanSetupOk);
        if (!vulkanSetupOk) {
            fail((unsupported ? "vulkan_unsupported:" : "vulkan_setup_failed:") + setupError);
            details.Str("vulkanSetupError", setupError);
        } else {
            details.Str("deviceName", vk.deviceName);
            details.U64("deviceType", vk.deviceType);
            details.Str("apiVersion", VersionString(vk.apiVersion));
            details.U64("driverVersion", vk.driverVersion);
            details.U64("queueFamilyIndex", vk.queueFamily);
        }
    }

    // -- Proof that a rejected descriptor never reached Vulkan work: only
    // true when the descriptor was rejected AND VulkanScratch::Setup() was
    // never even attempted.
    descriptorRejectedBeforeVulkanOk = !descriptorParseOk && !vulkanScratchSetupAttempted;
    details.Bool("descriptorRejectedBeforeVulkanOk", descriptorRejectedBeforeVulkanOk);
    if (!vulkanScratchSetupAttempted) {
        details.Str("vulkanSetupState", "not_run");
        details.U64("vulkanObjectsCreatedAtRejection", 0);
    }

    if (vulkanSetupOk) {
        std::string err;
        syntheticImportOk =
            CreateSolidTexture(vk, kRed, solidRed, &err) &&
            CreateSolidTexture(vk, kBlue, solidBlue, &err) &&
            CreateDeviceImage(vk, kCanvasWidth, kCanvasHeight,
                              VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | VK_IMAGE_USAGE_TRANSFER_SRC_BIT,
                              colorTarget, &err) &&
            CreateHostBuffer(vk, kReadbackBytes, VK_BUFFER_USAGE_TRANSFER_DST_BIT, readback, &err);
        details.Bool("syntheticImportOk", syntheticImportOk);
        details.Bool("readbackMemoryCoherent", readback.coherent);
        if (!syntheticImportOk) {
            fail("synthetic_vulkan_resource_creation_failed:" + err);
            details.Str("syntheticResourceError", err);
        }
    } else if (vulkanScratchSetupAttempted) {
        details.Str("syntheticImportState", "not_run");
    }

    VulkanMultiCamSpatialCompositor compositor;

    if (vulkanSetupOk && syntheticImportOk) {
        MultiCamLayout layout{};
        layout.mode         = resolved.mode;
        layout.canvasWidth  = static_cast<double>(kCanvasWidth);
        layout.canvasHeight = static_cast<double>(kCanvasHeight);
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
            ConvertNormalizedRectToPixelRect(layoutResult.primaryViewport, &primaryRect, &convertErr) &&
            ConvertNormalizedRectToPixelRect(layoutResult.secondaryViewport, &secondaryRect, &convertErr);
        details.Bool("layoutConvertOk", layoutConvertOk);
        if (!layoutConvertOk) {
            fail("layout_rect_conversion_failed:" + convertErr);
            details.Str("layoutConvertError", convertErr);
            details.Str("renderReadbackState", "not_run");
        } else {
            details.Str("primaryRectPx", RectString(primaryRect));
            details.Str("secondaryRectPx", RectString(secondaryRect));

            RenderContext ctx;
            ctx.vk             = &vk;
            ctx.compositor     = &compositor;
            ctx.readback       = &readback;
            ctx.primaryImage   = &solidRed;
            ctx.secondaryImage = &solidBlue;
            ctx.target.device                  = vk.device;
            ctx.target.queue                   = vk.queue;
            ctx.target.commandPool             = vk.commandPool;
            ctx.target.colorImage              = colorTarget.image;
            ctx.target.colorImageView          = colorTarget.view;
            ctx.target.colorFormat             = kColorFormat;
            ctx.target.readbackBuffer          = readback.buffer;
            ctx.target.readbackBufferSizeBytes = readback.size;
            ctx.target.extentWidth             = kCanvasWidth;
            ctx.target.extentHeight            = kCanvasHeight;
            ctx.target.clearColor = {{kGreen.r / 255.0f, kGreen.g / 255.0f, kGreen.b / 255.0f, 1.0f}};

            std::vector<uint8_t> px;
            std::string renderErr;
            if (RenderAndRead(ctx, primaryRect, secondaryRect, px, &renderErr)) {
                const OwnershipMismatches m = GateOwnership(px, primaryRect, secondaryRect);
                details.U64("blueRegionPixels", m.bluePixels);
                details.U64("redRegionPixels", m.redPixels);
                details.U64("greenRegionPixels", m.greenPixels);
                details.U64("blueRegionMismatches", m.blueRegion);
                details.U64("redRegionMismatches", m.redRegion);
                details.U64("greenRegionMismatches", m.greenRegion);
                details.Str("checksum", std::to_string(Checksum(px)));
                details.Str("probeSecondaryCenter",
                            RgbString(PixelAt(px,
                                              static_cast<uint32_t>(secondaryRect.x) + secondaryRect.width / 2,
                                              static_cast<uint32_t>(secondaryRect.yTop) + secondaryRect.height / 2)));
                details.Str("probeCanvasTl", RgbString(PixelAt(px, 0, 0)));
                details.Str("probeCanvasBr", RgbString(PixelAt(px, kCanvasWidth - 1, kCanvasHeight - 1)));
                renderReadbackOk = m.total() == 0;
                if (!renderReadbackOk) fail("pixel_ownership_mismatch");
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
    } else if (vulkanScratchSetupAttempted) {
        details.Str("layoutConvertState", "not_run");
        details.Str("renderReadbackState", "not_run");
    }

    // -- Teardown: every object this diagnostic created ---------------------
    if (vk.device != VK_NULL_HANDLE) {
        vkDeviceWaitIdle(vk.device);
    }
    readback.Destroy(vk.device);
    colorTarget.Destroy(vk.device);
    solidBlue.Destroy(vk.device);
    solidRed.Destroy(vk.device);
    const bool hadDevice = vk.device != VK_NULL_HANDLE;
    vk.Teardown();
    diagnosticTeardownOk = hadDevice && vk.teardownWaitIdleOk && vk.AllHandlesNull() &&
                           readback.IsNull() && colorTarget.IsNull() &&
                           solidRed.IsNull() && solidBlue.IsNull();
    details.Bool("teardownWaitIdleOk", vk.teardownWaitIdleOk);
    details.Bool("teardownHandlesNull", vk.AllHandlesNull() && readback.IsNull() && colorTarget.IsNull() &&
                                        solidRed.IsNull() && solidBlue.IsNull());
    if (hadDevice && !diagnosticTeardownOk) fail("diagnostic_teardown_incomplete");
    if (!vulkanScratchSetupAttempted) {
        details.Str("diagnosticTeardownState", "not_run");
    }

    const bool allGatesPass =
        descriptorParseOk && vulkanSetupOk && syntheticImportOk &&
        layoutConvertOk && renderReadbackOk &&
        helperResourcesReleasedOk && diagnosticTeardownOk;

    const char* status = allGatesPass ? "PASS" : (unsupported ? "UNSUPPORTED" : "FAIL");

    std::ostringstream oss;
    oss << "{"
        << "\"pass\":" << BoolStr(allGatesPass) << ","
        << "\"status\":\"" << status << "\","
        << "\"marker\":\"" << (allGatesPass ? kPassMarker : kFailMarker) << "\","
        << "\"proofBoundary\":\"" << kProofBoundary << "\","
        << "\"failureReason\":\"" << JsonEscape(failureReason) << "\","
        << "\"vulkanUnsupported\":" << BoolStr(unsupported) << ","
        << "\"descriptorParseOk\":" << BoolStr(descriptorParseOk) << ","
        << "\"descriptorRejectedBeforeVulkanOk\":" << BoolStr(descriptorRejectedBeforeVulkanOk) << ","
        << "\"vulkanSetupOk\":" << BoolStr(vulkanSetupOk) << ","
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
