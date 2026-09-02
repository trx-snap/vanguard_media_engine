// P5-COMPOSITOR-TRANS (sub-slice DUAL-DECODER-SYNC): private diagnostic
// Vulkan / AHardwareBuffer support implementation. See the header for the
// ownership split; the JNI translation unit owns validation and result
// shaping, this file owns the import / resolve / render mechanics.
//
// Diagnostic only: no export session, no production VulkanBackend mutation,
// no encoder/mux, no audio, no app UI.

#include "android_phase5_timeline_dual_decoder_sync_vulkan_support.h"

#include <dlfcn.h>

#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>

#include "vanguard/render/render_transform.h"
#include "shaders/passthrough_frag_spv.h"
#include "shaders/passthrough_vert_spv.h"
#include "vulkan_graphics_pipeline.h"
#include "vulkan_shader_module.h"

namespace vanguard::android_diag::dual_decoder_sync {

using vanguard::compositors::TimelineNormalizedRect;
using vanguard::compositors::TimelineTransitionProgress;
using vanguard::render::HardwareBufferImportResult;
using vanguard::render::VideoTransformFullPushConstants;
using vanguard::render::VulkanGraphicsPipeline;
using vanguard::render::VulkanShaderModule;
using vanguard::render::VulkanTimelineNormalizedRect;
using vanguard::render::VulkanTimelineTransitionCompositor;
using vanguard::render::VulkanTimelineTransitionGeometry;
using vanguard::render::VulkanTimelineTransitionLayerImage;

namespace {

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

bool DeviceHasExtension(const std::vector<VkExtensionProperties>& exts, const char* name) {
    for (const VkExtensionProperties& e : exts) {
        if (std::strcmp(e.extensionName, name) == 0) return true;
    }
    return false;
}

VulkanTimelineNormalizedRect ToVulkanRect(const TimelineNormalizedRect& r) {
    VulkanTimelineNormalizedRect out;
    out.x      = r.x;
    out.y      = r.y;
    out.width  = r.width;
    out.height = r.height;
    return out;
}

// Every temporary object of one resolve pass; destroyed in reverse order.
struct ResolveObjects {
    VulkanShaderModule     vert;
    VulkanShaderModule     frag;
    VkRenderPass           renderPass    = VK_NULL_HANDLE;
    VkFramebuffer          framebuffer   = VK_NULL_HANDLE;
    VulkanGraphicsPipeline pipeline;
    VkCommandBuffer        commandBuffer = VK_NULL_HANDLE;
    VkFence                fence         = VK_NULL_HANDLE;

