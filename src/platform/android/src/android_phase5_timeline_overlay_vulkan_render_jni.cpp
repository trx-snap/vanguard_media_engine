// P5-OVERLAYS-TRANS (sub-slice VULKAN-RENDER): VulkanOverlayCompositor
// shader/raster proof diagnostic JNI bridge.
//
// Android-only translation unit added via the CMake target_sources block.
// This is the composition root for the private
// vanguard::render::VulkanOverlayCompositor raster helper: it plays the role
// the Dart VGOverlayTransformEvaluator plays in the product (already-resolved
// per-layer transforms, sorted back-to-front) by hand-building
// VulkanOverlayLayerDescriptor values with known expected pixel outcomes. No
// keyframe math is re-implemented natively.
//
// The diagnostic owns a temporary VkInstance / VkDevice / VkQueue /
// VkCommandPool, synthetic 2x2 RGBA8 sampled images with clamp-to-border
// transparent-black samplers, a 64x64 RGBA8 offscreen color attachment and a
// host-visible readback buffer created solely for proof on the calling
// thread. It renders every lane through the helper, reads the pixels back
// from the staging buffer, gates the result against hard-coded expected pixel
// tables (top-left canvas coordinates), and destroys every Vulkan object it
// created before returning. Production VulkanBackend / export session state
// is never touched.
//
// Runtime support: Android guarantees libvulkan from API 24 but not a usable
// GPU driver, so vkCreateInstance failure, zero physical devices, no suitable
// graphics queue family, or a missing RGBA8 optimal-tiling feature set report
// status "UNSUPPORTED" with a fail-shaped payload instead of crashing.
//
// Non-claim: shader/raster proof only, using the existing AOT passthrough
// SPIR-V (no new shaders). No MediaCodec decode, no AHardwareBuffer / external
// image import, no production export route, no AndroidTimelineExportSession
// change, no VGTimelineCompositorNode change, no app/editor/product UI.
//
// JNI entry point (matching VanguardNativeBridge.kt declaration):
//   runAndroidDagPhase5TimelineOverlayVulkanRenderSmoke -> jstring (JSON)

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

#include "vulkan_overlay_compositor.h"

namespace {

using vanguard::render::ComputeVulkanOverlayPlacement;
using vanguard::render::ValidateVulkanOverlayLayerDescriptor;
using vanguard::render::VulkanOverlayCompositor;
using vanguard::render::VulkanOverlayLayerDescriptor;
using vanguard::render::VulkanOverlayLayerPlacement;
using vanguard::render::VulkanOverlayRenderTarget;

constexpr const char* kProofBoundary =
    "native_vulkan_timeline_overlay_compositor_shader_raster_only_no_decode_no_export_no_product";
constexpr const char* kPassMarker =
    "ANDROID_DAG_PHASE5_TIMELINE_OVERLAY_VULKAN_RENDER_PHYSICAL_SMOKE_PASS";
constexpr const char* kFailMarker =
    "ANDROID_DAG_PHASE5_TIMELINE_OVERLAY_VULKAN_RENDER_PHYSICAL_SMOKE_FAIL";

constexpr uint32_t kCanvasWidth    = 64;
constexpr uint32_t kCanvasHeight   = 64;
constexpr int      kColorTolerance = 8;
constexpr VkFormat kColorFormat    = VK_FORMAT_R8G8B8A8_UNORM;
constexpr VkDeviceSize kReadbackBytes =
    static_cast<VkDeviceSize>(kCanvasWidth) * kCanvasHeight * 4;

constexpr const char* kErrInvalidArgument  = "vulkan_overlay_compositor_invalid_argument";
constexpr const char* kErrInvalidImage     = "vulkan_overlay_compositor_invalid_image";
constexpr const char* kErrInvalidTransform = "vulkan_overlay_compositor_invalid_transform";
constexpr const char* kErrInvalidOpacity   = "vulkan_overlay_compositor_invalid_opacity";

constexpr double kPi = 3.14159265358979323846;

// Struct parity: the native descriptor must mirror the raster fields of the
// Dart VGOverlayEvaluatedTransform (translationX/Y -> x/y, width, height,
// rotation, scale, opacity, zIndex) with the same value types, exactly like
// the verified GLES descriptor. Checked at compile time; the runtime lane
// re-reports the result.
static_assert(std::is_same<decltype(VulkanOverlayLayerDescriptor::imageView), VkImageView>::value, "imageView");
static_assert(std::is_same<decltype(VulkanOverlayLayerDescriptor::sampler), VkSampler>::value, "sampler");
static_assert(std::is_same<decltype(VulkanOverlayLayerDescriptor::x), double>::value, "x");
static_assert(std::is_same<decltype(VulkanOverlayLayerDescriptor::y), double>::value, "y");
static_assert(std::is_same<decltype(VulkanOverlayLayerDescriptor::width), double>::value, "width");
static_assert(std::is_same<decltype(VulkanOverlayLayerDescriptor::height), double>::value, "height");
static_assert(std::is_same<decltype(VulkanOverlayLayerDescriptor::rotation), double>::value, "rotation");
static_assert(std::is_same<decltype(VulkanOverlayLayerDescriptor::scale), double>::value, "scale");
static_assert(std::is_same<decltype(VulkanOverlayLayerDescriptor::opacity), double>::value, "opacity");
static_assert(std::is_same<decltype(VulkanOverlayLayerDescriptor::zIndex), int32_t>::value, "zIndex");
static_assert(std::is_standard_layout<VulkanOverlayLayerDescriptor>::value, "standard layout");
constexpr bool kStructParityCompileTimeOk = true;

struct Rgba {
    uint8_t r;
    uint8_t g;
    uint8_t b;
    uint8_t a;
};

constexpr Rgba kRed       = {255, 0, 0, 255};
constexpr Rgba kYellow    = {255, 255, 0, 255};
constexpr Rgba kMagenta   = {255, 0, 255, 255};
constexpr Rgba kWhite     = {255, 255, 255, 255};
constexpr Rgba kBlue      = {0, 0, 255, 255};
constexpr Rgba kGreen     = {0, 255, 0, 255};
constexpr Rgba kHalfGreen = {0, 255, 0, 128};  // straight alpha ~0.502
constexpr Rgba kSentinel  = {40, 40, 40, 255}; // opaque clear colour
constexpr Rgba kTransparentBlack = {0, 0, 0, 0}; // transparent clear colour

// Expected blends over the sentinel (src * a + sentinel * (1 - a)).
constexpr Rgba kRedHalfOverSentinel      = {148, 20, 20, 255}; // a = 0.5
constexpr Rgba kGreenHalfOverSentinel    = {20, 148, 20, 255}; // a = 128/255
constexpr Rgba kGreenQuarterOverSentinel = {30, 94, 30, 255};  // a = 0.5 * 128/255
constexpr Rgba kGreenHalfOverBlue        = {0, 128, 128, 255}; // opaque green @0.5 over blue
constexpr Rgba kGreenHalfOverRed         = {128, 128, 0, 255}; // opaque green @0.5 over red
// Expected blends over transparent black (dst alpha accumulates).
constexpr Rgba kHalfGreenOverTransparent = {0, 128, 0, 128};   // rgb * a, alpha = a

// Quadrant texture: TL red, TR yellow, BL magenta, BR white.
struct QuadColors {
    Rgba tl;
    Rgba tr;
    Rgba bl;
    Rgba br;
};
constexpr QuadColors kQuadA = {kRed, kYellow, kMagenta, kWhite};

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
        appInfo.pApplicationName   = "VanguardTimelineOverlayVulkanSmoke";
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
                VK_FORMAT_FEATURE_COLOR_ATTACHMENT_BIT | VK_FORMAT_FEATURE_COLOR_ATTACHMENT_BLEND_BIT |
                VK_FORMAT_FEATURE_SAMPLED_IMAGE_BIT |
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
// SHADER_READ_ONLY_OPTIMAL, then creates its NEAREST / CLAMP_TO_BORDER
// (transparent black) sampler: the helper's outside-overlay contract.
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
    samplerCI.addressModeU  = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_BORDER;
    samplerCI.addressModeV  = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_BORDER;
    samplerCI.addressModeW  = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_BORDER;
    samplerCI.maxAnisotropy = 1.0f;
    samplerCI.borderColor   = VK_BORDER_COLOR_FLOAT_TRANSPARENT_BLACK;
    if (vkCreateSampler(vk.device, &samplerCI, nullptr, &img.sampler) != VK_SUCCESS) {
        img.sampler = VK_NULL_HANDLE;
        *outError = "scratch_sampler_create_failed";
        return false;
    }
    return true;
}

