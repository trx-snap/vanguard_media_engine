// P3-MULTICAM-NODE (sub-slice SPATIAL-VULKAN-RENDER): VulkanMultiCamSpatialCompositor
// two-texture spatial layout proof diagnostic JNI bridge.
//
// Android-only translation unit added via the CMake target_sources block.
// This is the composition root that bridges vanguard::compositors'
// ComputeMultiCamLayout() (compositor-owned pure PiP / split layout math,
// top-left Y-down normalized rects) to the private
// vanguard::render::VulkanMultiCamSpatialCompositor raster helper. Neither
// vanguard_render_vulkan nor the compositors library include each other; only
// this JNI translation unit links them together and converts the normalized
// layout viewports into top-left pixel rectangles.
//
// The diagnostic owns a temporary VkInstance / VkDevice / VkQueue /
// VkCommandPool, two synthetic 2x2 RGBA8 sampled images (solid red primary,
// solid blue secondary), a 64x64 RGBA8 offscreen color attachment and a
// host-visible readback buffer created solely for proof on the calling
// thread. It renders four layouts (top/bottom split, left/right split, PiP
// top-left, PiP free-floating) plus one partial-coverage case through the
// helper, reads the pixels back, gates every canvas pixel against the
// expected owner (blue inside the secondary rect, red inside the primary
// rect outside the secondary rect, green clear sentinel elsewhere), and
// destroys every Vulkan object it created before returning. Production
// VulkanBackend / export session state is never touched.
//
// Runtime support: Android guarantees libvulkan from API 24 but not a usable
// GPU driver, so vkCreateInstance failure, zero physical devices, no suitable
// graphics queue family, or a missing RGBA8 optimal-tiling feature set report
// status "UNSUPPORTED" with a fail-shaped payload instead of crashing.
//
// Non-claim: two-texture layout raster + readback proof only, using the
// existing AOT passthrough SPIR-V (no new shaders). No GLES, no camera open,
// no OES / AHardwareBuffer / YUV import, no secondary opacity, no corner
// radius, no crop, no recording / export, no app / editor / product wiring.
//
// JNI entry point (matching VanguardNativeBridge.kt declaration):
//   runAndroidDagPhase3MultiCamSpatialVulkanRenderSmoke -> jstring (JSON)

#include <jni.h>

#include <vulkan/vulkan.h>

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <limits>
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
    "native_multicam_spatial_vulkan_two_texture_layout_render_readback_only_no_gles_no_camera_no_oes_"
    "no_opacity_no_corner_radius_no_recording_no_product";
constexpr const char* kPassMarker = "ANDROID_DAG_PHASE3_MULTICAM_SPATIAL_VULKAN_RENDER_SMOKE_PASS";
constexpr const char* kFailMarker = "ANDROID_DAG_PHASE3_MULTICAM_SPATIAL_VULKAN_RENDER_SMOKE_FAIL";

constexpr uint32_t kCanvasWidth    = 64;
constexpr uint32_t kCanvasHeight   = 64;
constexpr int      kColorTolerance = 8;
constexpr VkFormat kColorFormat    = VK_FORMAT_R8G8B8A8_UNORM;
constexpr VkDeviceSize kReadbackBytes =
    static_cast<VkDeviceSize>(kCanvasWidth) * kCanvasHeight * 4;

constexpr const char* kErrInvalidArgument = "vulkan_multicam_spatial_compositor_invalid_argument";
constexpr const char* kErrInvalidRect     = "vulkan_multicam_spatial_compositor_invalid_rect";

struct Rgb {
    uint8_t r;
    uint8_t g;
    uint8_t b;
};

constexpr Rgb kRed   = {255, 0, 0};   // primary layer
constexpr Rgb kBlue  = {0, 0, 255};   // secondary layer
constexpr Rgb kGreen = {0, 255, 0};   // clear sentinel: only where no layer draws