    void Destroy(const VulkanScratch& vk) {
        if (vk.device == VK_NULL_HANDLE) return;
        if (fence != VK_NULL_HANDLE) { vkDestroyFence(vk.device, fence, nullptr); fence = VK_NULL_HANDLE; }
        if (commandBuffer != VK_NULL_HANDLE) {
            vkFreeCommandBuffers(vk.device, vk.commandPool, 1, &commandBuffer);
            commandBuffer = VK_NULL_HANDLE;
        }
        pipeline.destroy(vk.device);
        if (framebuffer != VK_NULL_HANDLE) { vkDestroyFramebuffer(vk.device, framebuffer, nullptr); framebuffer = VK_NULL_HANDLE; }
        if (renderPass != VK_NULL_HANDLE) { vkDestroyRenderPass(vk.device, renderPass, nullptr); renderPass = VK_NULL_HANDLE; }
        frag.destroy(vk.device);
        vert.destroy(vk.device);
    }
};

bool CreateResolveRenderPass(const VulkanScratch& vk, VkRenderPass* outPass) {
    VkAttachmentDescription color{};
    color.format         = kColorFormat;
    color.samples        = VK_SAMPLE_COUNT_1_BIT;
    color.loadOp         = VK_ATTACHMENT_LOAD_OP_CLEAR;
    color.storeOp        = VK_ATTACHMENT_STORE_OP_STORE;
    color.stencilLoadOp  = VK_ATTACHMENT_LOAD_OP_DONT_CARE;
    color.stencilStoreOp = VK_ATTACHMENT_STORE_OP_DONT_CARE;
    color.initialLayout  = VK_IMAGE_LAYOUT_UNDEFINED;
    color.finalLayout    = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;

    VkAttachmentReference colorRef{};
    colorRef.attachment = 0;
    colorRef.layout     = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL;

    VkSubpassDescription subpass{};
    subpass.pipelineBindPoint    = VK_PIPELINE_BIND_POINT_GRAPHICS;
    subpass.colorAttachmentCount = 1;
    subpass.pColorAttachments    = &colorRef;

    VkSubpassDependency deps[2]{};
    deps[0].srcSubpass    = VK_SUBPASS_EXTERNAL;
    deps[0].dstSubpass    = 0;
    deps[0].srcStageMask  = VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT;
    deps[0].dstStageMask  = VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT;
    deps[0].srcAccessMask = 0;
    deps[0].dstAccessMask = VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT;
    deps[1].srcSubpass    = 0;
    deps[1].dstSubpass    = VK_SUBPASS_EXTERNAL;
    deps[1].srcStageMask  = VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT;
    deps[1].dstStageMask  = VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT;
    deps[1].srcAccessMask = VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT;
    deps[1].dstAccessMask = VK_ACCESS_SHADER_READ_BIT;

    VkRenderPassCreateInfo rpCI{};
    rpCI.sType           = VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO;
    rpCI.attachmentCount = 1;
    rpCI.pAttachments    = &color;
    rpCI.subpassCount    = 1;
    rpCI.pSubpasses      = &subpass;
    rpCI.dependencyCount = 2;
    rpCI.pDependencies   = deps;
    if (vkCreateRenderPass(vk.device, &rpCI, nullptr, outPass) != VK_SUCCESS) {
        *outPass = VK_NULL_HANDLE;
        return false;
    }
    return true;
}

// Records the fullscreen-triangle resolve draw (layout transition of the
// imported image, render pass, viewport/scissor, pipeline, descriptor set,
// crop-selecting UV transform with identity color matrix, draw).
void RecordResolveDraw(VkCommandBuffer cb,
                       const ResolveObjects& r,
                       const ImportedFrame& frame) {
    // Imported image: UNDEFINED -> SHADER_READ_ONLY_OPTIMAL before sampling
    // (same masks / ignored queue families as the production frame path).
    frame.image.recordLayoutTransition(
        cb,
        VK_IMAGE_LAYOUT_UNDEFINED,
        VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
        VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT,
        VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT,
        0,
        VK_ACCESS_SHADER_READ_BIT);

    VkClearValue clearValue{};
    clearValue.color = {{0.0f, 0.0f, 0.0f, 1.0f}};
    VkRenderPassBeginInfo rpBegin{};
    rpBegin.sType             = VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO;
    rpBegin.renderPass        = r.renderPass;
    rpBegin.framebuffer       = r.framebuffer;
    rpBegin.renderArea.offset = {0, 0};
    rpBegin.renderArea.extent = {frame.cropWidth, frame.cropHeight};
    rpBegin.clearValueCount   = 1;
    rpBegin.pClearValues      = &clearValue;
    vkCmdBeginRenderPass(cb, &rpBegin, VK_SUBPASS_CONTENTS_INLINE);

    VkViewport viewport{};
    viewport.x        = 0.0f;
    viewport.y        = 0.0f;
    viewport.width    = static_cast<float>(frame.cropWidth);
    viewport.height   = static_cast<float>(frame.cropHeight);
    viewport.minDepth = 0.0f;
    viewport.maxDepth = 1.0f;
    vkCmdSetViewport(cb, 0, 1, &viewport);
    VkRect2D scissor{};
    scissor.offset = {0, 0};
    scissor.extent = {frame.cropWidth, frame.cropHeight};
    vkCmdSetScissor(cb, 0, 1, &scissor);

    vkCmdBindPipeline(cb, VK_PIPELINE_BIND_POINT_GRAPHICS, r.pipeline.get());
    VkDescriptorSet set = frame.image.descriptorResources.descriptorSet;
    vkCmdBindDescriptorSets(cb, VK_PIPELINE_BIND_POINT_GRAPHICS,
                            frame.image.descriptorResources.pipelineLayout, 0, 1, &set, 0, nullptr);

    // UV transform selects the declared crop out of the (possibly padded)
    // buffer extent; identity color matrix.
    VideoTransformFullPushConstants pc{};
    pc.uv.uvTransform0[0] = static_cast<float>(frame.cropWidth) / static_cast<float>(frame.buffer.desc.width);
    pc.uv.uvTransform0[1] = 0.0f;
    pc.uv.uvTransform0[2] = 0.0f;
    pc.uv.uvTransform0[3] = 0.0f;
    pc.uv.uvTransform1[0] = 0.0f;
    pc.uv.uvTransform1[1] = static_cast<float>(frame.cropHeight) / static_cast<float>(frame.buffer.desc.height);
    pc.uv.uvTransform1[2] = 0.0f;
    pc.uv.uvTransform1[3] = 0.0f;
    pc.color.row0[0] = 1.0f;
    pc.color.row1[1] = 1.0f;
    pc.color.row2[2] = 1.0f;
    pc.color.row3[3] = 1.0f;
    vkCmdPushConstants(cb, frame.image.descriptorResources.pipelineLayout,
                       VK_SHADER_STAGE_VERTEX_BIT | VK_SHADER_STAGE_FRAGMENT_BIT,
                       0, static_cast<uint32_t>(sizeof(pc)), &pc);
    vkCmdDraw(cb, 3, 1, 0, 0);
    vkCmdEndRenderPass(cb);
}

} // namespace

// ── AndroidBufferApi / AcquiredBuffer ───────────────────────────────────────

bool AndroidBufferApi::Load(std::string* outError) {
    lib = dlopen("libandroid.so", RTLD_NOW | RTLD_LOCAL);
    if (!lib) {
        *outError = "libandroid_dlopen_failed";
        return false;
    }
    fromHardwareBuffer = reinterpret_cast<FnAHardwareBufferFromHardwareBuffer>(
        dlsym(lib, "AHardwareBuffer_fromHardwareBuffer"));
    acquire  = reinterpret_cast<FnAHardwareBufferAcquire>(dlsym(lib, "AHardwareBuffer_acquire"));
    release  = reinterpret_cast<FnAHardwareBufferRelease>(dlsym(lib, "AHardwareBuffer_release"));
    describe = reinterpret_cast<FnAHardwareBufferDescribe>(dlsym(lib, "AHardwareBuffer_describe"));
    if (!fromHardwareBuffer || !acquire || !release || !describe) {
        *outError = "libandroid_ahardwarebuffer_symbols_unavailable";
        Unload();
        return false;
    }
    return true;
}

void AndroidBufferApi::Unload() {
    if (lib) {
        dlclose(lib);
        lib = nullptr;
    }
    fromHardwareBuffer = nullptr;
    acquire = nullptr;
    release = nullptr;
    describe = nullptr;
}

void AcquiredBuffer::Release(const AndroidBufferApi& api) {
    if (ahb && acquired && api.release) {
        api.release(ahb);
    }
    ahb = nullptr;
    acquired = false;
}

// ── VulkanScratch ───────────────────────────────────────────────────────────

bool VulkanScratch::Setup(std::string* outError, bool* outUnsupported) {
    *outUnsupported = false;
    VkApplicationInfo appInfo{};
    appInfo.sType              = VK_STRUCTURE_TYPE_APPLICATION_INFO;
    appInfo.pApplicationName   = "VanguardTimelineDualDecoderSyncSmoke";
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

    auto fnFeatures2 = reinterpret_cast<PFN_vkGetPhysicalDeviceFeatures2>(
        vkGetInstanceProcAddr(instance, "vkGetPhysicalDeviceFeatures2"));
    if (!fnFeatures2) {
        fnFeatures2 = reinterpret_cast<PFN_vkGetPhysicalDeviceFeatures2>(
            vkGetInstanceProcAddr(instance, "vkGetPhysicalDeviceFeatures2KHR"));
    }
    if (!fnFeatures2) {
        *outUnsupported = true;
        *outError = "vulkan_get_physical_device_features2_unavailable";
        Teardown();
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

    std::string rejection = "vulkan_no_suitable_graphics_device";
    bool foreignQueueExtAvailable = false;
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
        if ((fmt.optimalTilingFeatures & needed) != needed) {
            rejection = "vulkan_rgba8_format_features_missing";
            continue;
        }

        uint32_t extCount = 0;
        vkEnumerateDeviceExtensionProperties(dev, nullptr, &extCount, nullptr);
        std::vector<VkExtensionProperties> exts(extCount);
        if (extCount > 0) {
            vkEnumerateDeviceExtensionProperties(dev, nullptr, &extCount, exts.data());
        }
        if (!DeviceHasExtension(exts, kAhbExtensionName)) {
            rejection = "vulkan_ahardwarebuffer_extension_missing";
            continue;
        }

        VkPhysicalDeviceSamplerYcbcrConversionFeatures ycbcr{};
        ycbcr.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_SAMPLER_YCBCR_CONVERSION_FEATURES;
        VkPhysicalDeviceFeatures2 features2{};
        features2.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2;
        features2.pNext = &ycbcr;
        fnFeatures2(dev, &features2);
        if (ycbcr.samplerYcbcrConversion != VK_TRUE) {
            rejection = "vulkan_sampler_ycbcr_conversion_feature_missing";
            continue;
        }

        foreignQueueExtAvailable = DeviceHasExtension(exts, kForeignQueueExtName);
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
        *outError = rejection;
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

    std::vector<const char*> enabledExts;
    enabledExts.push_back(kAhbExtensionName);
    if (foreignQueueExtAvailable) {
        enabledExts.push_back(kForeignQueueExtName);
    }

    VkDeviceCreateInfo deviceCI{};
    deviceCI.sType                   = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO;
    deviceCI.pNext                   = &ycbcrFeature;
    deviceCI.queueCreateInfoCount    = 1;
    deviceCI.pQueueCreateInfos       = &queueCI;
    deviceCI.enabledExtensionCount   = static_cast<uint32_t>(enabledExts.size());
    deviceCI.ppEnabledExtensionNames = enabledExts.data();
    vr = vkCreateDevice(physDev, &deviceCI, nullptr, &device);
    if (vr != VK_SUCCESS) {
        device = VK_NULL_HANDLE;
        *outError = "vulkan_create_device_failed:" + std::to_string(static_cast<int>(vr));
        Teardown();
        return false;
    }
    foreignQueueExtEnabled = foreignQueueExtAvailable;
    vkGetDeviceQueue(device, queueFamily, 0, &queue);

    fnGetAhbProps = reinterpret_cast<PFN_vkGetAndroidHardwareBufferPropertiesANDROID>(
        vkGetDeviceProcAddr(device, "vkGetAndroidHardwareBufferPropertiesANDROID"));
    fnCreateYcbcr = reinterpret_cast<PFN_vkCreateSamplerYcbcrConversion>(
        vkGetDeviceProcAddr(device, "vkCreateSamplerYcbcrConversion"));
    if (!fnCreateYcbcr) {
        fnCreateYcbcr = reinterpret_cast<PFN_vkCreateSamplerYcbcrConversion>(
            vkGetDeviceProcAddr(device, "vkCreateSamplerYcbcrConversionKHR"));
    }
    fnDestroyYcbcr = reinterpret_cast<PFN_vkDestroySamplerYcbcrConversion>(
        vkGetDeviceProcAddr(device, "vkDestroySamplerYcbcrConversion"));
    if (!fnDestroyYcbcr) {
        fnDestroyYcbcr = reinterpret_cast<PFN_vkDestroySamplerYcbcrConversion>(
            vkGetDeviceProcAddr(device, "vkDestroySamplerYcbcrConversionKHR"));
    }
    if (!fnGetAhbProps || !fnCreateYcbcr || !fnDestroyYcbcr) {
        *outUnsupported = true;
        *outError = "vulkan_ahardwarebuffer_entry_points_unavailable";
        Teardown();
        return false;
    }

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

void VulkanScratch::Teardown() {
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
    physDev        = VK_NULL_HANDLE;
    queueFamily    = UINT32_MAX;
    fnGetAhbProps  = nullptr;
    fnCreateYcbcr  = nullptr;
    fnDestroyYcbcr = nullptr;
}

bool VulkanScratch::AllHandlesNull() const {
    return instance == VK_NULL_HANDLE && physDev == VK_NULL_HANDLE &&
           device == VK_NULL_HANDLE && queue == VK_NULL_HANDLE &&
           commandPool == VK_NULL_HANDLE;
}

// ── ScratchImage / ScratchBuffer ────────────────────────────────────────────

void ScratchImage::Destroy(VkDevice device) {
    if (device == VK_NULL_HANDLE) return;
    if (sampler != VK_NULL_HANDLE) { vkDestroySampler(device, sampler, nullptr); sampler = VK_NULL_HANDLE; }
    if (view != VK_NULL_HANDLE)    { vkDestroyImageView(device, view, nullptr);  view = VK_NULL_HANDLE; }
    if (image != VK_NULL_HANDLE)   { vkDestroyImage(device, image, nullptr);     image = VK_NULL_HANDLE; }
    if (memory != VK_NULL_HANDLE)  { vkFreeMemory(device, memory, nullptr);      memory = VK_NULL_HANDLE; }
}

bool ScratchImage::IsNull() const {
    return image == VK_NULL_HANDLE && memory == VK_NULL_HANDLE &&
           view == VK_NULL_HANDLE && sampler == VK_NULL_HANDLE;
}

void ScratchBuffer::Destroy(VkDevice device) {
    if (device == VK_NULL_HANDLE) return;
    if (mapped != nullptr && memory != VK_NULL_HANDLE) { vkUnmapMemory(device, memory); mapped = nullptr; }
    if (buffer != VK_NULL_HANDLE) { vkDestroyBuffer(device, buffer, nullptr); buffer = VK_NULL_HANDLE; }
    if (memory != VK_NULL_HANDLE) { vkFreeMemory(device, memory, nullptr);    memory = VK_NULL_HANDLE; }
    size = 0;
}

bool ScratchBuffer::IsNull() const {
    return buffer == VK_NULL_HANDLE && memory == VK_NULL_HANDLE && mapped == nullptr;
}

bool CreateDeviceImage(const VulkanScratch& vk,
                       uint32_t width,
                       uint32_t height,
                       VkImageUsageFlags usage,
                       bool withSampler,
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
    out.width  = width;
    out.height = height;
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
    if (withSampler) {
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
        if (vkCreateSampler(vk.device, &samplerCI, nullptr, &out.sampler) != VK_SUCCESS) {
            out.sampler = VK_NULL_HANDLE;
            *outError = "scratch_sampler_create_failed";
            return false;
        }
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

// ── ImportedFrame / ImportFrame ─────────────────────────────────────────────

void ImportedFrame::Destroy(const VulkanScratch& vk, const AndroidBufferApi& api) {
    if (vk.device != VK_NULL_HANDLE && imported) {
        image.destroy(vk.device, vk.fnDestroyYcbcr);
    }
    imported = false;
    buffer.Release(api);
}

bool ImportedFrame::IsNull() const {
    return image.image == VK_NULL_HANDLE && image.memory == VK_NULL_HANDLE &&
           image.imageView == VK_NULL_HANDLE && image.sampler == VK_NULL_HANDLE &&
           image.ycbcrConversion == VK_NULL_HANDLE && buffer.ahb == nullptr;
}

const char* ImportResultName(HardwareBufferImportResult r) {
    switch (r) {
        case HardwareBufferImportResult::kSuccess:                   return "success";
        case HardwareBufferImportResult::kUnavailable:               return "unavailable";
        case HardwareBufferImportResult::kBackendNotInitialized:     return "backend_not_initialized";
        case HardwareBufferImportResult::kInvalidArgument:           return "invalid_argument";
        case HardwareBufferImportResult::kDuplicateImport:           return "duplicate_import";
        case HardwareBufferImportResult::kIncompatibleBuffer:        return "incompatible_buffer";
        case HardwareBufferImportResult::kVulkanFunctionUnavailable: return "vulkan_function_unavailable";
        case HardwareBufferImportResult::kVulkanFailure:             return "vulkan_failure";
        case HardwareBufferImportResult::kUnknownHandle:             return "unknown_handle";
    }
    return "unknown";
}

bool ImportFrame(JNIEnv* env,
                 const AndroidBufferApi& api,
                 const VulkanScratch& vk,
                 jobject jHardwareBuffer,
                 uint32_t cropWidth,
                 uint32_t cropHeight,
                 const std::string& prefix,
                 ImportedFrame& out,
                 std::string* outError) {
    out.cropWidth  = cropWidth;
    out.cropHeight = cropHeight;
    AHardwareBuffer* raw = api.fromHardwareBuffer(env, jHardwareBuffer);
    if (!raw) {
        *outError = prefix + "_ahardwarebuffer_resolve_failed";
        return false;
    }
    api.acquire(raw);
    out.buffer.ahb      = raw;
    out.buffer.acquired = true;
    api.describe(raw, &out.buffer.desc);
    out.described = true;
    const AHardwareBuffer_Desc& d = out.buffer.desc;
    if (d.width == 0 || d.height == 0 || d.layers == 0) {
        *outError = prefix + "_buffer_zero_extent";
        return false;
    }
    if (d.width < cropWidth || d.height < cropHeight) {
        *outError = prefix + "_buffer_smaller_than_declared_frame";
        return false;
    }
    if (d.layers != 1) {
        *outError = prefix + "_buffer_layer_count_unsupported";
        return false;
    }
    if ((d.usage & AHARDWAREBUFFER_USAGE_GPU_SAMPLED_IMAGE) == 0) {
        *outError = prefix + "_buffer_lacks_gpu_sampled_usage";
        return false;
    }
    const HardwareBufferImportResult ir = out.image.create(
        vk.device, vk.physDev, raw, d, vk.fnGetAhbProps, vk.fnCreateYcbcr, vk.fnDestroyYcbcr);
    out.importResultName = ImportResultName(ir);
    if (ir != HardwareBufferImportResult::kSuccess) {
        *outError = prefix + "_import_failed:" + out.importResultName;
        return false;
    }
    out.imported = true;
    return true;
}

// ── ResolveImportedFrame ────────────────────────────────────────────────────

bool ResolveImportedFrame(const VulkanScratch& vk,
                          const ImportedFrame& frame,
                          ScratchImage& outRgba,
                          std::string* outError) {
    if (!CreateDeviceImage(vk, frame.cropWidth, frame.cropHeight,
                           VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | VK_IMAGE_USAGE_SAMPLED_BIT,
                           /*withSampler=*/true, outRgba, outError)) {
        return false;
    }

    ResolveObjects r;
    bool ok = true;
    if (!r.vert.create(vk.device, vanguard::render::shaders::kPassthroughVertSpv,
                       vanguard::render::shaders::kPassthroughVertSpvSize, "dualsync_resolve_vert")) {
        *outError = "resolve_vertex_shader_module_failed";
        ok = false;
    }
    if (ok && !r.frag.create(vk.device, vanguard::render::shaders::kPassthroughFragSpv,
                             vanguard::render::shaders::kPassthroughFragSpvSize, "dualsync_resolve_frag")) {
        *outError = "resolve_fragment_shader_module_failed";
        ok = false;
    }
    if (ok && !CreateResolveRenderPass(vk, &r.renderPass)) {
        *outError = "resolve_render_pass_failed";
        ok = false;
    }
    if (ok) {
        VkFramebufferCreateInfo fbCI{};
        fbCI.sType           = VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO;
        fbCI.renderPass      = r.renderPass;
        fbCI.attachmentCount = 1;
        fbCI.pAttachments    = &outRgba.view;
        fbCI.width           = frame.cropWidth;
        fbCI.height          = frame.cropHeight;
        fbCI.layers          = 1;
        if (vkCreateFramebuffer(vk.device, &fbCI, nullptr, &r.framebuffer) != VK_SUCCESS) {
            r.framebuffer = VK_NULL_HANDLE;
            *outError = "resolve_framebuffer_failed";
            ok = false;
        }
    }
    if (ok && !r.pipeline.create(vk.device, frame.image.descriptorResources.pipelineLayout,
                                 r.renderPass, r.vert.get(), r.frag.get())) {
        *outError = "resolve_pipeline_failed";
        ok = false;
    }
    if (ok) {
        VkCommandBufferAllocateInfo cbAI{};
        cbAI.sType              = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO;
        cbAI.commandPool        = vk.commandPool;
        cbAI.level              = VK_COMMAND_BUFFER_LEVEL_PRIMARY;
        cbAI.commandBufferCount = 1;
        if (vkAllocateCommandBuffers(vk.device, &cbAI, &r.commandBuffer) != VK_SUCCESS) {
            r.commandBuffer = VK_NULL_HANDLE;
            *outError = "resolve_command_buffer_alloc_failed";
            ok = false;
        }
    }
    if (ok) {
        VkFenceCreateInfo fenceCI{};
        fenceCI.sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO;
        if (vkCreateFence(vk.device, &fenceCI, nullptr, &r.fence) != VK_SUCCESS) {
            r.fence = VK_NULL_HANDLE;
            *outError = "resolve_fence_create_failed";
            ok = false;
        }
    }
    if (ok) {
        VkCommandBufferBeginInfo begin{};
        begin.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
        begin.flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
        if (vkBeginCommandBuffer(r.commandBuffer, &begin) != VK_SUCCESS) {
            *outError = "resolve_command_buffer_begin_failed";
            ok = false;
        }
    }
    if (ok) {
        RecordResolveDraw(r.commandBuffer, r, frame);
        if (vkEndCommandBuffer(r.commandBuffer) != VK_SUCCESS) {
            *outError = "resolve_command_buffer_end_failed";
            ok = false;
        }
    }
    if (ok) {
        VkSubmitInfo submit{};
        submit.sType              = VK_STRUCTURE_TYPE_SUBMIT_INFO;
        submit.commandBufferCount = 1;
        submit.pCommandBuffers    = &r.commandBuffer;
        if (vkQueueSubmit(vk.queue, 1, &submit, r.fence) != VK_SUCCESS) {
            *outError = "resolve_submit_failed";
            ok = false;
        } else if (vkWaitForFences(vk.device, 1, &r.fence, VK_TRUE, kFenceTimeoutNs) != VK_SUCCESS) {
            *outError = "resolve_fence_wait_failed";
            ok = false;
        }
    }
    // Drain before destroying anything the GPU might still reference.
    vkQueueWaitIdle(vk.queue);
    r.Destroy(vk);
    return ok;
}

// ── Geometry conversion ─────────────────────────────────────────────────────

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

VulkanTimelineTransitionLayerImage LayerOf(const ScratchImage& img) {
    VulkanTimelineTransitionLayerImage layer;
    layer.imageView = img.view;
    layer.sampler   = img.sampler;
    return layer;
}

// ── Render + readback ───────────────────────────────────────────────────────

void BindRenderTarget(RenderContext& ctx,
                      const VulkanScratch& vk,
                      VulkanTimelineTransitionCompositor& compositor,
                      const ScratchImage& colorTarget,
                      const ScratchBuffer& readback) {
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
    ctx.target.clearColor = {{0.0f, 0.0f, 0.0f, 1.0f}};
}

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

// ── Pixel telemetry ─────────────────────────────────────────────────────────

const uint8_t* PixelAt(const std::vector<uint8_t>& px, uint32_t x, uint32_t yTop) {
    return &px[(static_cast<size_t>(yTop) * kCanvasWidth + x) * 4];
}

std::string RgbString(const uint8_t* p) {
    char buf[32];
    std::snprintf(buf, sizeof(buf), "%u,%u,%u", p[0], p[1], p[2]);
    return buf;
}

uint64_t Checksum(const std::vector<uint8_t>& px) {
    uint64_t sum = 0;
    for (const uint8_t b : px) sum += b;
    return sum;
}

double MeanLuma(const std::vector<uint8_t>& px) {
    double total = 0.0;
    const size_t pixels = px.size() / 4;
    for (size_t i = 0; i < pixels; ++i) {
        const uint8_t* p = &px[i * 4];
        total += 0.299 * p[0] + 0.587 * p[1] + 0.114 * p[2];
    }
    return pixels == 0 ? 0.0 : total / static_cast<double>(pixels);
}

uint64_t SumAbsDiff(const std::vector<uint8_t>& a, const std::vector<uint8_t>& b) {
    uint64_t sum = 0;
    const size_t pixels = a.size() / 4;
    for (size_t i = 0; i < pixels; ++i) {
        for (size_t c = 0; c < 3; ++c) {
            sum += static_cast<uint64_t>(std::abs(static_cast<int>(a[i * 4 + c]) - static_cast<int>(b[i * 4 + c])));
        }
    }
    return sum;
}

uint32_t CountBlendMismatches(const std::vector<uint8_t>& from,
                              const std::vector<uint8_t>& to,
                              const std::vector<uint8_t>& mid,
                              double p) {
    uint32_t mismatches = 0;
    const size_t pixels = from.size() / 4;
    for (size_t i = 0; i < pixels; ++i) {
        bool bad = false;
        for (size_t c = 0; c < 3; ++c) {
            const double expected = from[i * 4 + c] * (1.0 - p) + to[i * 4 + c] * p;
            const int rounded = static_cast<int>(std::lround(expected));
            if (std::abs(rounded - static_cast<int>(mid[i * 4 + c])) > kColorTolerance) {
                bad = true;
                break;
            }
        }
        if (bad) ++mismatches;
    }
    return mismatches;
}

std::string VersionString(uint32_t v) {
    return std::to_string(VK_VERSION_MAJOR(v)) + "." + std::to_string(VK_VERSION_MINOR(v)) + "." +
           std::to_string(VK_VERSION_PATCH(v));
}

} // namespace vanguard::android_diag::dual_decoder_sync
