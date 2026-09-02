// P5-COMPOSITOR-TRANS (sub-slice VULKAN-RENDER): VulkanTimelineTransitionCompositor
// shader/raster proof diagnostic JNI bridge.
//
// Android-only translation unit added via the CMake target_sources block.
// This is the composition root that bridges vanguard::compositors'
// ComputeTransitionGeometry() (compositor-owned pure transition math from the
// verified P5-COMPOSITOR-TRANS-NODE-TOPOLOGY-MATH sub-slice) to the private
// vanguard::render::VulkanTimelineTransitionCompositor raster helper. Neither
// vanguard_render_vulkan nor the compositors library include each other; only
// this JNI translation unit links them together.
//
// The diagnostic owns a temporary VkInstance / VkDevice / VkQueue /
// VkCommandPool, synthetic 2x2 RGBA8 sampled images, a 64x64 RGBA8 offscreen
// color attachment and a host-visible readback buffer created solely for
// proof on the calling thread. It renders every transition family through the
// helper, reads the pixels back from the staging buffer, gates the result
// against hard-coded expected pixel ownership tables (top-left canvas
// coordinates), and destroys every Vulkan object it created before returning.
// Production VulkanBackend / export session state is never touched.
//
// Runtime support: Android guarantees libvulkan from API 24 but not a usable
// GPU driver, so vkCreateInstance failure, zero physical devices, no suitable
// graphics queue family, or a missing RGBA8 optimal-tiling feature set report
// status "UNSUPPORTED" with a fail-shaped payload instead of crashing.
//
// Non-claim: shader/raster proof only, using the existing AOT passthrough
// SPIR-V (no new shaders). No MediaCodec decode or dual decoder sync, no
// AHardwareBuffer / external image import, no production export route, no
// AndroidTimelineExportSession change, no app/editor UI.
//
// JNI entry point (matching VanguardNativeBridge.kt declaration):
//   runAndroidDagPhase5TimelineTransitionVulkanRenderSmoke -> jstring (JSON)

#include <jni.h>

#include <vulkan/vulkan.h>

#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <limits>
#include <sstream>
#include <string>
#include <vector>

#include "vanguard/compositors/vg_timeline_compositor_node.h"
#include "vulkan_timeline_transition_compositor.h"

