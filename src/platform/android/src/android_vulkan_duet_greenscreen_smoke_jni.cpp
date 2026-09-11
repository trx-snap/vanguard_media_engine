// android_vulkan_duet_greenscreen_smoke_jni.cpp
// DUET-VULKAN-GREENSCREEN-PIXEL-PROOF: VulkanGreenScreenCompositor mask-blend
// pixel proof diagnostic JNI bridge.
//
// Android-only translation unit added via the CMake target_sources block.
// This is the composition root for the private
// vanguard::render::VulkanGreenScreenCompositor raster helper: it owns a
// temporary VkInstance/VkDevice/VkQueue/VkCommandPool, synthetic
// VK_FORMAT_R8G8B8A8_UNORM background/foreground sampled images and a
// VK_FORMAT_R8_UNORM mask sampled image (17x19, deliberately smaller than the
// 64x48 output so the mask sampler's scaling path is exercised), a 64x48
// offscreen color attachment, and a host-visible readback buffer created
// solely for proof on the calling thread. It calls
// VulkanGreenScreenCompositor::blendGreenScreen once, reads the pixels back,
// compares every output pixel against ComputeVulkanGreenScreenReferencePixel
// via MapVulkanGreenScreenMaskTexel (the same pure functions the compositor's
// own header exposes; no duplicate math), proves the compositor's own
// fail-closed ValidateVulkanGreenScreenInputs rejects bad input before any
// Vulkan object is created, proves helper temporary object created ==
// released, additionally calls blendGreenScreen once more into a second,
// caller-owned color target with readbackEnabled=false (no readback buffer /
// copy) to prove the no-readback render target path, and destroys every
// Vulkan object it created before returning a single flat JSON string.
//
// Runtime support: Android guarantees libvulkan from API 24 but not a usable
// GPU driver, so vkCreateInstance failure, zero physical devices, no
// suitable graphics queue family, or a missing RGBA8/R8 optimal-tiling
// feature set report status "UNSUPPORTED" with a fail-shaped payload instead
// of crashing.
//
// Non-claim: synthetic mask-blend pixel proof only. No camera, no
// MediaCodec decode, no AHardwareBuffer/external image import, no
// production Duet preview/export route (AndroidDuetPreviewCompositor /
// AndroidDuetExportSession / AndroidDuetGreenScreenAdapter /
// AndroidDuetSegmentationBackendSelector are never referenced), no
// production VulkanBackend mutation, no app/editor/product UI.
// Proof boundary:
// native_vulkan_duet_greenscreen_mask_blend_pixel_proof_synthetic_only_no_camera_no_decode_no_export_no_product
//
// JNI entry point (matching VanguardNativeBridge.kt declaration):
//   runAndroidDuetVulkanPixelProofSmoke -> jstring (JSON)

#include <jni.h>

#include <vulkan/vulkan.h>

#include <cstdint>
#include <cstdio>
#include <cstring>
#include <sstream>
#include <string>
#include <vector>

#include "vulkan_greenscreen_compositor.h"