void PutTexel(uint8_t* texel, Rgba c) {
    texel[0] = c.r;
    texel[1] = c.g;
    texel[2] = c.b;
    texel[3] = c.a;
}

// 2x2 RGBA8 sampled image, rows top-down (row 0 == tl/tr): texel row 0 is
// the overlay's visual top edge without any V flip.
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

bool CreateSolidTexture(const VulkanScratch& vk, Rgba c, ScratchImage& out, std::string* outError) {
    return CreateQuadrantTexture(vk, QuadColors{c, c, c, c}, out, outError);
}

// ── Descriptor construction ─────────────────────────────────────────────────

VulkanOverlayLayerDescriptor MakeLayer(const ScratchImage& img,
                                       double x, double y, double width, double height,
                                       double rotation = 0.0,
                                       double scale = 1.0,
                                       double opacity = 1.0,
                                       int32_t zIndex = 0) {
    VulkanOverlayLayerDescriptor d;
    d.imageView = img.view;
    d.sampler   = img.sampler;
    d.x         = x;
    d.y         = y;
    d.width     = width;
    d.height    = height;
    d.rotation  = rotation;
    d.scale     = scale;
    d.opacity   = opacity;
    d.zIndex    = zIndex;
    return d;
}

// ── Pixel readback + probes (top-left canvas coordinates, row 0 == top) ─────

const uint8_t* PixelAt(const std::vector<uint8_t>& px, uint32_t x, uint32_t yTop) {
    return &px[(static_cast<size_t>(yTop) * kCanvasWidth + x) * 4];
}

bool ColorNear(const uint8_t* p, Rgba expected) {
    return std::abs(static_cast<int>(p[0]) - expected.r) <= kColorTolerance &&
           std::abs(static_cast<int>(p[1]) - expected.g) <= kColorTolerance &&
           std::abs(static_cast<int>(p[2]) - expected.b) <= kColorTolerance &&
           std::abs(static_cast<int>(p[3]) - expected.a) <= kColorTolerance;
}

uint64_t Checksum(const std::vector<uint8_t>& px) {
    uint64_t sum = 0;
    for (const uint8_t b : px) sum += b;
    return sum;
}

std::string RgbaString(const uint8_t* p) {
    char buf[48];
    std::snprintf(buf, sizeof(buf), "%u,%u,%u,%u", p[0], p[1], p[2], p[3]);
    return buf;
}

// One expected-ownership region in top-left pixel coordinates [x0,x1)x[y0,y1).
// Regions are evaluated in order; the first region containing a pixel wins,
// so list the topmost (last drawn) layer's regions first.
struct Region {
    uint32_t x0, y0, x1, y1;
    Rgba color;
};

// Counts pixels whose colour does not match the first region containing
// them, or `background` when no region contains them.
uint32_t CountTableMismatches(const std::vector<uint8_t>& px,
                              const Region* regions, size_t regionCount,
                              Rgba background,
                              uint32_t* outFirstBadX, uint32_t* outFirstBadY,
                              std::string* outFirstBadRgba) {
    uint32_t mismatches = 0;
    for (uint32_t y = 0; y < kCanvasHeight; ++y) {
        for (uint32_t x = 0; x < kCanvasWidth; ++x) {
            Rgba expected = background;
            for (size_t i = 0; i < regionCount; ++i) {
                const Region& r = regions[i];
                if (x >= r.x0 && x < r.x1 && y >= r.y0 && y < r.y1) {
                    expected = r.color;
                    break;
                }
            }
            const uint8_t* p = PixelAt(px, x, y);
            if (!ColorNear(p, expected)) {
                if (mismatches == 0) {
                    *outFirstBadX = x;
                    *outFirstBadY = y;
                    *outFirstBadRgba = RgbaString(p);
                }
                ++mismatches;
            }
        }
    }
    return mismatches;
}