// -- Vulkan scratch context (owned entirely by this diagnostic) --------------

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
        appInfo.pApplicationName   = "VanguardMultiCamSpatialVulkanSmoke";
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

// Uploads tightly packed RGBA8 rows (row 0 == top) into `img` through a
// temporary staging buffer and one-time command buffer, leaving the image in
// SHADER_READ_ONLY_OPTIMAL, then creates its NEAREST/CLAMP sampler.
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
    samplerCI.borderColor   = VK_BORDER_COLOR_FLOAT_TRANSPARENT_BLACK;
    if (vkCreateSampler(vk.device, &samplerCI, nullptr, &img.sampler) != VK_SUCCESS) {
        img.sampler = VK_NULL_HANDLE;
        *outError = "scratch_sampler_create_failed";
        return false;
    }
    return true;
}

// 2x2 solid-color RGBA8 sampled image.
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

// -- Layout construction + normalized -> pixel rect conversion ---------------

MultiCamLayout MakeSplitLayout(MultiCamSplitDirection direction, double splitRatio) {
    MultiCamLayout layout{};
    layout.mode         = MultiCamLayoutMode::kSplitScreen;
    layout.canvasWidth  = static_cast<double>(kCanvasWidth);
    layout.canvasHeight = static_cast<double>(kCanvasHeight);
    layout.pip.anchor          = MultiCamPiPAnchor::kFreeFloating;
    layout.pip.centerX         = 0.5;
    layout.pip.centerY         = 0.5;
    layout.pip.normalizedWidth = 0.35;
    layout.pip.aspectRatio     = 9.0 / 16.0;
    layout.pip.marginFraction  = 0.05;
    layout.pip.cornerRadiusFractionOfCanvasWidth = 0.0;
    layout.pip.opacity         = 1.0;
    layout.split.direction  = direction;
    layout.split.splitRatio = splitRatio;
    return layout;
}

MultiCamLayout MakePiPLayout(MultiCamPiPAnchor anchor,
                             double centerX,
                             double centerY,
                             double normalizedWidth,
                             double aspectRatio,
                             double marginFraction) {
    MultiCamLayout layout{};
    layout.mode         = MultiCamLayoutMode::kPictureInPicture;
    layout.canvasWidth  = static_cast<double>(kCanvasWidth);
    layout.canvasHeight = static_cast<double>(kCanvasHeight);
    layout.pip.anchor          = anchor;
    layout.pip.centerX         = centerX;
    layout.pip.centerY         = centerY;
    layout.pip.normalizedWidth = normalizedWidth;
    layout.pip.aspectRatio     = aspectRatio;
    layout.pip.marginFraction  = marginFraction;
    layout.pip.cornerRadiusFractionOfCanvasWidth = 0.0;
    layout.pip.opacity         = 1.0;
    layout.split.direction  = MultiCamSplitDirection::kTopBottom;
    layout.split.splitRatio = 0.5;
    return layout;
}

// Top-left normalized -> top-left pixel rect. Rounds each edge independently
// via std::lround and takes width/height as the difference of the rounded
// edges (same rule as the verified GLES spatial JNI), so adjacent split
// rects tile the canvas without a seam. Returns false for a non-finite,
// out-of-canvas, or non-positive rounded rect.
bool ConvertNormalizedRectToPixelRect(const NormalizedRect& rect,
                                      VulkanSpatialViewportRectPx* out,
                                      std::string* outError) {
    if (!std::isfinite(rect.x) || !std::isfinite(rect.y) ||
        !std::isfinite(rect.width) || !std::isfinite(rect.height)) {
        *outError = "multicam_spatial_rect_non_finite";
        return false;
    }
    if (rect.x < 0.0 || rect.y < 0.0 || rect.width <= 0.0 || rect.height <= 0.0 ||
        rect.x + rect.width > 1.0 + 1e-9 || rect.y + rect.height > 1.0 + 1e-9) {
        *outError = "multicam_spatial_rect_out_of_canvas";
        return false;
    }
    const double canvasW = static_cast<double>(kCanvasWidth);
    const double canvasH = static_cast<double>(kCanvasHeight);
    const long left   = std::lround(rect.x * canvasW);
    const long right  = std::lround(std::min(1.0, rect.x + rect.width) * canvasW);
    const long top    = std::lround(rect.y * canvasH);
    const long bottom = std::lround(std::min(1.0, rect.y + rect.height) * canvasH);
    if (right <= left || bottom <= top) {
        *outError = "multicam_spatial_rect_nonpositive_after_round";
        return false;
    }
    out->x      = static_cast<int32_t>(left);
    out->yTop   = static_cast<int32_t>(top);
    out->width  = static_cast<uint32_t>(right - left);
    out->height = static_cast<uint32_t>(bottom - top);
    return true;
}