namespace {

using vanguard::compositors::ComputeTransitionGeometry;
using vanguard::compositors::TimelineNormalizedRect;
using vanguard::compositors::TimelineTransitionProgress;
using vanguard::compositors::TransitionType;
using vanguard::render::VulkanTimelineNormalizedRect;
using vanguard::render::VulkanTimelineTransitionCompositor;
using vanguard::render::VulkanTimelineTransitionGeometry;
using vanguard::render::VulkanTimelineTransitionLayerImage;
using vanguard::render::VulkanTimelineTransitionRenderTarget;

constexpr const char* kProofBoundary =
    "native_vulkan_timeline_transition_compositor_shader_raster_only_no_decode_no_export";
constexpr const char* kPassMarker =
    "ANDROID_DAG_PHASE5_TIMELINE_TRANSITION_VULKAN_RENDER_PHYSICAL_SMOKE_PASS";
constexpr const char* kFailMarker =
    "ANDROID_DAG_PHASE5_TIMELINE_TRANSITION_VULKAN_RENDER_PHYSICAL_SMOKE_FAIL";

constexpr uint32_t kCanvasWidth   = 64;
constexpr uint32_t kCanvasHeight  = 64;
constexpr int      kColorTolerance = 8;
constexpr VkFormat kColorFormat   = VK_FORMAT_R8G8B8A8_UNORM;
constexpr VkDeviceSize kReadbackBytes =
    static_cast<VkDeviceSize>(kCanvasWidth) * kCanvasHeight * 4;

constexpr const char* kErrInvalidArgument     = "vulkan_timeline_transition_compositor_invalid_argument";
constexpr const char* kErrInvalidProgress     = "vulkan_timeline_transition_compositor_invalid_progress";
constexpr const char* kErrInvalidWeight       = "vulkan_timeline_transition_compositor_invalid_blend_weight";
constexpr const char* kErrInvalidGeometry     = "vulkan_timeline_transition_compositor_invalid_geometry";
constexpr const char* kErrUnsupportedGeometry = "vulkan_timeline_transition_compositor_unsupported_geometry";

struct Rgb {
    uint8_t r;
    uint8_t g;
    uint8_t b;
};

constexpr Rgb kRed      = {255, 0, 0};
constexpr Rgb kYellow   = {255, 255, 0};
constexpr Rgb kMagenta  = {255, 0, 255};
constexpr Rgb kWhite    = {255, 255, 255};
constexpr Rgb kBlue     = {0, 0, 255};
constexpr Rgb kCyan     = {0, 255, 255};
constexpr Rgb kGreen    = {0, 255, 0};
constexpr Rgb kBlack    = {0, 0, 0};
constexpr Rgb kPurple   = {128, 0, 128}; // crossfade midpoint of red/blue
constexpr Rgb kSentinel = {40, 40, 40};  // clear color; must never survive a tiling draw

// Quadrant texture A (from): TL red, TR yellow, BL magenta, BR white.
// Quadrant texture B (to):   TL blue, TR cyan, BL green, BR black.
struct QuadColors {
    Rgb tl;
    Rgb tr;
    Rgb bl;
    Rgb br;
};
constexpr QuadColors kQuadA = {kRed, kYellow, kMagenta, kWhite};
constexpr QuadColors kQuadB = {kBlue, kCyan, kGreen, kBlack};

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
        appInfo.pApplicationName   = "VanguardTimelineTransitionVulkanSmoke";
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
    samplerCI.sType        = VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO;
    samplerCI.magFilter    = VK_FILTER_NEAREST;
    samplerCI.minFilter    = VK_FILTER_NEAREST;
    samplerCI.mipmapMode   = VK_SAMPLER_MIPMAP_MODE_NEAREST;
    samplerCI.addressModeU = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE;
    samplerCI.addressModeV = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE;
    samplerCI.addressModeW = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE;
    samplerCI.maxAnisotropy = 1.0f;
    samplerCI.borderColor  = VK_BORDER_COLOR_FLOAT_TRANSPARENT_BLACK;
    if (vkCreateSampler(vk.device, &samplerCI, nullptr, &img.sampler) != VK_SUCCESS) {
        img.sampler = VK_NULL_HANDLE;
        *outError = "scratch_sampler_create_failed";
        return false;
    }
    return true;
}

void PutTexel(uint8_t* texel, Rgb c) {
    texel[0] = c.r;
    texel[1] = c.g;
    texel[2] = c.b;
    texel[3] = 255;
}

// 2x2 RGBA8 sampled image, rows top-down (row 0 == tl/tr) so crop.y == 0
// selects `tl`/`tr` without any V flip.
bool CreateQuadrantTexture(const VulkanScratch& vk, const QuadColors& q, ScratchImage& out, std::string* outError) {
    uint8_t data[2][2][4];
    PutTexel(data[0][0], q.tl);
    PutTexel(data[0][1], q.tr);
    PutTexel(data[1][0], q.bl);
    PutTexel(data[1][1], q.br);
    if (!CreateDeviceImage(vk, 2, 2, VK_IMAGE_USAGE_SAMPLED_BIT | VK_IMAGE_USAGE_TRANSFER_DST_BIT, out, outError)) {
        return false;
    }
    return UploadSampledImage(vk, out, &data[0][0][0], 2, 2, outError);
}

bool CreateSolidTexture(const VulkanScratch& vk, Rgb c, ScratchImage& out, std::string* outError) {
    return CreateQuadrantTexture(vk, QuadColors{c, c, c, c}, out, outError);
}

VulkanTimelineTransitionLayerImage LayerOf(const ScratchImage& img) {
    VulkanTimelineTransitionLayerImage layer;
    layer.imageView = img.view;
    layer.sampler   = img.sampler;
    return layer;
}

// ── Geometry conversion (compositor math -> render helper descriptor) ───────

VulkanTimelineNormalizedRect ToVulkanRect(const TimelineNormalizedRect& r) {
    VulkanTimelineNormalizedRect out;
    out.x      = r.x;
    out.y      = r.y;
    out.width  = r.width;
    out.height = r.height;
    return out;
}

VulkanTimelineTransitionGeometry ToVulkanGeometry(const TimelineTransitionProgress& p) {
    VulkanTimelineTransitionGeometry g;
    g.progress        = p.progress;
    g.blendWeightFrom = p.blendWeightFrom;
    g.blendWeightTo   = p.blendWeightTo;
    g.fromViewport    = ToVulkanRect(p.fromViewport);
    g.toViewport      = ToVulkanRect(p.toViewport);
    g.fromCrop        = ToVulkanRect(p.fromCrop);
    g.toCrop          = ToVulkanRect(p.toCrop);
    return g;
}