// Arbitrary-angle ownership: for every pixel centre, evaluates the layer's
// inverse placement in double precision and expects the quadrant colour when
// (u, v) lies inside [0,1]^2, else `background`. Pixels within one source
// pixel of any quadrant / outer edge are skipped (rasterization tie zone).
uint32_t CountRotatedQuadMismatches(const std::vector<uint8_t>& px,
                                    const VulkanOverlayLayerDescriptor& layer,
                                    const QuadColors& quad,
                                    Rgba background,
                                    uint32_t* outChecked,
                                    uint32_t* outInside) {
    const double cx = layer.x + layer.width * 0.5;
    const double cy = layer.y + layer.height * 0.5;
    const double ws = layer.width * layer.scale;
    const double hs = layer.height * layer.scale;
    const double c  = std::cos(layer.rotation);
    const double s  = std::sin(layer.rotation);
    uint32_t mismatches = 0;
    *outChecked = 0;
    *outInside = 0;
    for (uint32_t y = 0; y < kCanvasHeight; ++y) {
        for (uint32_t x = 0; x < kCanvasWidth; ++x) {
            const double dx = (x + 0.5) - cx;
            const double dy = (y + 0.5) - cy;
            const double u  = (c * dx + s * dy) / ws + 0.5;
            const double v  = (-s * dx + c * dy) / hs + 0.5;
            const double edgeU = std::min(std::fabs(u), std::min(std::fabs(u - 0.5), std::fabs(u - 1.0))) * ws;
            const double edgeV = std::min(std::fabs(v), std::min(std::fabs(v - 0.5), std::fabs(v - 1.0))) * hs;
            if (edgeU < 1.0 || edgeV < 1.0) continue;
            const bool inside = u > 0.0 && u < 1.0 && v > 0.0 && v < 1.0;
            Rgba expected = background;
            if (inside) {
                ++*outInside;
                expected = v < 0.5 ? (u < 0.5 ? quad.tl : quad.tr) : (u < 0.5 ? quad.bl : quad.br);
            }
            ++*outChecked;
            if (!ColorNear(PixelAt(px, x, y), expected)) ++mismatches;
        }
    }
    return mismatches;
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

// Everything one render needs: the diagnostic's target plus the helper.
struct RenderContext {
    const VulkanScratch* vk = nullptr;
    VulkanOverlayCompositor* compositor = nullptr;
    VulkanOverlayRenderTarget target; // default: clear to opaque sentinel
    const ScratchBuffer* readback = nullptr;
};

void ReadBack(const RenderContext& ctx, std::vector<uint8_t>& outPixels) {
    InvalidateIfNeeded(*ctx.vk, *ctx.readback);
    outPixels.assign(static_cast<size_t>(kReadbackBytes), 0);
    std::memcpy(outPixels.data(), ctx.readback->mapped, static_cast<size_t>(kReadbackBytes));
}

// Render `layers` into `target` -> copy back -> read. Returns false (with
// `outError`) when the helper fails.
bool RenderAndRead(RenderContext& ctx,
                   const VulkanOverlayRenderTarget& target,
                   const VulkanOverlayLayerDescriptor* layers,
                   size_t layerCount,
                   std::vector<uint8_t>& outPixels,
                   std::string* outError) {
    if (!ctx.compositor->renderOverlays(target, layers, layerCount, outError)) {
        return false;
    }
    ReadBack(ctx, outPixels);
    return true;
}

// Render the layer list into `target` -> read -> gate against the region
// table over `background`.
bool RunTableCase(RenderContext& ctx,
                  const VulkanOverlayRenderTarget& target,
                  const VulkanOverlayLayerDescriptor* layers, size_t layerCount,
                  const Region* regions, size_t regionCount,
                  Rgba background,
                  const char* name,
                  DetailsBuilder& details,
                  std::string* outFailure) {
    const std::string keyBase = name;
    std::string err;
    std::vector<uint8_t> px;
    if (!RenderAndRead(ctx, target, layers, layerCount, px, &err)) {
        details.Str((keyBase + "Error").c_str(), err);
        *outFailure = keyBase + "_draw_failed:" + err;
        return false;
    }
    uint32_t badX = 0, badY = 0;
    std::string badRgba;
    const uint32_t mismatches =
        CountTableMismatches(px, regions, regionCount, background, &badX, &badY, &badRgba);
    details.U64((keyBase + "Mismatches").c_str(), mismatches);
    details.Str((keyBase + "Checksum").c_str(), std::to_string(Checksum(px)));
    details.Str((keyBase + "CenterRgba").c_str(),
                RgbaString(PixelAt(px, kCanvasWidth / 2, kCanvasHeight / 2)));
    if (mismatches != 0) {
        details.Str((keyBase + "FirstMismatch").c_str(),
                    std::to_string(badX) + "," + std::to_string(badY) + ":" + badRgba);
        *outFailure = keyBase + "_pixel_mismatch";
        return false;
    }
    return true;
}

// Expects renderOverlays to reject the single `layer` with exactly
// `expectedError` against `target`.
bool ExpectRejected(VulkanOverlayCompositor& compositor,
                    const VulkanOverlayRenderTarget& target,
                    const VulkanOverlayLayerDescriptor& layer,
                    const char* expectedError,
                    std::string* outActual) {
    std::string err;
    const bool drew = compositor.renderOverlays(target, &layer, 1, &err);
    *outActual = err;
    return !drew && err == expectedError;
}

std::string VersionString(uint32_t v) {
    return std::to_string(VK_VERSION_MAJOR(v)) + "." + std::to_string(VK_VERSION_MINOR(v)) + "." +
           std::to_string(VK_VERSION_PATCH(v));
}

} // namespace