bool RectEquals(const VulkanSpatialViewportRectPx& a, const VulkanSpatialViewportRectPx& b) {
    return a.x == b.x && a.yTop == b.yTop && a.width == b.width && a.height == b.height;
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

// Expected owner per canvas pixel: secondary rect -> blue, primary rect
// (outside secondary) -> red, otherwise the green clear sentinel.
struct OwnershipMismatches {
    uint32_t blueRegion  = 0; // pixels inside secondary rect that are not blue
    uint32_t redRegion   = 0; // pixels inside primary-only region that are not red
    uint32_t greenRegion = 0; // pixels outside both rects that are not green
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

// Everything one render needs: the diagnostic's target plus the helper.
struct RenderContext {
    const VulkanScratch* vk = nullptr;
    VulkanMultiCamSpatialCompositor* compositor = nullptr;
    VulkanMultiCamSpatialRenderTarget target;
    const ScratchBuffer* readback = nullptr;
    const ScratchImage* primaryImage = nullptr;
    const ScratchImage* secondaryImage = nullptr;
};

// Render (clear to green + primary + secondary) -> copy back -> read.
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

// Renders `primaryRect`/`secondaryRect` and gates full-canvas pixel ownership.
// Records per-region mismatch counts, probes and checksum under `<name>*`.
bool RunRectCase(RenderContext& ctx,
                 const VulkanSpatialViewportRectPx& primaryRect,
                 const VulkanSpatialViewportRectPx& secondaryRect,
                 const char* name,
                 DetailsBuilder& details,
                 std::string* outFailure) {
    const std::string keyBase = name;
    details.Str((keyBase + "PrimaryRectPx").c_str(), RectString(primaryRect));
    details.Str((keyBase + "SecondaryRectPx").c_str(), RectString(secondaryRect));
    std::vector<uint8_t> px;
    std::string err;
    if (!RenderAndRead(ctx, primaryRect, secondaryRect, px, &err)) {
        details.Str((keyBase + "Error").c_str(), err);
        *outFailure = keyBase + "_draw_failed:" + err;
        return false;
    }
    const OwnershipMismatches m = GateOwnership(px, primaryRect, secondaryRect);
    details.U64((keyBase + "BlueRegionPixels").c_str(), m.bluePixels);
    details.U64((keyBase + "RedRegionPixels").c_str(), m.redPixels);
    details.U64((keyBase + "GreenRegionPixels").c_str(), m.greenPixels);
    details.U64((keyBase + "BlueRegionMismatches").c_str(), m.blueRegion);
    details.U64((keyBase + "RedRegionMismatches").c_str(), m.redRegion);
    details.U64((keyBase + "GreenRegionMismatches").c_str(), m.greenRegion);
    details.Str((keyBase + "Checksum").c_str(), std::to_string(Checksum(px)));
    // Probes: secondary rect center, primary rect top-left texel, canvas corners.
    details.Str((keyBase + "ProbeSecondaryCenter").c_str(),
                RgbString(PixelAt(px,
                                  static_cast<uint32_t>(secondaryRect.x) + secondaryRect.width / 2,
                                  static_cast<uint32_t>(secondaryRect.yTop) + secondaryRect.height / 2)));
    details.Str((keyBase + "ProbePrimaryOrigin").c_str(),
                RgbString(PixelAt(px, static_cast<uint32_t>(primaryRect.x),
                                  static_cast<uint32_t>(primaryRect.yTop))));
    details.Str((keyBase + "ProbeCanvasTl").c_str(), RgbString(PixelAt(px, 0, 0)));
    details.Str((keyBase + "ProbeCanvasBr").c_str(),
                RgbString(PixelAt(px, kCanvasWidth - 1, kCanvasHeight - 1)));
    const bool ok = m.total() == 0;
    if (!ok) {
        *outFailure = keyBase + "_pixel_ownership_mismatch";
    }
    return ok;
}

// Evaluates ComputeMultiCamLayout(), converts both viewports to pixel rects,
// gates the converted rects against the hand-derived expectation (so the
// conversion itself is proven, not just echoed), then renders + gates pixels.
bool RunLayoutCase(RenderContext& ctx,
                   const MultiCamLayout& layout,
                   const VulkanSpatialViewportRectPx& expectedPrimary,
                   const VulkanSpatialViewportRectPx& expectedSecondary,
                   const char* name,
                   DetailsBuilder& details,
                   std::string* outFailure) {
    const std::string keyBase = name;
    const MultiCamLayoutResult result = ComputeMultiCamLayout(layout);
    VulkanSpatialViewportRectPx primaryRect;
    VulkanSpatialViewportRectPx secondaryRect;
    std::string err;
    if (!ConvertNormalizedRectToPixelRect(result.primaryViewport, &primaryRect, &err) ||
        !ConvertNormalizedRectToPixelRect(result.secondaryViewport, &secondaryRect, &err)) {
        details.Str((keyBase + "Error").c_str(), err);
        *outFailure = keyBase + "_rect_conversion_failed:" + err;
        return false;
    }
    details.Str((keyBase + "ExpectedPrimaryRectPx").c_str(), RectString(expectedPrimary));
    details.Str((keyBase + "ExpectedSecondaryRectPx").c_str(), RectString(expectedSecondary));
    if (!RectEquals(primaryRect, expectedPrimary) || !RectEquals(secondaryRect, expectedSecondary)) {
        details.Str((keyBase + "PrimaryRectPx").c_str(), RectString(primaryRect));
        details.Str((keyBase + "SecondaryRectPx").c_str(), RectString(secondaryRect));
        *outFailure = keyBase + "_layout_rect_mismatch";
        return false;
    }
    return RunRectCase(ctx, primaryRect, secondaryRect, name, details, outFailure);
}

std::string VersionString(uint32_t v) {
    return std::to_string(VK_VERSION_MAJOR(v)) + "." + std::to_string(VK_VERSION_MINOR(v)) + "." +
           std::to_string(VK_VERSION_PATCH(v));
}

} // namespace

extern "C" JNIEXPORT jstring JNICALL
Java_com_connects_vanguard_1media_1engine_bridge_VanguardNativeBridge_runAndroidDagPhase3MultiCamSpatialVulkanRenderSmoke(
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
    details.Int("colorTolerance", kColorTolerance);
    details.Str("shaderSource", "aot_passthrough_vert_frag_spv_no_new_shaders");
    details.Str("drawModel", "opaque_primary_rect_then_opaque_secondary_rect_paint_over");

    // Gate flags (all default false; every lane must set its own true).
    bool vulkanSetupOk = false;
    bool syntheticImportOk = false;
    bool invalidArgumentRejectedOk = false;
    bool invalidRectRejectedOk = false;
    bool topBottomSplitOk = false;
    bool leftRightSplitOk = false;
    bool pipTopLeftOk = false;
    bool pipFreeFloatingOk = false;
    bool partialCoverageSentinelOk = false;
    bool helperResourcesReleasedOk = false;
    bool diagnosticTeardownOk = false;
    bool unsupported = false;

    VulkanScratch vk;
    ScratchImage solidRed, solidBlue, colorTarget;
    ScratchBuffer readback;

    {
        std::string setupError;
        vulkanSetupOk = vk.Setup(&setupError, &unsupported);
        details.Bool("vulkanDeviceInitOk", vulkanSetupOk);
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
        syntheticImportOk =
            CreateSolidTexture(vk, kRed, solidRed, &err) &&
            CreateSolidTexture(vk, kBlue, solidBlue, &err) &&
            CreateDeviceImage(vk, kCanvasWidth, kCanvasHeight,
                              VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | VK_IMAGE_USAGE_TRANSFER_SRC_BIT,
                              colorTarget, &err) &&
            CreateHostBuffer(vk, kReadbackBytes, VK_BUFFER_USAGE_TRANSFER_DST_BIT, readback, &err);
        details.Bool("readbackMemoryCoherent", readback.coherent);
        if (!syntheticImportOk) {
            fail("synthetic_vulkan_resource_creation_failed:" + err);
            details.Str("syntheticResourceError", err);
        }
    }

    VulkanMultiCamSpatialCompositor compositor;
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

    const VulkanSpatialViewportRectPx fullCanvas{0, 0, kCanvasWidth, kCanvasHeight};

    if (vulkanSetupOk && syntheticImportOk) {
        // -- Lane 1: parameter validation (fail closed, no Vulkan objects) --
        const VulkanMultiCamSpatialLayerImage primaryLayer   = LayerOf(solidRed);
        const VulkanMultiCamSpatialLayerImage secondaryLayer = LayerOf(solidBlue);
        const VulkanSpatialViewportRectPx halfLeft{0, 0, kCanvasWidth / 2, kCanvasHeight};
        std::string err;

        VulkanMultiCamSpatialLayerImage nullView = primaryLayer;
        nullView.imageView = VK_NULL_HANDLE;
        bool ok = !compositor.renderSpatialComposite(ctx.target, nullView, secondaryLayer, fullCanvas, halfLeft, &err) &&
                  err == kErrInvalidArgument;
        VulkanMultiCamSpatialLayerImage nullSampler = secondaryLayer;
        nullSampler.sampler = VK_NULL_HANDLE;
        ok = ok && !compositor.renderSpatialComposite(ctx.target, primaryLayer, nullSampler, fullCanvas, halfLeft, &err) &&
             err == kErrInvalidArgument;
        VulkanMultiCamSpatialRenderTarget nullDevice = ctx.target;
        nullDevice.device = VK_NULL_HANDLE;
        ok = ok && !compositor.renderSpatialComposite(nullDevice, primaryLayer, secondaryLayer, fullCanvas, halfLeft, &err) &&
             err == kErrInvalidArgument;
        VulkanMultiCamSpatialRenderTarget nullQueue = ctx.target;
        nullQueue.queue = VK_NULL_HANDLE;
        ok = ok && !compositor.renderSpatialComposite(nullQueue, primaryLayer, secondaryLayer, fullCanvas, halfLeft, &err) &&
             err == kErrInvalidArgument;
        VulkanMultiCamSpatialRenderTarget nullPool = ctx.target;
        nullPool.commandPool = VK_NULL_HANDLE;
        ok = ok && !compositor.renderSpatialComposite(nullPool, primaryLayer, secondaryLayer, fullCanvas, halfLeft, &err) &&
             err == kErrInvalidArgument;
        VulkanMultiCamSpatialRenderTarget nullColor = ctx.target;
        nullColor.colorImageView = VK_NULL_HANDLE;
        ok = ok && !compositor.renderSpatialComposite(nullColor, primaryLayer, secondaryLayer, fullCanvas, halfLeft, &err) &&
             err == kErrInvalidArgument;
        VulkanMultiCamSpatialRenderTarget nullReadback = ctx.target;
        nullReadback.readbackBuffer = VK_NULL_HANDLE;
        ok = ok && !compositor.renderSpatialComposite(nullReadback, primaryLayer, secondaryLayer, fullCanvas, halfLeft, &err) &&
             err == kErrInvalidArgument;
        VulkanMultiCamSpatialRenderTarget zeroWidth = ctx.target;
        zeroWidth.extentWidth = 0;
        ok = ok && !compositor.renderSpatialComposite(zeroWidth, primaryLayer, secondaryLayer, fullCanvas, halfLeft, &err) &&
             err == kErrInvalidArgument;
        VulkanMultiCamSpatialRenderTarget zeroHeight = ctx.target;
        zeroHeight.extentHeight = 0;
        ok = ok && !compositor.renderSpatialComposite(zeroHeight, primaryLayer, secondaryLayer, fullCanvas, halfLeft, &err) &&
             err == kErrInvalidArgument;
        VulkanMultiCamSpatialRenderTarget smallReadback = ctx.target;
        smallReadback.readbackBufferSizeBytes = kReadbackBytes - 4;
        ok = ok && !compositor.renderSpatialComposite(smallReadback, primaryLayer, secondaryLayer, fullCanvas, halfLeft, &err) &&
             err == kErrInvalidArgument;
        invalidArgumentRejectedOk = ok;
        details.Str("invalidArgumentError", err);

        // Rect validation: zero extent, negative origin, right/bottom beyond
        // the canvas, and a 32-bit overflow candidate (x + width wraps to a
        // small value if computed in uint32).
        const VulkanSpatialViewportRectPx zeroWidthRect{0, 0, 0, 8};
        ok = !compositor.renderSpatialComposite(ctx.target, primaryLayer, secondaryLayer, fullCanvas, zeroWidthRect, &err) &&
             err == kErrInvalidRect;
        const VulkanSpatialViewportRectPx zeroHeightRect{0, 0, 8, 0};
        ok = ok && !compositor.renderSpatialComposite(ctx.target, primaryLayer, secondaryLayer, zeroHeightRect, fullCanvas, &err) &&
             err == kErrInvalidRect;
        const VulkanSpatialViewportRectPx negativeXRect{-1, 0, 8, 8};
        ok = ok && !compositor.renderSpatialComposite(ctx.target, primaryLayer, secondaryLayer, fullCanvas, negativeXRect, &err) &&
             err == kErrInvalidRect;
        const VulkanSpatialViewportRectPx negativeYRect{0, -1, 8, 8};
        ok = ok && !compositor.renderSpatialComposite(ctx.target, primaryLayer, secondaryLayer, fullCanvas, negativeYRect, &err) &&
             err == kErrInvalidRect;
        const VulkanSpatialViewportRectPx rightOverflowRect{static_cast<int32_t>(kCanvasWidth - 4), 0, 8, 8};
        ok = ok && !compositor.renderSpatialComposite(ctx.target, primaryLayer, secondaryLayer, fullCanvas, rightOverflowRect, &err) &&
             err == kErrInvalidRect;
        const VulkanSpatialViewportRectPx bottomOverflowRect{0, static_cast<int32_t>(kCanvasHeight - 4), 8, 8};
        ok = ok && !compositor.renderSpatialComposite(ctx.target, primaryLayer, secondaryLayer, bottomOverflowRect, fullCanvas, &err) &&
             err == kErrInvalidRect;
        const VulkanSpatialViewportRectPx wrapAroundRect{1, 0, std::numeric_limits<uint32_t>::max(), 8};
        ok = ok && !compositor.renderSpatialComposite(ctx.target, primaryLayer, secondaryLayer, fullCanvas, wrapAroundRect, &err) &&
             err == kErrInvalidRect;
        const VulkanSpatialViewportRectPx wrapAroundYRect{0, 1, 8, std::numeric_limits<uint32_t>::max()};
        ok = ok && !compositor.renderSpatialComposite(ctx.target, primaryLayer, secondaryLayer, wrapAroundYRect, fullCanvas, &err) &&
             err == kErrInvalidRect;
        invalidRectRejectedOk = ok;
        details.Str("invalidRectError", err);

        const bool noVulkanObjectsAfterValidation =
            compositor.temporaryObjectsCreated() == 0 && compositor.temporaryObjectsReleased() == 0;
        details.Bool("noVulkanObjectsAfterValidation", noVulkanObjectsAfterValidation);
        if (!noVulkanObjectsAfterValidation) {
            invalidArgumentRejectedOk = false;
            invalidRectRejectedOk = false;
        }
        if (!invalidArgumentRejectedOk) fail("invalid_argument_not_rejected");
        if (!invalidRectRejectedOk)     fail("invalid_rect_not_rejected");

        // -- Lane 2: layouts via ComputeMultiCamLayout() -------------------
        // Expected pixel rects derived by hand from the compositor math on a
        // 64x64 canvas with independent std::lround edge rounding:
        //   split 0.3      -> edge at lround(19.2) = 19
        //   PiP topLeft    -> width 0.3, aspect 1.0, margin 0.05:
        //                     x = y = 0.05 -> 3, x+w = y+h = 0.35 -> 22 (19 px)
        //   PiP freeFloat  -> center (0.7, 0.75), width 0.2, aspect 1.0:
        //                     x 0.6 -> 38, x+w 0.8 -> 51 (13 px);
        //                     y 0.65 -> 42, y+h 0.85 -> 54 (12 px)
        std::string laneFailure;
        topBottomSplitOk = RunLayoutCase(
            ctx, MakeSplitLayout(MultiCamSplitDirection::kTopBottom, 0.3),
            VulkanSpatialViewportRectPx{0, 0, kCanvasWidth, 19},
            VulkanSpatialViewportRectPx{0, 19, kCanvasWidth, kCanvasHeight - 19},
            "topBottomSplit", details, &laneFailure);
        if (!topBottomSplitOk) fail(laneFailure);

        leftRightSplitOk = RunLayoutCase(
            ctx, MakeSplitLayout(MultiCamSplitDirection::kLeftRight, 0.3),
            VulkanSpatialViewportRectPx{0, 0, 19, kCanvasHeight},
            VulkanSpatialViewportRectPx{19, 0, kCanvasWidth - 19, kCanvasHeight},
            "leftRightSplit", details, &laneFailure);
        if (!leftRightSplitOk) fail(laneFailure);

        pipTopLeftOk = RunLayoutCase(
            ctx, MakePiPLayout(MultiCamPiPAnchor::kTopLeft, 0.5, 0.5, 0.3, 1.0, 0.05),
            fullCanvas,
            VulkanSpatialViewportRectPx{3, 3, 19, 19},
            "pipTopLeft", details, &laneFailure);
        if (!pipTopLeftOk) fail(laneFailure);

        pipFreeFloatingOk = RunLayoutCase(
            ctx, MakePiPLayout(MultiCamPiPAnchor::kFreeFloating, 0.7, 0.75, 0.2, 1.0, 0.05),
            fullCanvas,
            VulkanSpatialViewportRectPx{38, 42, 13, 12},
            "pipFreeFloating", details, &laneFailure);
        if (!pipFreeFloatingOk) fail(laneFailure);

        // -- Lane 3: partial coverage -> green clear sentinel survives only -
        // outside both rects, proving the clear and that neither scissor
        // bleeds. Direct helper rects (no layout): two disjoint 16x16 tiles.
        partialCoverageSentinelOk = RunRectCase(
            ctx,
            VulkanSpatialViewportRectPx{4, 4, 16, 16},
            VulkanSpatialViewportRectPx{40, 40, 16, 16},
            "partialCoverage", details, &laneFailure);
        if (!partialCoverageSentinelOk) fail(laneFailure);

        // -- Lane 4 (helper half): every temporary helper object released ---
        const uint64_t created  = compositor.temporaryObjectsCreated();
        const uint64_t released = compositor.temporaryObjectsReleased();
        details.U64("helperTemporaryObjectsCreated", created);
        details.U64("helperTemporaryObjectsReleased", released);
        helperResourcesReleasedOk = noVulkanObjectsAfterValidation && created > 0 && created == released;
        if (!helperResourcesReleasedOk) fail("helper_temporary_objects_not_released");
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
    // Lane 4 (diagnostic half): device drained before destruction and every
    // owned handle nulled. Only meaningful when a device existed.
    diagnosticTeardownOk = hadDevice && vk.teardownWaitIdleOk && vk.AllHandlesNull() &&
                           readback.IsNull() && colorTarget.IsNull() &&
                           solidRed.IsNull() && solidBlue.IsNull();
    details.Bool("teardownWaitIdleOk", vk.teardownWaitIdleOk);
    details.Bool("teardownHandlesNull", vk.AllHandlesNull() && readback.IsNull() && colorTarget.IsNull() &&
                                        solidRed.IsNull() && solidBlue.IsNull());
    if (hadDevice && !diagnosticTeardownOk) fail("diagnostic_teardown_incomplete");

    const bool allNativeLanesPass =
        vulkanSetupOk && syntheticImportOk &&
        invalidArgumentRejectedOk && invalidRectRejectedOk &&
        topBottomSplitOk && leftRightSplitOk && pipTopLeftOk && pipFreeFloatingOk &&
        partialCoverageSentinelOk &&
        helperResourcesReleasedOk && diagnosticTeardownOk;

    const char* status = allNativeLanesPass ? "PASS" : (unsupported ? "UNSUPPORTED" : "FAIL");

    std::ostringstream oss;
    oss << "{"
        << "\"pass\":" << BoolStr(allNativeLanesPass) << ","
        << "\"status\":\"" << status << "\","
        << "\"marker\":\"" << (allNativeLanesPass ? kPassMarker : kFailMarker) << "\","
        << "\"proofBoundary\":\"" << kProofBoundary << "\","
        << "\"failureReason\":\"" << JsonEscape(failureReason) << "\","
        << "\"vulkanUnsupported\":" << BoolStr(unsupported) << ","
        << "\"vulkanSetupOk\":" << BoolStr(vulkanSetupOk) << ","
        << "\"syntheticImportOk\":" << BoolStr(syntheticImportOk) << ","
        << "\"invalidArgumentRejectedOk\":" << BoolStr(invalidArgumentRejectedOk) << ","
        << "\"invalidRectRejectedOk\":" << BoolStr(invalidRectRejectedOk) << ","
        << "\"topBottomSplitOk\":" << BoolStr(topBottomSplitOk) << ","
        << "\"leftRightSplitOk\":" << BoolStr(leftRightSplitOk) << ","
        << "\"pipTopLeftOk\":" << BoolStr(pipTopLeftOk) << ","
        << "\"pipFreeFloatingOk\":" << BoolStr(pipFreeFloatingOk) << ","
        << "\"partialCoverageSentinelOk\":" << BoolStr(partialCoverageSentinelOk) << ","
        << "\"helperResourcesReleasedOk\":" << BoolStr(helperResourcesReleasedOk) << ","
        << "\"diagnosticTeardownOk\":" << BoolStr(diagnosticTeardownOk) << ","
        << "\"helperTemporaryObjectsCreated\":" << compositor.temporaryObjectsCreated() << ","
        << "\"helperTemporaryObjectsReleased\":" << compositor.temporaryObjectsReleased() << ","
        << "\"allNativeLanesPass\":" << BoolStr(allNativeLanesPass) << ","
        << "\"nativeAllLanesPass\":" << BoolStr(allNativeLanesPass) << ","
        << "\"details\":" << details.Json()
        << "}";

    const std::string resultStr = oss.str();
    return env->NewStringUTF(resultStr.c_str());
}