VulkanTimelineTransitionGeometry GeometryFor(TransitionType type, double progress) {
    return ToVulkanGeometry(ComputeTransitionGeometry(type, progress));
}

// ── Pixel readback + probes (top-left canvas coordinates, row 0 == top) ─────

const uint8_t* PixelAt(const std::vector<uint8_t>& px, uint32_t x, uint32_t yTop) {
    return &px[(static_cast<size_t>(yTop) * kCanvasWidth + x) * 4];
}

bool ColorNear(const uint8_t* p, Rgb expected) {
    return std::abs(static_cast<int>(p[0]) - expected.r) <= kColorTolerance &&
           std::abs(static_cast<int>(p[1]) - expected.g) <= kColorTolerance &&
           std::abs(static_cast<int>(p[2]) - expected.b) <= kColorTolerance;
}

uint64_t Checksum(const std::vector<uint8_t>& px) {
    uint64_t sum = 0;
    for (const uint8_t b : px) sum += b;
    return sum;
}

uint32_t CountMismatches(const std::vector<uint8_t>& px,
                         uint32_t x0, uint32_t y0, uint32_t x1, uint32_t y1,
                         Rgb expected) {
    uint32_t mismatches = 0;
    for (uint32_t y = y0; y < y1; ++y) {
        for (uint32_t x = x0; x < x1; ++x) {
            if (!ColorNear(PixelAt(px, x, y), expected)) ++mismatches;
        }
    }
    return mismatches;
}

uint32_t CountUniformMismatches(const std::vector<uint8_t>& px, Rgb expected) {
    return CountMismatches(px, 0, 0, kCanvasWidth, kCanvasHeight, expected);
}

struct QuadrantMismatches {
    uint32_t tl = 0;
    uint32_t tr = 0;
    uint32_t bl = 0;
    uint32_t br = 0;
    uint32_t total() const { return tl + tr + bl + br; }
};

QuadrantMismatches CountQuadrantMismatches(const std::vector<uint8_t>& px, const QuadColors& expected) {
    const uint32_t hw = kCanvasWidth / 2;
    const uint32_t hh = kCanvasHeight / 2;
    QuadrantMismatches m;
    m.tl = CountMismatches(px, 0,  0,  hw,           hh,            expected.tl);
    m.tr = CountMismatches(px, hw, 0,  kCanvasWidth, hh,            expected.tr);
    m.bl = CountMismatches(px, 0,  hh, hw,           kCanvasHeight, expected.bl);
    m.br = CountMismatches(px, hw, hh, kCanvasWidth, kCanvasHeight, expected.br);
    return m;
}

std::string RgbString(const uint8_t* p) {
    char buf[32];
    std::snprintf(buf, sizeof(buf), "%u,%u,%u", p[0], p[1], p[2]);
    return buf;
}

// Everything one render needs: the diagnostic's target plus the helper.
struct RenderContext {
    const VulkanScratch* vk = nullptr;
    VulkanTimelineTransitionCompositor* compositor = nullptr;
    VulkanTimelineTransitionRenderTarget target;
    const ScratchBuffer* readback = nullptr;
};

// Render (clear to sentinel + transition) -> copy back -> read. Returns false
// (with `outError`) when the helper or the readback fails.
bool RenderAndRead(RenderContext& ctx,
                   const ScratchImage& from,
                   const ScratchImage& to,
                   const VulkanTimelineTransitionGeometry& geometry,
                   std::vector<uint8_t>& outPixels,
                   std::string* outError) {
    if (!ctx.compositor->renderTransition(ctx.target, LayerOf(from), LayerOf(to), geometry, outError)) {
        return false;
    }
    InvalidateIfNeeded(*ctx.vk, *ctx.readback);
    outPixels.assign(static_cast<size_t>(kReadbackBytes), 0);
    std::memcpy(outPixels.data(), ctx.readback->mapped, static_cast<size_t>(kReadbackBytes));
    return true;
}

// ── JSON helpers ────────────────────────────────────────────────────────────

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