extern "C" JNIEXPORT jstring JNICALL
Java_com_connects_vanguard_1media_1engine_bridge_VanguardNativeBridge_runAndroidDagPhase5TimelineOverlayVulkanRenderSmoke(
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
    details.Str("placementStrategy", "inverse_uv_push_constant_full_viewport_bbox_scissor");
    details.Str("blendFactors", "src_alpha_one_minus_src_alpha_add_one_one_minus_src_alpha_add");
    details.Str("outsideOverlaySampling", "sampler_clamp_to_border_float_transparent_black");

    // Gate flags (all default false; every lane must set its own true).
    bool vulkanSetupOk = false;
    bool invalidImageRejectedOk = false;
    bool invalidDimensionsRejectedOk = false;
    bool nonFiniteTransformRejectedOk = false;
    bool invalidOpacityRejectedOk = false;
    bool mixedListRejectedBeforeDrawOk = false;
    bool singleLayerTransformOk = false;
    bool arbitraryRotationOk = false;
    bool opacityBlendOk = false;
    bool alphaAccumulationOk = false;
    bool multiLayerZOrderOk = false;
    bool existingContentsCompositeOk = false;
    bool helperResourcesReleasedOk = false;
    bool diagnosticTeardownOk = false;
    bool structParityOk = false;
    bool canonical = false;
    bool unsupported = false;

    VulkanScratch vk;
    ScratchImage solidRed, solidBlue, solidGreen, halfGreen, quadA, colorTarget;
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
                  CreateSolidTexture(vk, kGreen, solidGreen, &err) &&
                  CreateSolidTexture(vk, kHalfGreen, halfGreen, &err) &&
                  CreateQuadrantTexture(vk, kQuadA, quadA, &err) &&
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

    VulkanOverlayCompositor compositor;
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
    ctx.target.loadExistingContents    = false;
    ctx.target.colorInitialLayout      = VK_IMAGE_LAYOUT_UNDEFINED;
    ctx.target.readbackBuffer          = readback.buffer;
    ctx.target.readbackBufferSizeBytes = readback.size;
    ctx.target.extentWidth             = kCanvasWidth;
    ctx.target.extentHeight            = kCanvasHeight;
    ctx.target.clearColor = {{kSentinel.r / 255.0f, kSentinel.g / 255.0f, kSentinel.b / 255.0f, 1.0f}};

    // Same target but cleared to transparent black (alpha accumulation lane).
    VulkanOverlayRenderTarget transparentTarget = ctx.target;
    transparentTarget.clearColor = {{0.0f, 0.0f, 0.0f, 0.0f}};

    if (vulkanSetupOk) {
        // ── Lane 1: parameter validation (fail closed, no Vulkan calls) ────
        const VulkanOverlayLayerDescriptor valid = MakeLayer(solidRed, 8, 8, 16, 16);
        std::string err;

        {
            VulkanOverlayLayerDescriptor nullView = valid;
            nullView.imageView = VK_NULL_HANDLE;
            bool ok = ExpectRejected(compositor, ctx.target, nullView, kErrInvalidImage, &err);
            VulkanOverlayLayerDescriptor nullSampler = valid;
            nullSampler.sampler = VK_NULL_HANDLE;
            ok = ok && ExpectRejected(compositor, ctx.target, nullSampler, kErrInvalidImage, &err);
            invalidImageRejectedOk = ok;
            details.Str("invalidImageError", err);
        }

        {
            VulkanOverlayRenderTarget t = ctx.target;
            t.device = VK_NULL_HANDLE;
            bool ok = ExpectRejected(compositor, t, valid, kErrInvalidArgument, &err);
            t = ctx.target; t.queue = VK_NULL_HANDLE;
            ok = ok && ExpectRejected(compositor, t, valid, kErrInvalidArgument, &err);
            t = ctx.target; t.commandPool = VK_NULL_HANDLE;
            ok = ok && ExpectRejected(compositor, t, valid, kErrInvalidArgument, &err);
            t = ctx.target; t.colorImage = VK_NULL_HANDLE;
            ok = ok && ExpectRejected(compositor, t, valid, kErrInvalidArgument, &err);
            t = ctx.target; t.colorImageView = VK_NULL_HANDLE;
            ok = ok && ExpectRejected(compositor, t, valid, kErrInvalidArgument, &err);
            t = ctx.target; t.colorFormat = VK_FORMAT_UNDEFINED;
            ok = ok && ExpectRejected(compositor, t, valid, kErrInvalidArgument, &err);
            t = ctx.target; t.readbackBuffer = VK_NULL_HANDLE;
            ok = ok && ExpectRejected(compositor, t, valid, kErrInvalidArgument, &err);
            t = ctx.target; t.readbackBufferSizeBytes = kReadbackBytes - 4;
            ok = ok && ExpectRejected(compositor, t, valid, kErrInvalidArgument, &err);
            t = ctx.target; t.extentWidth = 0;
            ok = ok && ExpectRejected(compositor, t, valid, kErrInvalidArgument, &err);
            t = ctx.target; t.extentHeight = 0;
            ok = ok && ExpectRejected(compositor, t, valid, kErrInvalidArgument, &err);
            t = ctx.target; t.loadExistingContents = true; t.colorInitialLayout = VK_IMAGE_LAYOUT_UNDEFINED;
            ok = ok && ExpectRejected(compositor, t, valid, kErrInvalidArgument, &err);
            {
                // Null layer array with a non-zero count is an argument error.
                std::string nullErr;
                const bool nullRejected =
                    !compositor.renderOverlays(ctx.target, nullptr, 1, &nullErr) &&
                    nullErr == kErrInvalidArgument;
                ok = ok && nullRejected;
            }
            ok = ok && ExpectRejected(compositor, ctx.target, MakeLayer(solidRed, 8, 8, 0, 16),
                                      kErrInvalidTransform, &err);
            ok = ok && ExpectRejected(compositor, ctx.target, MakeLayer(solidRed, 8, 8, 16, -4),
                                      kErrInvalidTransform, &err);
            ok = ok && ExpectRejected(compositor, ctx.target, MakeLayer(solidRed, 8, 8, 16, 16, 0.0, 0.0),
                                      kErrInvalidTransform, &err);
            ok = ok && ExpectRejected(compositor, ctx.target, MakeLayer(solidRed, 8, 8, 16, 16, 0.0, -1.0),
                                      kErrInvalidTransform, &err);
            invalidDimensionsRejectedOk = ok;
            details.Str("invalidDimensionsError", err);
        }

        {
            const double kNan = std::numeric_limits<double>::quiet_NaN();
            const double kInf = std::numeric_limits<double>::infinity();
            bool ok = ExpectRejected(compositor, ctx.target, MakeLayer(solidRed, kNan, 8, 16, 16),
                                     kErrInvalidTransform, &err);
            ok = ok && ExpectRejected(compositor, ctx.target, MakeLayer(solidRed, 8, kInf, 16, 16),
                                      kErrInvalidTransform, &err);
            ok = ok && ExpectRejected(compositor, ctx.target, MakeLayer(solidRed, 8, 8, kNan, 16),
                                      kErrInvalidTransform, &err);
            ok = ok && ExpectRejected(compositor, ctx.target, MakeLayer(solidRed, 8, 8, 16, kInf),
                                      kErrInvalidTransform, &err);
            ok = ok && ExpectRejected(compositor, ctx.target, MakeLayer(solidRed, 8, 8, 16, 16, kNan),
                                      kErrInvalidTransform, &err);
            ok = ok && ExpectRejected(compositor, ctx.target, MakeLayer(solidRed, 8, 8, 16, 16, -kInf),
                                      kErrInvalidTransform, &err);
            ok = ok && ExpectRejected(compositor, ctx.target, MakeLayer(solidRed, 8, 8, 16, 16, 0.0, kNan),
                                      kErrInvalidTransform, &err);
            ok = ok && ExpectRejected(compositor, ctx.target, MakeLayer(solidRed, 8, 8, 16, 16, 0.0, kInf),
                                      kErrInvalidTransform, &err);
            // Finite inputs whose derived placement overflows are also rejected.
            const double kHuge = std::numeric_limits<double>::max();
            ok = ok && ExpectRejected(compositor, ctx.target, MakeLayer(solidRed, 8, 8, kHuge, 16, 0.0, kHuge),
                                      kErrInvalidTransform, &err);
            nonFiniteTransformRejectedOk = ok;
            details.Str("nonFiniteTransformError", err);
        }

        {
            const double kNan = std::numeric_limits<double>::quiet_NaN();
            const double kInf = std::numeric_limits<double>::infinity();
            bool ok = ExpectRejected(compositor, ctx.target, MakeLayer(solidRed, 8, 8, 16, 16, 0.0, 1.0, kNan),
                                     kErrInvalidOpacity, &err);
            ok = ok && ExpectRejected(compositor, ctx.target, MakeLayer(solidRed, 8, 8, 16, 16, 0.0, 1.0, kInf),
                                      kErrInvalidOpacity, &err);
            ok = ok && ExpectRejected(compositor, ctx.target, MakeLayer(solidRed, 8, 8, 16, 16, 0.0, 1.0, -0.01),
                                      kErrInvalidOpacity, &err);
            ok = ok && ExpectRejected(compositor, ctx.target, MakeLayer(solidRed, 8, 8, 16, 16, 0.0, 1.0, 1.01),
                                      kErrInvalidOpacity, &err);
            invalidOpacityRejectedOk = ok;
            details.Str("invalidOpacityError", err);
        }

        const bool noVulkanObjectsAfterValidation =
            compositor.temporaryObjectsCreated() == 0 && compositor.temporaryObjectsReleased() == 0;
        details.Bool("noVulkanObjectsAfterValidation", noVulkanObjectsAfterValidation);
        if (!noVulkanObjectsAfterValidation) {
            invalidImageRejectedOk = false;
            invalidDimensionsRejectedOk = false;
            nonFiniteTransformRejectedOk = false;
            invalidOpacityRejectedOk = false;
        }
        if (!invalidImageRejectedOk)       fail("invalid_image_not_rejected");
        if (!invalidDimensionsRejectedOk)  fail("invalid_dimensions_not_rejected");
        if (!nonFiniteTransformRejectedOk) fail("non_finite_transform_not_rejected");
        if (!invalidOpacityRejectedOk)     fail("invalid_opacity_not_rejected");

        // ── Lane 2: single-layer transform (translation + scale, rotation) ─
        std::string laneFailure;
        {
            // Quadrant texture at (16,16) 16x16, scale 2 -> centre (24,24),
            // half extents 16 -> covers [8,40)^2 with quadrants at 24.
            const VulkanOverlayLayerDescriptor scaled = MakeLayer(quadA, 16, 16, 16, 16, 0.0, 2.0);
            const Region scaledTable[] = {
                {8, 8, 24, 24, kRed}, {24, 8, 40, 24, kYellow},
                {8, 24, 24, 40, kMagenta}, {24, 24, 40, 40, kWhite},
            };
            const bool scaledOk = RunTableCase(ctx, ctx.target, &scaled, 1, scaledTable, 4, kSentinel,
                                               "translateScale", details, &laneFailure);
            if (!scaledOk) fail(laneFailure);

            // Non-square 32x16 at (16,24), rotated +90 deg (clockwise) about
            // centre (32,32) -> covers [24,40)x[16,48); quadrants rotate
            // TL->TR, TR->BR, BR->BL, BL->TL.
            const VulkanOverlayLayerDescriptor rotated = MakeLayer(quadA, 16, 24, 32, 16, kPi / 2.0);
            const Region rotatedTable[] = {
                {24, 16, 32, 32, kMagenta}, {32, 16, 40, 32, kRed},
                {24, 32, 32, 48, kWhite},   {32, 32, 40, 48, kYellow},
            };
            const bool rotatedOk = RunTableCase(ctx, ctx.target, &rotated, 1, rotatedTable, 4, kSentinel,
                                                "rotate90", details, &laneFailure);
            if (!rotatedOk) fail(laneFailure);

            // 180 deg: quadrants swap diagonally, footprint unchanged.
            const VulkanOverlayLayerDescriptor flipped = MakeLayer(quadA, 16, 16, 32, 32, kPi);
            const Region flippedTable[] = {
                {16, 16, 32, 32, kWhite}, {32, 16, 48, 32, kMagenta},
                {16, 32, 32, 48, kYellow}, {32, 32, 48, 48, kRed},
            };
            const bool flippedOk = RunTableCase(ctx, ctx.target, &flipped, 1, flippedTable, 4, kSentinel,
                                                "rotate180", details, &laneFailure);
            if (!flippedOk) fail(laneFailure);

            // Partially off-canvas translation: red 32x32 at (48,-16) shows
            // only [48,64)x[0,16).
            const VulkanOverlayLayerDescriptor offCanvas = MakeLayer(solidRed, 48, -16, 32, 32);
            const Region offCanvasTable[] = {{48, 0, 64, 16, kRed}};
            const bool offCanvasOk = RunTableCase(ctx, ctx.target, &offCanvas, 1, offCanvasTable, 1, kSentinel,
                                                  "offCanvasClip", details, &laneFailure);
            if (!offCanvasOk) fail(laneFailure);

            // Fully off-canvas layer is a valid draw that leaves the clear
            // colour everywhere (placement rounds to zero visible pixels).
            const VulkanOverlayLayerDescriptor farAway = MakeLayer(solidRed, 1000, 1000, 32, 32);
            const bool farAwayOk = RunTableCase(ctx, ctx.target, &farAway, 1, nullptr, 0, kSentinel,
                                                "fullyOffCanvas", details, &laneFailure);
            if (!farAwayOk) fail(laneFailure);

            singleLayerTransformOk = scaledOk && rotatedOk && flippedOk && offCanvasOk && farAwayOk;
        }

        // ── Lane 2b: arbitrary rotation (45 deg) + transparent border ──────
        {
            // 32x32 quadrant at (16,16) rotated 45 deg about (32,32): a
            // diamond reaching 22.6 px from the centre. Pixels inside the
            // scissor bounding box but outside the diamond must stay at the
            // sentinel (clamp-to-border transparent black), proving the
            // outside-overlay contract.
            const VulkanOverlayLayerDescriptor diamond = MakeLayer(quadA, 16, 16, 32, 32, kPi / 4.0);
            std::vector<uint8_t> px;
            std::string err45;
            bool ok = RenderAndRead(ctx, ctx.target, &diamond, 1, px, &err45);
            if (!ok) {
                details.Str("rotate45Error", err45);
                fail("rotate45_draw_failed:" + err45);
            } else {
                uint32_t checked = 0, inside = 0;
                const uint32_t mismatches =
                    CountRotatedQuadMismatches(px, diamond, kQuadA, kSentinel, &checked, &inside);
                details.U64("rotate45Mismatches", mismatches);
                details.U64("rotate45CheckedPixels", checked);
                details.U64("rotate45InsidePixels", inside);
                details.Str("rotate45Checksum", std::to_string(Checksum(px)));
                // Explicit probes: one per quadrant plus a bounding-box corner
                // that lies outside the diamond, and a far canvas corner.
                const bool probes =
                    ColorNear(PixelAt(px, 32, 20), kRed) &&
                    ColorNear(PixelAt(px, 44, 32), kYellow) &&
                    ColorNear(PixelAt(px, 20, 32), kMagenta) &&
                    ColorNear(PixelAt(px, 32, 44), kWhite) &&
                    ColorNear(PixelAt(px, 17, 17), kSentinel) &&
                    ColorNear(PixelAt(px, 46, 46), kSentinel) &&
                    ColorNear(PixelAt(px, 2, 2), kSentinel);
                details.Str("rotate45ProbeTop", RgbaString(PixelAt(px, 32, 20)));
                details.Str("rotate45ProbeRight", RgbaString(PixelAt(px, 44, 32)));
                details.Str("rotate45ProbeLeft", RgbaString(PixelAt(px, 20, 32)));
                details.Str("rotate45ProbeBottom", RgbaString(PixelAt(px, 32, 44)));
                details.Str("rotate45ProbeBboxCorner", RgbaString(PixelAt(px, 17, 17)));
                details.Bool("rotate45ProbesOk", probes);
                ok = mismatches == 0 && inside > 0 && probes;
                if (!ok) fail("rotate45_pixel_mismatch");
            }
            arbitraryRotationOk = ok;
        }

        // ── Lane 3: per-layer opacity + Porter-Duff source-over ────────────
        {
            const VulkanOverlayLayerDescriptor redHalf = MakeLayer(solidRed, 0, 0, 64, 64, 0.0, 1.0, 0.5);
            const Region redHalfTable[] = {{0, 0, 64, 64, kRedHalfOverSentinel}};
            const bool a = RunTableCase(ctx, ctx.target, &redHalf, 1, redHalfTable, 1, kSentinel,
                                        "opacityHalfUniform", details, &laneFailure);
            if (!a) fail(laneFailure);

            // Texture alpha alone (opacity = 1) blends.
            const VulkanOverlayLayerDescriptor texAlpha = MakeLayer(halfGreen, 0, 0, 64, 64);
            const Region texAlphaTable[] = {{0, 0, 64, 64, kGreenHalfOverSentinel}};
            const bool b = RunTableCase(ctx, ctx.target, &texAlpha, 1, texAlphaTable, 1, kSentinel,
                                        "textureAlphaBlend", details, &laneFailure);
            if (!b) fail(laneFailure);

            // Texture alpha x opacity multiply (RGB stays straight).
            const VulkanOverlayLayerDescriptor both = MakeLayer(halfGreen, 0, 0, 64, 64, 0.0, 1.0, 0.5);
            const Region bothTable[] = {{0, 0, 64, 64, kGreenQuarterOverSentinel}};
            const bool c = RunTableCase(ctx, ctx.target, &both, 1, bothTable, 1, kSentinel,
                                        "textureAlphaTimesOpacity", details, &laneFailure);
            if (!c) fail(laneFailure);

            // Opacity 0 leaves the destination untouched; opacity 1 is opaque.
            const VulkanOverlayLayerDescriptor zero = MakeLayer(solidRed, 0, 0, 64, 64, 0.0, 1.0, 0.0);
            const bool d = RunTableCase(ctx, ctx.target, &zero, 1, nullptr, 0, kSentinel,
                                        "opacityZero", details, &laneFailure);
            if (!d) fail(laneFailure);
            const VulkanOverlayLayerDescriptor one = MakeLayer(solidRed, 16, 16, 32, 32);
            const Region oneTable[] = {{16, 16, 48, 48, kRed}};
            const bool e = RunTableCase(ctx, ctx.target, &one, 1, oneTable, 1, kSentinel,
                                        "opacityOneOpaque", details, &laneFailure);
            if (!e) fail(laneFailure);

            opacityBlendOk = a && b && c && d && e;
        }

        // ── Lane 3b: destination alpha accumulation over transparent black ─
        {
            // alpha = srcA * 1 + dstA * (1 - srcA) with dstA = 0 -> srcA;
            // rgb = src * srcA. Proves the ONE / ONE_MINUS_SRC_ALPHA alpha
            // factors rather than an opaque-destination shortcut.
            const VulkanOverlayLayerDescriptor half = MakeLayer(halfGreen, 16, 16, 32, 32);
            const Region halfTable[] = {{16, 16, 48, 48, kHalfGreenOverTransparent}};
            const bool a = RunTableCase(ctx, transparentTarget, &half, 1, halfTable, 1, kTransparentBlack,
                                        "alphaAccumulateHalf", details, &laneFailure);
            if (!a) fail(laneFailure);
            const VulkanOverlayLayerDescriptor opaque = MakeLayer(solidRed, 0, 0, 32, 64);
            const Region opaqueTable[] = {{0, 0, 32, 64, kRed}};
            const bool b = RunTableCase(ctx, transparentTarget, &opaque, 1, opaqueTable, 1, kTransparentBlack,
                                        "alphaAccumulateOpaque", details, &laneFailure);
            if (!b) fail(laneFailure);
            alphaAccumulationOk = a && b;
        }

        // ── Lane 4: multi-layer stacking / order ───────────────────────────
        {
            const VulkanOverlayLayerDescriptor stack[3] = {
                MakeLayer(solidRed,   0,  0, 32, 64, 0.0, 1.0, 1.0, 0),
                MakeLayer(solidBlue,  16, 0, 32, 64, 0.0, 1.0, 1.0, 1),
                MakeLayer(solidGreen, 24, 24, 16, 16, 0.0, 1.0, 0.5, 2),
            };
            const Region stackTable[] = {
                {24, 24, 40, 40, kGreenHalfOverBlue}, // top: half green over blue
                {16, 0, 48, 64, kBlue},               // middle covers red overlap
                {0, 0, 32, 64, kRed},
            };
            const bool forwardOk = RunTableCase(ctx, ctx.target, stack, 3, stackTable, 3, kSentinel,
                                                "stackForward", details, &laneFailure);
            if (!forwardOk) fail(laneFailure);

            // Reverse order of the two opaque layers: overlap must be red,
            // proving the helper honours caller order rather than zIndex.
            const VulkanOverlayLayerDescriptor reversed[2] = {stack[1], stack[0]};
            const Region reversedTable[] = {
                {0, 0, 32, 64, kRed},
                {16, 0, 48, 64, kBlue},
            };
            const bool reverseOk = RunTableCase(ctx, ctx.target, reversed, 2, reversedTable, 2, kSentinel,
                                                "stackReversed", details, &laneFailure);
            if (!reverseOk) fail(laneFailure);

            // Empty list is a successful no-op: no Vulkan object created, the
            // readback buffer (still holding the reversed stack) untouched.
            std::vector<uint8_t> before;
            ReadBack(ctx, before);
            const uint64_t createdBefore = compositor.temporaryObjectsCreated();
            std::string emptyErr;
            const bool emptyReturned =
                compositor.renderOverlays(ctx.target, nullptr, 0, &emptyErr) && emptyErr.empty();
            std::vector<uint8_t> after;
            ReadBack(ctx, after);
            const bool emptyOk = emptyReturned &&
                                 compositor.temporaryObjectsCreated() == createdBefore &&
                                 before == after;
            details.Bool("emptyListNoOpOk", emptyOk);
            details.Str("emptyListError", emptyErr);
            if (!emptyOk) fail("empty_layer_list_not_no_op");

            multiLayerZOrderOk = forwardOk && reverseOk && emptyOk;
        }

        // ── Lane 1b: mixed list rejected before any draw ───────────────────
        {
            // A bad layer anywhere in the list rejects the whole list before
            // any Vulkan call: the readback buffer and object counters must
            // be untouched, and the valid first layer must not be drawn.
            std::vector<uint8_t> before;
            ReadBack(ctx, before);
            const uint64_t createdBefore = compositor.temporaryObjectsCreated();
            const VulkanOverlayLayerDescriptor list[2] = {
                valid, MakeLayer(solidBlue, 0, 0, 16, 16, 0.0, 1.0, 1.5, 1)};
            std::string listErr;
            const bool listRejected =
                !compositor.renderOverlays(ctx.target, list, 2, &listErr) &&
                listErr == kErrInvalidOpacity;
            std::vector<uint8_t> after;
            ReadBack(ctx, after);
            mixedListRejectedBeforeDrawOk = listRejected &&
                                            compositor.temporaryObjectsCreated() == createdBefore &&
                                            before == after;
            details.Bool("mixedListRejectedBeforeDraw", mixedListRejectedBeforeDrawOk);
            details.Str("mixedListError", listErr);
            if (!mixedListRejectedBeforeDrawOk) fail("mixed_list_not_rejected_before_draw");
        }

        // ── Lane 4b: composite over existing attachment contents ───────────
        {
            // Render A (clear): opaque red 32x32 at (16,16) over the sentinel.
            // Render B (load, initial layout TRANSFER_SRC_OPTIMAL left by A):
            // half-opacity green over the whole canvas -> green-over-red in
            // the square, green-over-sentinel elsewhere. Proves loadOp LOAD
            // preserves the base layer the way a real overlay pass needs.
            const VulkanOverlayLayerDescriptor base = MakeLayer(solidRed, 16, 16, 32, 32);
            const Region baseTable[] = {{16, 16, 48, 48, kRed}};
            const bool baseOk = RunTableCase(ctx, ctx.target, &base, 1, baseTable, 1, kSentinel,
                                             "existingBase", details, &laneFailure);
            if (!baseOk) fail(laneFailure);

            VulkanOverlayRenderTarget loadTarget = ctx.target;
            loadTarget.loadExistingContents = true;
            loadTarget.colorInitialLayout   = VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL;
            const VulkanOverlayLayerDescriptor top = MakeLayer(solidGreen, 0, 0, 64, 64, 0.0, 1.0, 0.5, 5);
            const Region loadTable[] = {{16, 16, 48, 48, kGreenHalfOverRed}};
            const bool loadOk = baseOk && RunTableCase(ctx, loadTarget, &top, 1, loadTable, 1,
                                                       kGreenHalfOverSentinel,
                                                       "existingComposite", details, &laneFailure);
            if (baseOk && !loadOk) fail(laneFailure);
            existingContentsCompositeOk = baseOk && loadOk;
        }

        // ── Lane 5 (helper half): every temporary helper object released ───
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

        // ── Lane 6: descriptor / placement parity + telemetry ──────────────
        {
            VulkanOverlayLayerPlacement p;
            auto near = [](double a, double b) { return std::fabs(a - b) <= 1e-5; };
            auto apply = [&p](double bx, double by, double* u, double* v) {
                *u = p.uvRow0[0] * bx + p.uvRow0[1] * by + p.uvRow0[3];
                *v = p.uvRow1[0] * bx + p.uvRow1[1] * by + p.uvRow1[3];
            };
            double u = 0, v = 0;

            // Full-canvas identity placement: base (0,0) -> (u,v) (0,0),
            // base (1,1) -> (1,1), scissor = whole canvas.
            const VulkanOverlayLayerDescriptor full = MakeLayer(solidRed, 0, 0, 64, 64);
            bool parity = ComputeVulkanOverlayPlacement(full, kCanvasWidth, kCanvasHeight, &p) && p.visible;
            apply(0, 0, &u, &v);
            parity = parity && near(u, 0.0) && near(v, 0.0);
            apply(1, 1, &u, &v);
            parity = parity && near(u, 1.0) && near(v, 1.0);
            parity = parity && near(p.uvRow0[2], 0.0) && near(p.uvRow1[2], 0.0) &&
                     p.scissorX == 0 && p.scissorY == 0 &&
                     p.scissorWidth == kCanvasWidth && p.scissorHeight == kCanvasHeight;

            // Rotated lane-2 descriptor: canvas pixel (40,16) is the source
            // top-left corner -> (u,v) = (0,0); scissor = [24,40)x[16,48).
            const VulkanOverlayLayerDescriptor rotated = MakeLayer(quadA, 16, 24, 32, 16, kPi / 2.0);
            parity = parity && ComputeVulkanOverlayPlacement(rotated, kCanvasWidth, kCanvasHeight, &p) && p.visible;
            apply(40.0 / kCanvasWidth, 16.0 / kCanvasHeight, &u, &v);
            parity = parity && near(u, 0.0) && near(v, 0.0);
            parity = parity && p.scissorX == 24 && p.scissorY == 16 &&
                     p.scissorWidth == 16 && p.scissorHeight == 32;

            // Fully off-canvas placement is valid but invisible.
            parity = parity &&
                     ComputeVulkanOverlayPlacement(MakeLayer(solidRed, -100, -100, 32, 32),
                                                   kCanvasWidth, kCanvasHeight, &p) &&
                     !p.visible;

            // Pure validation parity with the fail-closed draw path.
            std::string vErr;
            parity = parity && ValidateVulkanOverlayLayerDescriptor(full, kCanvasWidth, kCanvasHeight, &vErr) &&
                     vErr.empty();
            VulkanOverlayLayerDescriptor noView = full;
            noView.imageView = VK_NULL_HANDLE;
            parity = parity &&
                     !ValidateVulkanOverlayLayerDescriptor(noView, kCanvasWidth, kCanvasHeight, &vErr) &&
                     vErr == kErrInvalidImage;
            parity = parity &&
                     !ValidateVulkanOverlayLayerDescriptor(MakeLayer(solidRed, 0, 0, 64, 64, 0.0, 1.0, 2.0),
                                                           kCanvasWidth, kCanvasHeight, &vErr) &&
                     vErr == kErrInvalidOpacity;
            parity = parity &&
                     !ValidateVulkanOverlayLayerDescriptor(full, 0, kCanvasHeight, &vErr) &&
                     vErr == kErrInvalidArgument;

            // Non-finite descriptor yields identity rows + invisible + false.
            const double nanRot = std::numeric_limits<double>::quiet_NaN();
            const bool nonFiniteIdentity =
                !ComputeVulkanOverlayPlacement(MakeLayer(solidRed, 0, 0, 64, 64, nanRot),
                                               kCanvasWidth, kCanvasHeight, &p) &&
                !p.visible &&
                near(p.uvRow0[0], 1.0) && near(p.uvRow0[1], 0.0) && near(p.uvRow0[3], 0.0) &&
                near(p.uvRow1[0], 0.0) && near(p.uvRow1[1], 1.0) && near(p.uvRow1[3], 0.0);
            parity = parity && nonFiniteIdentity;

            structParityOk = kStructParityCompileTimeOk && parity;
            details.Str("descriptorFields",
                        "imageView,sampler,x,y,width,height,rotation,scale,opacity,zIndex");
            details.Str("mirroredDartFields",
                        "translationX,translationY,width,height,rotation,scale,opacity,zIndex");
            details.Str("glesDescriptorFields",
                        "texture,textureTarget,x,y,width,height,rotation,scale,opacity,zIndex");
            details.Bool("descriptorStandardLayout", std::is_standard_layout<VulkanOverlayLayerDescriptor>::value);
            details.U64("descriptorSizeBytes", sizeof(VulkanOverlayLayerDescriptor));
            details.Str("zIndexRole", "telemetry_parity_only_caller_order_is_draw_order");
            if (!structParityOk) fail("struct_parity_failed");
        }
    }

    // ── Teardown: every object this diagnostic created ─────────────────────
    if (vk.device != VK_NULL_HANDLE) {
        vkDeviceWaitIdle(vk.device);
    }
    readback.Destroy(vk.device);
    colorTarget.Destroy(vk.device);
    quadA.Destroy(vk.device);
    halfGreen.Destroy(vk.device);
    solidGreen.Destroy(vk.device);
    solidBlue.Destroy(vk.device);
    solidRed.Destroy(vk.device);
    const bool hadDevice = vk.device != VK_NULL_HANDLE;
    vk.Teardown();
    // Lane 5 (diagnostic half): device drained before destruction and every
    // owned handle nulled. Only meaningful when a device existed.
    diagnosticTeardownOk = hadDevice && vk.teardownWaitIdleOk && vk.AllHandlesNull() &&
                           readback.IsNull() && colorTarget.IsNull() &&
                           quadA.IsNull() && halfGreen.IsNull() && solidGreen.IsNull() &&
                           solidBlue.IsNull() && solidRed.IsNull();
    details.Bool("teardownWaitIdleOk", vk.teardownWaitIdleOk);
    details.Bool("teardownHandlesNull", vk.AllHandlesNull() && readback.IsNull() && colorTarget.IsNull());
    if (hadDevice && !diagnosticTeardownOk) fail("diagnostic_teardown_incomplete");

    const bool lanesPass =
        vulkanSetupOk &&
        invalidImageRejectedOk && invalidDimensionsRejectedOk &&
        nonFiniteTransformRejectedOk && invalidOpacityRejectedOk && mixedListRejectedBeforeDrawOk &&
        singleLayerTransformOk && arbitraryRotationOk &&
        opacityBlendOk && alphaAccumulationOk &&
        multiLayerZOrderOk && existingContentsCompositeOk &&
        helperResourcesReleasedOk && diagnosticTeardownOk &&
        structParityOk;
    // Canonical route: every lane ran through the private helper against the
    // diagnostic-owned offscreen attachment with no lane skipped or
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
        << "\"nonFiniteTransformRejectedOk\":" << BoolStr(nonFiniteTransformRejectedOk) << ","
        << "\"invalidOpacityRejectedOk\":" << BoolStr(invalidOpacityRejectedOk) << ","
        << "\"mixedListRejectedBeforeDrawOk\":" << BoolStr(mixedListRejectedBeforeDrawOk) << ","
        << "\"singleLayerTransformOk\":" << BoolStr(singleLayerTransformOk) << ","
        << "\"arbitraryRotationOk\":" << BoolStr(arbitraryRotationOk) << ","
        << "\"opacityBlendOk\":" << BoolStr(opacityBlendOk) << ","
        << "\"alphaAccumulationOk\":" << BoolStr(alphaAccumulationOk) << ","
        << "\"multiLayerZOrderOk\":" << BoolStr(multiLayerZOrderOk) << ","
        << "\"existingContentsCompositeOk\":" << BoolStr(existingContentsCompositeOk) << ","
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