namespace {

using vanguard::render::ComputeVulkanGreenScreenReferencePixel;
using vanguard::render::kVulkanGreenScreenBlendFormula;
using vanguard::render::kVulkanGreenScreenColorContract;
using vanguard::render::kVulkanGreenScreenColorFormatValue;
using vanguard::render::kVulkanGreenScreenMaskFormatValue;
using vanguard::render::kVulkanGreenScreenReferenceColorTolerance;
using vanguard::render::kVulkanGreenScreenShaderSource;
using vanguard::render::MapVulkanGreenScreenMaskTexel;
using vanguard::render::ValidateVulkanGreenScreenInputs;
using vanguard::render::VulkanGreenScreenCompositor;
using vanguard::render::VulkanGreenScreenInputs;
using vanguard::render::VulkanGreenScreenPixelWithinTolerance;
using vanguard::render::VulkanGreenScreenRenderTarget;
using vanguard::render::VulkanGreenScreenSampledImage;

constexpr const char* kProofBoundary =
    "native_vulkan_duet_greenscreen_mask_blend_pixel_proof_synthetic_only_no_camera_no_decode_no_export_no_product";
constexpr const char* kPassMarker = "ANDROID_DUET_VULKAN_PIXEL_PROOF_PHYSICAL_PASS";
constexpr const char* kFailMarker = "ANDROID_DUET_VULKAN_PIXEL_PROOF_PHYSICAL_FAIL";

constexpr uint32_t kOutputWidth  = 64;
constexpr uint32_t kOutputHeight = 48;
constexpr uint32_t kMaskWidth    = 17;
constexpr uint32_t kMaskHeight   = 19;
static_assert(kMaskWidth != kOutputWidth && kMaskHeight != kOutputHeight,
              "mask resolution must differ from output resolution");

constexpr VkFormat kColorFormat = VK_FORMAT_R8G8B8A8_UNORM;
constexpr VkFormat kMaskFormat  = VK_FORMAT_R8_UNORM;
constexpr VkDeviceSize kReadbackBytes =
    static_cast<VkDeviceSize>(kOutputWidth) * kOutputHeight * 4;

// Documented ValidateVulkanGreenScreenInputs failure reasons (see
// vulkan_greenscreen_compositor.h); not exported as constants there, so
// pinned here as the contract literal.
constexpr const char* kErrInvalidArgument = "vulkan_greenscreen_compositor_invalid_argument";
constexpr const char* kErrInvalidFormat   = "vulkan_greenscreen_compositor_invalid_format";
constexpr const char* kErrInvalidImage    = "vulkan_greenscreen_compositor_invalid_image";
constexpr const char* kErrInvalidMaskSize = "vulkan_greenscreen_compositor_invalid_mask_size";

// Straight-alpha RGBA background/foreground; differing alpha exercises the
// out.a = mix(bg.a, fg.a, maskAlpha) leg of the blend formula too.
constexpr uint8_t kBackground[4] = {30, 60, 200, 255};
constexpr uint8_t kForeground[4] = {230, 120, 20, 180};

// One mask value per row (uniform across all 17 columns of that row),
// spanning the full [0,255] range: rows 0-1 are exactly 0 (proves
// alphaZeroPreservesBackgroundOk), rows 17-18 are exactly 255 (proves
// alphaFullForegroundOk), and the remaining rows are strictly-interior
// values, including 64/128/192 (proves alphaFractionalBlendOk).
constexpr uint8_t kMaskRowValues[kMaskHeight] = {
    0, 0, 16, 32, 48, 64, 80, 96, 112, 128, 144, 160, 176, 192, 208, 224, 240, 255, 255,
};

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