// Runs one slide/wipe family at p=0.5 and gates the canvas quadrant ownership
// table. Records mismatch counts and checksum under `<name>*` detail keys.
bool RunQuadrantCase(RenderContext& ctx,
                     const ScratchImage& quadA,
                     const ScratchImage& quadB,
                     TransitionType type,
                     const QuadColors& expected,
                     const char* name,
                     DetailsBuilder& details,
                     std::string* outFailure) {
    std::vector<uint8_t> px;
    std::string err;
    const std::string keyBase = name;
    if (!RenderAndRead(ctx, quadA, quadB, GeometryFor(type, 0.5), px, &err)) {
        details.Str((keyBase + "Error").c_str(), err);
        *outFailure = keyBase + "_draw_failed:" + err;
        return false;
    }
    const QuadrantMismatches m = CountQuadrantMismatches(px, expected);
    const uint32_t sentinelLeft = static_cast<uint32_t>(kCanvasWidth * kCanvasHeight) -
        CountUniformMismatches(px, kSentinel);
    details.U64((keyBase + "MismatchTl").c_str(), m.tl);
    details.U64((keyBase + "MismatchTr").c_str(), m.tr);
    details.U64((keyBase + "MismatchBl").c_str(), m.bl);
    details.U64((keyBase + "MismatchBr").c_str(), m.br);
    details.U64((keyBase + "SentinelPixels").c_str(), sentinelLeft);
    details.Str((keyBase + "Checksum").c_str(), std::to_string(Checksum(px)));
    details.Str((keyBase + "ProbeTl").c_str(), RgbString(PixelAt(px, kCanvasWidth / 4, kCanvasHeight / 4)));
    details.Str((keyBase + "ProbeTr").c_str(), RgbString(PixelAt(px, 3 * kCanvasWidth / 4, kCanvasHeight / 4)));
    details.Str((keyBase + "ProbeBl").c_str(), RgbString(PixelAt(px, kCanvasWidth / 4, 3 * kCanvasHeight / 4)));
    details.Str((keyBase + "ProbeBr").c_str(), RgbString(PixelAt(px, 3 * kCanvasWidth / 4, 3 * kCanvasHeight / 4)));
    const bool ok = m.total() == 0 && sentinelLeft == 0;
    if (!ok) {
        *outFailure = keyBase + "_pixel_ownership_mismatch";
    }
    return ok;
}

// Runs one uniform-result case (crossfade instant or hard cut) and gates
// every canvas pixel against `expected`.
bool RunUniformCase(RenderContext& ctx,
                    const ScratchImage& solidFrom,
                    const ScratchImage& solidTo,
                    TransitionType type,
                    double progress,
                    Rgb expected,
                    const char* name,
                    DetailsBuilder& details,
                    std::string* outFailure) {
    std::vector<uint8_t> px;
    std::string err;
    const std::string keyBase = name;
    if (!RenderAndRead(ctx, solidFrom, solidTo, GeometryFor(type, progress), px, &err)) {
        details.Str((keyBase + "Error").c_str(), err);
        *outFailure = keyBase + "_draw_failed:" + err;
        return false;
    }
    const uint32_t mismatches = CountUniformMismatches(px, expected);
    details.U64((keyBase + "Mismatches").c_str(), mismatches);
    details.Str((keyBase + "Checksum").c_str(), std::to_string(Checksum(px)));
    details.Str((keyBase + "CenterRgb").c_str(), RgbString(PixelAt(px, kCanvasWidth / 2, kCanvasHeight / 2)));
    const bool ok = mismatches == 0;
    if (!ok) {
        *outFailure = keyBase + "_color_mismatch";
    }
    return ok;
}

std::string VersionString(uint32_t v) {
    return std::to_string(VK_VERSION_MAJOR(v)) + "." + std::to_string(VK_VERSION_MINOR(v)) + "." +
           std::to_string(VK_VERSION_PATCH(v));
}

} // namespace