    // Returns false with *outUnsupported == true when Vulkan (or the two
    // pinned formats' required feature set) is structurally unavailable on
    // this device (no crash), or *outUnsupported == false for a genuine
    // failure.
    bool Setup(std::string* outError, bool* outUnsupported) {
        *outUnsupported = false;
        VkApplicationInfo appInfo{};
        appInfo.sType              = VK_STRUCTURE_TYPE_APPLICATION_INFO;
        appInfo.pApplicationName   = "VanguardDuetGreenScreenVulkanSmoke";
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

            VkFormatProperties colorFmt{};
            vkGetPhysicalDeviceFormatProperties(dev, kColorFormat, &colorFmt);
            const VkFormatFeatureFlags neededColor =
                VK_FORMAT_FEATURE_COLOR_ATTACHMENT_BIT | VK_FORMAT_FEATURE_SAMPLED_IMAGE_BIT |
                VK_FORMAT_FEATURE_TRANSFER_SRC_BIT | VK_FORMAT_FEATURE_TRANSFER_DST_BIT;
            if ((colorFmt.optimalTilingFeatures & neededColor) != neededColor) continue;

            VkFormatProperties maskFmt{};
            vkGetPhysicalDeviceFormatProperties(dev, kMaskFormat, &maskFmt);
            const VkFormatFeatureFlags neededMask =
                VK_FORMAT_FEATURE_SAMPLED_IMAGE_BIT | VK_FORMAT_FEATURE_TRANSFER_DST_BIT;
            if ((maskFmt.optimalTilingFeatures & neededMask) != neededMask) continue;

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
                       VkFormat format,
                       uint32_t width,
                       uint32_t height,
                       VkImageUsageFlags usage,
                       ScratchImage& out,
                       std::string* outError) {
    VkImageCreateInfo imgCI{};
    imgCI.sType         = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO;
    imgCI.imageType     = VK_IMAGE_TYPE_2D;
    imgCI.format        = format;
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
    viewCI.format                      = format;
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

// Uploads tightly packed rows (row 0 == top) into `img` through a temporary
// staging buffer and one-time command buffer, leaving the image in
// SHADER_READ_ONLY_OPTIMAL, then creates its NEAREST / CLAMP_TO_EDGE sampler
// -- the compositor header's pinned sampler contract for all three inputs.
bool UploadSampledImage(const VulkanScratch& vk,
                        ScratchImage& img,
                        const uint8_t* data,
                        uint32_t width,
                        uint32_t height,
                        uint32_t bytesPerPixel,
                        std::string* outError) {
    const VkDeviceSize bytes = static_cast<VkDeviceSize>(width) * height * bytesPerPixel;
    ScratchBuffer staging;
    bool ok = CreateHostBuffer(vk, bytes, VK_BUFFER_USAGE_TRANSFER_SRC_BIT, staging, outError);
    VkCommandBuffer cb = VK_NULL_HANDLE;
    if (ok) {
        std::memcpy(staging.mapped, data, static_cast<size_t>(bytes));
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

std::string RgbaString(const uint8_t* p) {
    char buf[48];
    std::snprintf(buf, sizeof(buf), "%u,%u,%u,%u", p[0], p[1], p[2], p[3]);
    return buf;
}

std::string VersionString(uint32_t v) {
    return std::to_string(VK_VERSION_MAJOR(v)) + "." + std::to_string(VK_VERSION_MINOR(v)) + "." +
           std::to_string(VK_VERSION_PATCH(v));
}

// Expects blendGreenScreen to reject (target, inputs) with exactly
// `expectedError`, and that doing so created zero temporary Vulkan objects
// (the header's fail-closed contract).
bool ExpectRejected(VulkanGreenScreenCompositor& compositor,
                    const VulkanGreenScreenRenderTarget& target,
                    const VulkanGreenScreenInputs& inputs,
                    const char* expectedError,
                    std::string* outActual) {
    std::string err;
    const bool drew = compositor.blendGreenScreen(target, inputs, &err);
    *outActual = err;
    return !drew && err == expectedError;
}

} // namespace

extern "C" JNIEXPORT jstring JNICALL
Java_com_connects_vanguard_1media_1engine_bridge_VanguardNativeBridge_runAndroidDuetVulkanPixelProofSmoke(
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
    details.U64("outputWidth", kOutputWidth);
    details.U64("outputHeight", kOutputHeight);
    details.U64("maskWidth", kMaskWidth);
    details.U64("maskHeight", kMaskHeight);
    details.Int("colorTolerance", kVulkanGreenScreenReferenceColorTolerance);
    details.Str("shaderSource", kVulkanGreenScreenShaderSource);
    details.Str("colorContract", kVulkanGreenScreenColorContract);
    details.Str("blendFormula", kVulkanGreenScreenBlendFormula);

    // Gate flags (all default false; every lane must set its own true).
    bool vulkanCoreReady = false;
    bool maskUploadOk = false;
    bool maskResolutionMismatchOk = false;
    bool alphaZeroPreservesBackgroundOk = false;
    bool alphaFullForegroundOk = false;
    bool alphaFractionalBlendOk = false;
    bool cpuReferenceParityOk = false;
    bool colorContractPinnedOk = false;
    bool capabilityFallbackReportedOk = false;
    bool noReadbackRenderOk = false;
    bool cleanupOk = false;
    bool canonical = false;
    bool unsupported = false;

    VulkanScratch vk;
    ScratchImage backgroundImg, foregroundImg, maskImg, colorTarget, noReadbackColorTarget;
    ScratchBuffer readback;

    {
        std::string setupError;
        vulkanCoreReady = vk.Setup(&setupError, &unsupported);
        details.Bool("vulkanDeviceInitOk", vulkanCoreReady);
        details.Bool("vulkanUnsupported", unsupported);
        if (!vulkanCoreReady) {
            fail((unsupported ? "vulkan_unsupported:" : "vulkan_setup_failed:") + setupError);
            details.Str("vulkanSetupError", setupError);
        }
    }

    VulkanGreenScreenCompositor compositor;

    if (vulkanCoreReady) {
        details.Str("deviceName", vk.deviceName);
        details.U64("deviceType", vk.deviceType);
        details.Str("apiVersion", VersionString(vk.apiVersion));
        details.U64("driverVersion", vk.driverVersion);
        details.U64("queueFamilyIndex", vk.queueFamily);
        capabilityFallbackReportedOk =
            !vk.deviceName.empty() && vk.apiVersion != 0;

        // ── Synthetic resources: 1x1 flat background/foreground, 17x19 mask ─
        std::string err;
        bool ok = CreateDeviceImage(vk, kColorFormat, 1, 1,
                                    VK_IMAGE_USAGE_SAMPLED_BIT | VK_IMAGE_USAGE_TRANSFER_DST_BIT,
                                    backgroundImg, &err) &&
                  UploadSampledImage(vk, backgroundImg, kBackground, 1, 1, 4, &err) &&
                  CreateDeviceImage(vk, kColorFormat, 1, 1,
                                    VK_IMAGE_USAGE_SAMPLED_BIT | VK_IMAGE_USAGE_TRANSFER_DST_BIT,
                                    foregroundImg, &err) &&
                  UploadSampledImage(vk, foregroundImg, kForeground, 1, 1, 4, &err) &&
                  CreateDeviceImage(vk, kColorFormat, kOutputWidth, kOutputHeight,
                                    VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | VK_IMAGE_USAGE_TRANSFER_SRC_BIT,
                                    colorTarget, &err) &&
                  CreateDeviceImage(vk, kColorFormat, kOutputWidth, kOutputHeight,
                                    VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT,
                                    noReadbackColorTarget, &err) &&
                  CreateHostBuffer(vk, kReadbackBytes, VK_BUFFER_USAGE_TRANSFER_DST_BIT, readback, &err);
        if (ok) {
            std::vector<uint8_t> maskPixels(static_cast<size_t>(kMaskWidth) * kMaskHeight);
            for (uint32_t y = 0; y < kMaskHeight; ++y) {
                for (uint32_t x = 0; x < kMaskWidth; ++x) {
                    maskPixels[static_cast<size_t>(y) * kMaskWidth + x] = kMaskRowValues[y];
                }
            }
            ok = CreateDeviceImage(vk, kMaskFormat, kMaskWidth, kMaskHeight,
                                   VK_IMAGE_USAGE_SAMPLED_BIT | VK_IMAGE_USAGE_TRANSFER_DST_BIT,
                                   maskImg, &err) &&
                 UploadSampledImage(vk, maskImg, maskPixels.data(), kMaskWidth, kMaskHeight, 1, &err);
        }
        maskUploadOk = ok;
        details.Bool("syntheticResourcesOk", ok);
        details.Bool("readbackMemoryCoherent", readback.coherent);
        if (!ok) {
            fail("synthetic_vulkan_resource_creation_failed:" + err);
            details.Str("syntheticResourceError", err);
        }
    }

    if (maskUploadOk) {
        VulkanGreenScreenRenderTarget target;
        target.device                  = vk.device;
        target.queue                   = vk.queue;
        target.commandPool             = vk.commandPool;
        target.colorImage              = colorTarget.image;
        target.colorImageView          = colorTarget.view;
        target.colorFormat             = kColorFormat;
        target.readbackBuffer          = readback.buffer;
        target.readbackBufferSizeBytes = readback.size;
        target.extentWidth             = kOutputWidth;
        target.extentHeight            = kOutputHeight;

        VulkanGreenScreenInputs inputs;
        inputs.background.imageView = backgroundImg.view;
        inputs.background.sampler   = backgroundImg.sampler;
        inputs.foreground.imageView = foregroundImg.view;
        inputs.foreground.sampler   = foregroundImg.sampler;
        inputs.mask.imageView       = maskImg.view;
        inputs.mask.sampler         = maskImg.sampler;
        inputs.maskWidth            = kMaskWidth;
        inputs.maskHeight           = kMaskHeight;

        // ── Contract lane: pinned format constants + fail-closed validation
        // (every ExpectRejected call must create zero temporary objects). ──
        {
            bool ok = kVulkanGreenScreenColorFormatValue == 37u &&
                     kVulkanGreenScreenMaskFormatValue == 9u &&
                     kVulkanGreenScreenReferenceColorTolerance == 1;
            std::string actual;

            VulkanGreenScreenRenderTarget t = target; t.device = VK_NULL_HANDLE;
            ok = ok && ExpectRejected(compositor, t, inputs, kErrInvalidArgument, &actual);
            t = target; t.extentWidth = 0;
            ok = ok && ExpectRejected(compositor, t, inputs, kErrInvalidArgument, &actual);
            t = target; t.readbackBufferSizeBytes = kReadbackBytes - 4;
            ok = ok && ExpectRejected(compositor, t, inputs, kErrInvalidArgument, &actual);
            t = target; t.finalLayout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL;
            ok = ok && ExpectRejected(compositor, t, inputs, kErrInvalidArgument, &actual);
            t = target; t.colorFormat = VK_FORMAT_R8G8B8A8_SRGB;
            ok = ok && ExpectRejected(compositor, t, inputs, kErrInvalidFormat, &actual);

            VulkanGreenScreenInputs badImg = inputs; badImg.background.imageView = VK_NULL_HANDLE;
            ok = ok && ExpectRejected(compositor, target, badImg, kErrInvalidImage, &actual);
            badImg = inputs; badImg.mask.sampler = VK_NULL_HANDLE;
            ok = ok && ExpectRejected(compositor, target, badImg, kErrInvalidImage, &actual);

            VulkanGreenScreenInputs badMask = inputs; badMask.maskWidth = 0;
            ok = ok && ExpectRejected(compositor, target, badMask, kErrInvalidMaskSize, &actual);

            const bool noVulkanObjectsFromValidation =
                compositor.temporaryObjectsCreated() == 0 && compositor.temporaryObjectsReleased() == 0;
            details.Bool("noVulkanObjectsFromValidation", noVulkanObjectsFromValidation);
            details.Str("lastValidationError", actual);
            colorContractPinnedOk = ok && noVulkanObjectsFromValidation;
            if (!colorContractPinnedOk) fail("color_contract_or_validation_lane_failed");
        }

        // ── Real render + full-image CPU reference parity ──────────────────
        std::string renderErr;
        const bool renderOk = compositor.blendGreenScreen(target, inputs, &renderErr);
        details.Bool("renderOk", renderOk);
        if (!renderOk) {
            fail("blend_green_screen_failed:" + renderErr);
            details.Str("renderError", renderErr);
        } else {
            InvalidateIfNeeded(vk, readback);
            std::vector<uint8_t> pixels(static_cast<size_t>(kReadbackBytes));
            std::memcpy(pixels.data(), readback.mapped, static_cast<size_t>(kReadbackBytes));

            uint64_t mismatchCount = 0;
            std::string firstMismatch;
            uint64_t zeroCount = 0, fullCount = 0, fractionalCount = 0;
            bool zeroOk = true, fullOk = true, fractionalOk = true;

            for (uint32_t y = 0; y < kOutputHeight; ++y) {
                for (uint32_t x = 0; x < kOutputWidth; ++x) {
                    uint32_t mx = 0, my = 0;
                    MapVulkanGreenScreenMaskTexel(x, y, kOutputWidth, kOutputHeight,
                                                  kMaskWidth, kMaskHeight, &mx, &my);
                    const uint8_t maskValue = kMaskRowValues[my];
                    uint8_t expected[4];
                    ComputeVulkanGreenScreenReferencePixel(kBackground, kForeground, maskValue, expected);

                    const uint8_t* actual = &pixels[(static_cast<size_t>(y) * kOutputWidth + x) * 4];
                    int maxDelta = 0;
                    const bool withinTolerance = VulkanGreenScreenPixelWithinTolerance(
                        actual, expected, kVulkanGreenScreenReferenceColorTolerance, &maxDelta);
                    if (!withinTolerance) {
                        if (mismatchCount == 0) {
                            firstMismatch = std::to_string(x) + "," + std::to_string(y) +
                                           " mask=" + std::to_string(maskValue) +
                                           " actual=" + RgbaString(actual) +
                                           " expected=" + RgbaString(expected);
                        }
                        ++mismatchCount;
                    }

                    if (maskValue == 0) {
                        ++zeroCount;
                        int delta = 0;
                        if (!VulkanGreenScreenPixelWithinTolerance(actual, kBackground, 0, &delta)) zeroOk = false;
                    } else if (maskValue == 255) {
                        ++fullCount;
                        int delta = 0;
                        if (!VulkanGreenScreenPixelWithinTolerance(actual, kForeground, 0, &delta)) fullOk = false;
                    } else {
                        ++fractionalCount;
                        const bool matchesBackground =
                            std::memcmp(actual, kBackground, 4) == 0;
                        const bool matchesForeground =
                            std::memcmp(actual, kForeground, 4) == 0;
                        if (!withinTolerance || matchesBackground || matchesForeground) {
                            fractionalOk = false;
                        }
                    }
                }
            }

            details.U64("mismatchCount", mismatchCount);
            details.Str("firstMismatch", mismatchCount == 0 ? "" : firstMismatch);
            details.U64("alphaZeroPixelCount", zeroCount);
            details.U64("alphaFullPixelCount", fullCount);
            details.U64("alphaFractionalPixelCount", fractionalCount);

            cpuReferenceParityOk = mismatchCount == 0;
            alphaZeroPreservesBackgroundOk = zeroOk && zeroCount > 0;
            alphaFullForegroundOk = fullOk && fullCount > 0;
            alphaFractionalBlendOk = fractionalOk && fractionalCount > 0;
            maskResolutionMismatchOk =
                (kMaskWidth != kOutputWidth) && (kMaskHeight != kOutputHeight) && cpuReferenceParityOk;

            if (!cpuReferenceParityOk) fail("cpu_reference_parity_failed");
            if (!alphaZeroPreservesBackgroundOk) fail("alpha_zero_preserves_background_failed");
            if (!alphaFullForegroundOk) fail("alpha_full_foreground_failed");
            if (!alphaFractionalBlendOk) fail("alpha_fractional_blend_failed");
            if (!maskResolutionMismatchOk) fail("mask_resolution_mismatch_lane_failed");
        }

        // ── No-readback render target lane: proves blendGreenScreen() accepts
        // a caller-owned color target with readbackEnabled=false (no readback
        // buffer / copy), for future preview/swapchain-style callers. This
        // does not itself wire up or promote the production Duet preview
        // route (AndroidDuetPreviewCompositor / AndroidDuetExportSession are
        // never referenced). ──
        {
            VulkanGreenScreenRenderTarget noReadbackTarget = target;
            noReadbackTarget.colorImage              = noReadbackColorTarget.image;
            noReadbackTarget.colorImageView          = noReadbackColorTarget.view;
            noReadbackTarget.readbackEnabled         = false;
            noReadbackTarget.readbackBuffer          = VK_NULL_HANDLE;
            noReadbackTarget.readbackBufferSizeBytes = 0;
            noReadbackTarget.finalLayout             = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL;

            std::string noReadbackErr;
            noReadbackRenderOk = compositor.blendGreenScreen(noReadbackTarget, inputs, &noReadbackErr);
            details.Bool("noReadbackRenderOk", noReadbackRenderOk);
            if (!noReadbackRenderOk) {
                fail("no_readback_render_failed:" + noReadbackErr);
                details.Str("noReadbackRenderError", noReadbackErr);
            }
        }
    }

    // ── Teardown: every object this diagnostic created ─────────────────────
    if (vk.device != VK_NULL_HANDLE) {
        vkDeviceWaitIdle(vk.device);
    }
    readback.Destroy(vk.device);
    colorTarget.Destroy(vk.device);
    noReadbackColorTarget.Destroy(vk.device);
    maskImg.Destroy(vk.device);
    foregroundImg.Destroy(vk.device);
    backgroundImg.Destroy(vk.device);
    const bool hadDevice = vk.device != VK_NULL_HANDLE;
    vk.Teardown();

    const uint64_t helperCreated  = compositor.temporaryObjectsCreated();
    const uint64_t helperReleased = compositor.temporaryObjectsReleased();
    details.U64("helperTemporaryObjectsCreated", helperCreated);
    details.U64("helperTemporaryObjectsReleased", helperReleased);
    details.Bool("teardownWaitIdleOk", vk.teardownWaitIdleOk);
    const bool allHandlesNull =
        vk.AllHandlesNull() && readback.IsNull() && colorTarget.IsNull() &&
        noReadbackColorTarget.IsNull() && maskImg.IsNull() && foregroundImg.IsNull() &&
        backgroundImg.IsNull();
    details.Bool("teardownHandlesNull", allHandlesNull);

    cleanupOk = (!hadDevice) ||
               (vk.teardownWaitIdleOk && allHandlesNull && helperCreated == helperReleased);
    if (hadDevice && !cleanupOk) fail("cleanup_incomplete");

    if (!unsupported && !vulkanCoreReady) {
        // Genuine setup failure with a usable-looking driver still reports no
        // capability facts; leave capabilityFallbackReportedOk false.
    } else if (unsupported) {
        capabilityFallbackReportedOk = !failureReason.empty();
    }
    details.Bool("capabilityFallbackReportedOk", capabilityFallbackReportedOk);

    const bool lanesPass =
        vulkanCoreReady && maskUploadOk && maskResolutionMismatchOk &&
        alphaZeroPreservesBackgroundOk && alphaFullForegroundOk && alphaFractionalBlendOk &&
        cpuReferenceParityOk && colorContractPinnedOk && capabilityFallbackReportedOk &&
        noReadbackRenderOk && cleanupOk;
    canonical = lanesPass && failureReason.empty();
    const bool allNativeLanesPass = canonical;

    const char* status = allNativeLanesPass ? "PASS" : (unsupported ? "UNSUPPORTED" : "FAIL");

    std::ostringstream oss;
    oss << "{"
        << "\"pass\":" << BoolStr(allNativeLanesPass) << ","
        << "\"status\":\"" << status << "\","
        << "\"marker\":\"" << (allNativeLanesPass ? kPassMarker : kFailMarker) << "\","
        << "\"proofBoundary\":\"" << kProofBoundary << "\","
        << "\"failureReason\":\"" << JsonEscape(failureReason) << "\","
        << "\"vulkanCoreReady\":" << BoolStr(vulkanCoreReady) << ","
        << "\"maskUploadOk\":" << BoolStr(maskUploadOk) << ","
        << "\"maskResolutionMismatchOk\":" << BoolStr(maskResolutionMismatchOk) << ","
        << "\"alphaZeroPreservesBackgroundOk\":" << BoolStr(alphaZeroPreservesBackgroundOk) << ","
        << "\"alphaFullForegroundOk\":" << BoolStr(alphaFullForegroundOk) << ","
        << "\"alphaFractionalBlendOk\":" << BoolStr(alphaFractionalBlendOk) << ","
        << "\"cpuReferenceParityOk\":" << BoolStr(cpuReferenceParityOk) << ","
        << "\"colorContractPinnedOk\":" << BoolStr(colorContractPinnedOk) << ","
        << "\"capabilityFallbackReportedOk\":" << BoolStr(capabilityFallbackReportedOk) << ","
        << "\"noReadbackRenderOk\":" << BoolStr(noReadbackRenderOk) << ","
        << "\"cleanupOk\":" << BoolStr(cleanupOk) << ","
        << "\"canonical\":" << BoolStr(canonical) << ","
        << "\"allNativeLanesPass\":" << BoolStr(allNativeLanesPass) << ","
        << "\"nativeAllLanesPass\":" << BoolStr(allNativeLanesPass) << ","
        << "\"details\":" << details.Json()
        << "}";

    const std::string resultStr = oss.str();
    return env->NewStringUTF(resultStr.c_str());
}