extern "C" JNIEXPORT jstring JNICALL
Java_com_connects_vanguard_1media_1engine_bridge_VanguardNativeBridge_runAndroidDagPhase5TimelineTransitionVulkanRenderSmoke(
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

    // Gate flags (all default false; every lane must set its own true).
    bool vulkanSetupOk = false;
    bool invalidHandleRejectedOk = false;
    bool invalidDimensionsRejectedOk = false;
    bool nonFiniteProgressRejectedOk = false;
    bool nonFiniteWeightRejectedOk = false;
    bool invalidGeometryRejectedOk = false;
    bool hardCutNoneOk = false;
    bool crossfadeStartOk = false;
    bool crossfadeMidOk = false;
    bool crossfadeEndOk = false;
    bool slideLeftOk = false, slideRightOk = false, slideUpOk = false, slideDownOk = false;
    bool wipeLeftOk = false, wipeRightOk = false, wipeUpOk = false, wipeDownOk = false;
    bool helperResourcesReleasedOk = false;
    bool diagnosticTeardownOk = false;
    bool unsupported = false;

    VulkanScratch vk;
    ScratchImage solidRed, solidBlue, quadA, quadB, colorTarget;
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
        bool ok = CreateSolidTexture(vk, kRed, solidRed, &err) &&
                  CreateSolidTexture(vk, kBlue, solidBlue, &err) &&
                  CreateQuadrantTexture(vk, kQuadA, quadA, &err) &&
                  CreateQuadrantTexture(vk, kQuadB, quadB, &err) &&
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

    VulkanTimelineTransitionCompositor compositor;
    RenderContext ctx;
    ctx.vk         = &vk;
    ctx.compositor = &compositor;
    ctx.readback   = &readback;
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
    ctx.target.clearColor = {{kSentinel.r / 255.0f, kSentinel.g / 255.0f, kSentinel.b / 255.0f, 1.0f}};

    if (vulkanSetupOk) {
        // ── Lane 1: parameter validation (fail closed, no Vulkan calls) ────
        const VulkanTimelineTransitionGeometry xfadeMid = GeometryFor(TransitionType::kCrossfade, 0.5);
        const VulkanTimelineTransitionLayerImage fromLayer = LayerOf(solidRed);
        const VulkanTimelineTransitionLayerImage toLayer   = LayerOf(solidBlue);
        std::string err;

        VulkanTimelineTransitionLayerImage nullView = fromLayer;
        nullView.imageView = VK_NULL_HANDLE;
        bool ok = !compositor.renderTransition(ctx.target, nullView, toLayer, xfadeMid, &err) &&
                  err == kErrInvalidArgument;
        VulkanTimelineTransitionLayerImage nullSampler = toLayer;
        nullSampler.sampler = VK_NULL_HANDLE;
        ok = ok && !compositor.renderTransition(ctx.target, fromLayer, nullSampler, xfadeMid, &err) &&
             err == kErrInvalidArgument;
        VulkanTimelineTransitionRenderTarget nullDevice = ctx.target;
        nullDevice.device = VK_NULL_HANDLE;
        ok = ok && !compositor.renderTransition(nullDevice, fromLayer, toLayer, xfadeMid, &err) &&
             err == kErrInvalidArgument;
        VulkanTimelineTransitionRenderTarget nullQueue = ctx.target;
        nullQueue.queue = VK_NULL_HANDLE;
        ok = ok && !compositor.renderTransition(nullQueue, fromLayer, toLayer, xfadeMid, &err) &&
             err == kErrInvalidArgument;
        VulkanTimelineTransitionRenderTarget nullColor = ctx.target;
        nullColor.colorImageView = VK_NULL_HANDLE;
        ok = ok && !compositor.renderTransition(nullColor, fromLayer, toLayer, xfadeMid, &err) &&
             err == kErrInvalidArgument;
        invalidHandleRejectedOk = ok;
        details.Str("invalidHandleError", err);

        VulkanTimelineTransitionRenderTarget zeroWidth = ctx.target;
        zeroWidth.extentWidth = 0;
        ok = !compositor.renderTransition(zeroWidth, fromLayer, toLayer, xfadeMid, &err) &&
             err == kErrInvalidArgument;
        VulkanTimelineTransitionRenderTarget zeroHeight = ctx.target;
        zeroHeight.extentHeight = 0;
        ok = ok && !compositor.renderTransition(zeroHeight, fromLayer, toLayer, xfadeMid, &err) &&
             err == kErrInvalidArgument;
        VulkanTimelineTransitionRenderTarget smallReadback = ctx.target;
        smallReadback.readbackBufferSizeBytes = kReadbackBytes - 4;
        ok = ok && !compositor.renderTransition(smallReadback, fromLayer, toLayer, xfadeMid, &err) &&
             err == kErrInvalidArgument;
        invalidDimensionsRejectedOk = ok;
        details.Str("invalidDimensionsError", err);

        VulkanTimelineTransitionGeometry nanProgress = xfadeMid;
        nanProgress.progress = std::numeric_limits<double>::quiet_NaN();
        ok = !compositor.renderTransition(ctx.target, fromLayer, toLayer, nanProgress, &err) &&
             err == kErrInvalidProgress;
        VulkanTimelineTransitionGeometry infProgress = xfadeMid;
        infProgress.progress = std::numeric_limits<double>::infinity();
        ok = ok && !compositor.renderTransition(ctx.target, fromLayer, toLayer, infProgress, &err) &&
             err == kErrInvalidProgress;
        nonFiniteProgressRejectedOk = ok;
        details.Str("nonFiniteProgressError", err);

        VulkanTimelineTransitionGeometry nanWeight = xfadeMid;
        nanWeight.blendWeightTo = std::numeric_limits<double>::quiet_NaN();
        ok = !compositor.renderTransition(ctx.target, fromLayer, toLayer, nanWeight, &err) &&
             err == kErrInvalidWeight;
        VulkanTimelineTransitionGeometry infWeight = xfadeMid;
        infWeight.blendWeightFrom = -std::numeric_limits<double>::infinity();
        ok = ok && !compositor.renderTransition(ctx.target, fromLayer, toLayer, infWeight, &err) &&
             err == kErrInvalidWeight;
        nonFiniteWeightRejectedOk = ok;
        details.Str("nonFiniteWeightError", err);

        VulkanTimelineTransitionGeometry cropOutside = xfadeMid;
        cropOutside.fromCrop.x = 1.5;
        ok = !compositor.renderTransition(ctx.target, fromLayer, toLayer, cropOutside, &err) &&
             err == kErrInvalidGeometry;
        VulkanTimelineTransitionGeometry negativeCrop = xfadeMid;
        negativeCrop.toCrop.width = -0.1;
        ok = ok && !compositor.renderTransition(ctx.target, fromLayer, toLayer, negativeCrop, &err) &&
             err == kErrInvalidGeometry;
        VulkanTimelineTransitionGeometry nanViewport = xfadeMid;
        nanViewport.fromViewport.x = std::numeric_limits<double>::quiet_NaN();
        ok = ok && !compositor.renderTransition(ctx.target, fromLayer, toLayer, nanViewport, &err) &&
             err == kErrInvalidGeometry;
        VulkanTimelineTransitionGeometry mixShifted = xfadeMid;
        mixShifted.toViewport.x = 0.25;
        ok = ok && !compositor.renderTransition(ctx.target, fromLayer, toLayer, mixShifted, &err) &&
             err == kErrUnsupportedGeometry;
        invalidGeometryRejectedOk = ok;
        details.Str("invalidGeometryError", err);

        const bool noVulkanObjectsAfterValidation =
            compositor.temporaryObjectsCreated() == 0 && compositor.temporaryObjectsReleased() == 0;
        details.Bool("noVulkanObjectsAfterValidation", noVulkanObjectsAfterValidation);
        if (!noVulkanObjectsAfterValidation) {
            invalidHandleRejectedOk = false;
            invalidDimensionsRejectedOk = false;
            nonFiniteProgressRejectedOk = false;
            nonFiniteWeightRejectedOk = false;
            invalidGeometryRejectedOk = false;
        }
        if (!invalidHandleRejectedOk)      fail("invalid_handle_not_rejected");
        if (!invalidDimensionsRejectedOk)  fail("invalid_dimensions_not_rejected");
        if (!nonFiniteProgressRejectedOk)  fail("non_finite_progress_not_rejected");
        if (!nonFiniteWeightRejectedOk)    fail("non_finite_weight_not_rejected");
        if (!invalidGeometryRejectedOk)    fail("invalid_geometry_not_rejected");

        // ── Lane 2: hard cut + crossfade start / mid / end ─────────────────
        std::string laneFailure;
        hardCutNoneOk = RunUniformCase(ctx, solidRed, solidBlue, TransitionType::kNone, 0.7,
                                       kRed, "hardCutNone", details, &laneFailure);
        if (!hardCutNoneOk) fail(laneFailure);
        crossfadeStartOk = RunUniformCase(ctx, solidRed, solidBlue, TransitionType::kCrossfade, 0.0,
                                          kRed, "crossfadeStart", details, &laneFailure);
        if (!crossfadeStartOk) fail(laneFailure);
        crossfadeMidOk = RunUniformCase(ctx, solidRed, solidBlue, TransitionType::kCrossfade, 0.5,
                                        kPurple, "crossfadeMid", details, &laneFailure);
        if (!crossfadeMidOk) fail(laneFailure);
        crossfadeEndOk = RunUniformCase(ctx, solidRed, solidBlue, TransitionType::kCrossfade, 1.0,
                                        kBlue, "crossfadeEnd", details, &laneFailure);
        if (!crossfadeEndOk) fail(laneFailure);

        // ── Lane 3: slides at p=0.5 (viewport translation, clipped UVs) ────
        // Expected canvas quadrant ownership derived by hand from
        // ComputeTransitionGeometry (top-left canvas coordinates): slide-left
        // shows A's right half on the canvas left and B's left half on the
        // canvas right, etc. Identical to the verified GLES tables.
        slideLeftOk = RunQuadrantCase(ctx, quadA, quadB, TransitionType::kSlideLeft,
                                      QuadColors{kQuadA.tr, kQuadB.tl, kQuadA.br, kQuadB.bl},
                                      "slideLeft", details, &laneFailure);
        if (!slideLeftOk) fail(laneFailure);
        slideRightOk = RunQuadrantCase(ctx, quadA, quadB, TransitionType::kSlideRight,
                                       QuadColors{kQuadB.tr, kQuadA.tl, kQuadB.br, kQuadA.bl},
                                       "slideRight", details, &laneFailure);
        if (!slideRightOk) fail(laneFailure);
        slideUpOk = RunQuadrantCase(ctx, quadA, quadB, TransitionType::kSlideUp,
                                    QuadColors{kQuadA.bl, kQuadA.br, kQuadB.tl, kQuadB.tr},
                                    "slideUp", details, &laneFailure);
        if (!slideUpOk) fail(laneFailure);
        slideDownOk = RunQuadrantCase(ctx, quadA, quadB, TransitionType::kSlideDown,
                                      QuadColors{kQuadB.bl, kQuadB.br, kQuadA.tl, kQuadA.tr},
                                      "slideDown", details, &laneFailure);
        if (!slideDownOk) fail(laneFailure);

        // ── Lane 4: wipes at p=0.5 (identity viewport, complementary crops) ─
        wipeLeftOk = RunQuadrantCase(ctx, quadA, quadB, TransitionType::kWipeLeft,
                                     QuadColors{kQuadA.tl, kQuadB.tr, kQuadA.bl, kQuadB.br},
                                     "wipeLeft", details, &laneFailure);
        if (!wipeLeftOk) fail(laneFailure);
        wipeRightOk = RunQuadrantCase(ctx, quadA, quadB, TransitionType::kWipeRight,
                                      QuadColors{kQuadB.tl, kQuadA.tr, kQuadB.bl, kQuadA.br},
                                      "wipeRight", details, &laneFailure);
        if (!wipeRightOk) fail(laneFailure);
        wipeUpOk = RunQuadrantCase(ctx, quadA, quadB, TransitionType::kWipeUp,
                                   QuadColors{kQuadA.tl, kQuadA.tr, kQuadB.bl, kQuadB.br},
                                   "wipeUp", details, &laneFailure);
        if (!wipeUpOk) fail(laneFailure);
        wipeDownOk = RunQuadrantCase(ctx, quadA, quadB, TransitionType::kWipeDown,
                                     QuadColors{kQuadB.tl, kQuadB.tr, kQuadA.bl, kQuadA.br},
                                     "wipeDown", details, &laneFailure);
        if (!wipeDownOk) fail(laneFailure);

        // ── Lane 5 (helper half): every temporary helper object released ───
        // Validation-only failures created nothing (checked above); every
        // render created objects and must have released exactly as many.
        const uint64_t created  = compositor.temporaryObjectsCreated();
        const uint64_t released = compositor.temporaryObjectsReleased();
        details.U64("helperTemporaryObjectsCreated", created);
        details.U64("helperTemporaryObjectsReleased", released);
        helperResourcesReleasedOk = noVulkanObjectsAfterValidation && created > 0 && created == released;
        if (!helperResourcesReleasedOk) fail("helper_temporary_objects_not_released");
    }

    // ── Teardown: every object this diagnostic created ─────────────────────
    if (vk.device != VK_NULL_HANDLE) {
        vkDeviceWaitIdle(vk.device);
    }
    readback.Destroy(vk.device);
    colorTarget.Destroy(vk.device);
    quadB.Destroy(vk.device);
    quadA.Destroy(vk.device);
    solidBlue.Destroy(vk.device);
    solidRed.Destroy(vk.device);
    const bool hadDevice = vk.device != VK_NULL_HANDLE;
    vk.Teardown();
    // Lane 5 (diagnostic half): device drained before destruction and every
    // owned handle nulled. Only meaningful when a device existed.
    diagnosticTeardownOk = hadDevice && vk.teardownWaitIdleOk && vk.AllHandlesNull() &&
                           readback.IsNull() && colorTarget.IsNull() &&
                           quadA.IsNull() && quadB.IsNull() && solidRed.IsNull() && solidBlue.IsNull();
    details.Bool("teardownWaitIdleOk", vk.teardownWaitIdleOk);
    details.Bool("teardownHandlesNull", vk.AllHandlesNull() && readback.IsNull() && colorTarget.IsNull());
    if (hadDevice && !diagnosticTeardownOk) fail("diagnostic_teardown_incomplete");

    const bool allNativeLanesPass =
        vulkanSetupOk &&
        invalidHandleRejectedOk && invalidDimensionsRejectedOk &&
        nonFiniteProgressRejectedOk && nonFiniteWeightRejectedOk && invalidGeometryRejectedOk &&
        hardCutNoneOk && crossfadeStartOk && crossfadeMidOk && crossfadeEndOk &&
        slideLeftOk && slideRightOk && slideUpOk && slideDownOk &&
        wipeLeftOk && wipeRightOk && wipeUpOk && wipeDownOk &&
        helperResourcesReleasedOk && diagnosticTeardownOk;

    const char* status = allNativeLanesPass ? "PASS" : (unsupported ? "UNSUPPORTED" : "FAIL");

    std::ostringstream oss;
    oss << "{"
        << "\"pass\":" << BoolStr(allNativeLanesPass) << ","
        << "\"status\":\"" << status << "\","
        << "\"marker\":\"" << (allNativeLanesPass ? kPassMarker : kFailMarker) << "\","
        << "\"proofBoundary\":\"" << kProofBoundary << "\","
        << "\"failureReason\":\"" << JsonEscape(failureReason) << "\","
        << "\"vulkanSetupOk\":" << BoolStr(vulkanSetupOk) << ","
        << "\"invalidHandleRejectedOk\":" << BoolStr(invalidHandleRejectedOk) << ","
        << "\"invalidDimensionsRejectedOk\":" << BoolStr(invalidDimensionsRejectedOk) << ","
        << "\"nonFiniteProgressRejectedOk\":" << BoolStr(nonFiniteProgressRejectedOk) << ","
        << "\"nonFiniteWeightRejectedOk\":" << BoolStr(nonFiniteWeightRejectedOk) << ","
        << "\"invalidGeometryRejectedOk\":" << BoolStr(invalidGeometryRejectedOk) << ","
        << "\"hardCutNoneOk\":" << BoolStr(hardCutNoneOk) << ","
        << "\"crossfadeStartOk\":" << BoolStr(crossfadeStartOk) << ","
        << "\"crossfadeMidOk\":" << BoolStr(crossfadeMidOk) << ","
        << "\"crossfadeEndOk\":" << BoolStr(crossfadeEndOk) << ","
        << "\"slideLeftOk\":" << BoolStr(slideLeftOk) << ","
        << "\"slideRightOk\":" << BoolStr(slideRightOk) << ","
        << "\"slideUpOk\":" << BoolStr(slideUpOk) << ","
        << "\"slideDownOk\":" << BoolStr(slideDownOk) << ","
        << "\"wipeLeftOk\":" << BoolStr(wipeLeftOk) << ","
        << "\"wipeRightOk\":" << BoolStr(wipeRightOk) << ","
        << "\"wipeUpOk\":" << BoolStr(wipeUpOk) << ","
        << "\"wipeDownOk\":" << BoolStr(wipeDownOk) << ","
        << "\"helperResourcesReleasedOk\":" << BoolStr(helperResourcesReleasedOk) << ","
        << "\"diagnosticTeardownOk\":" << BoolStr(diagnosticTeardownOk) << ","
        << "\"allNativeLanesPass\":" << BoolStr(allNativeLanesPass) << ","
        << "\"nativeAllLanesPass\":" << BoolStr(allNativeLanesPass) << ","
        << "\"details\":" << details.Json()
        << "}";

    const std::string resultStr = oss.str();
    return env->NewStringUTF(resultStr.c_str());
}
