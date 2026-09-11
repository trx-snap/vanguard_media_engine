#include <jni.h>
#define VK_USE_PLATFORM_ANDROID_KHR 1
#include <vulkan/vulkan.h>
#include <android/hardware_buffer.h>
#include <android/native_window.h>
#include <android/native_window_jni.h>

#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <limits>
#include <sstream>
#include <string>
#include <vector>

#include "android_phase5_timeline_dual_decoder_sync_vulkan_support.h"
#include "vanguard/render/render_transform.h"
#include "vulkan_greenscreen_compositor.h"
#include "vulkan_shader_module.h"
#include "vulkan_graphics_pipeline.h"
#include "shaders/passthrough_vert_spv.h"
#include "shaders/passthrough_frag_spv.h"

using vanguard::android_diag::dual_decoder_sync::AndroidBufferApi;
using vanguard::android_diag::dual_decoder_sync::CreateDeviceImage;
using vanguard::android_diag::dual_decoder_sync::CreateHostBuffer;
using vanguard::android_diag::dual_decoder_sync::ImportedFrame;
using vanguard::android_diag::dual_decoder_sync::ImportFrame;
using vanguard::android_diag::dual_decoder_sync::ResolveImportedFrame;
using vanguard::android_diag::dual_decoder_sync::ScratchBuffer;
using vanguard::android_diag::dual_decoder_sync::ScratchImage;
using vanguard::android_diag::dual_decoder_sync::VulkanScratch;

using vanguard::render::VulkanGreenScreenCompositor;
using vanguard::render::VulkanGreenScreenInputs;
using vanguard::render::VulkanGreenScreenRenderTarget;
using vanguard::render::VulkanShaderModule;
using vanguard::render::VulkanGraphicsPipeline;
using vanguard::render::VideoTransformFullPushConstants;

constexpr uint32_t kMaskWidth = 17;
constexpr uint32_t kMaskHeight = 19;
constexpr uint8_t kMaskRowValues[kMaskHeight] = {
    0, 0, 16, 32, 48, 64, 80, 96, 112, 128, 144, 160, 176, 192, 208, 224, 240, 255, 255,
};

constexpr const char* kProofBoundary =
    "native_android_duet_vulkan_preview_presentation_surfaceproducer_ahb_no_readback_diagnostic_only_no_production_preview_no_export";
constexpr const char* kPassMarker =
    "ANDROID_DUET_VULKAN_PREVIEW_PRESENTATION_PHYSICAL_PASS";
constexpr const char* kFailMarker =
    "ANDROID_DUET_VULKAN_PREVIEW_PRESENTATION_PHYSICAL_FAIL";

static void FlushIfNeeded(const VulkanScratch& vk, const ScratchBuffer& buf) {
    if (buf.coherent) return;
    VkMappedMemoryRange range{};
    range.sType  = VK_STRUCTURE_TYPE_MAPPED_MEMORY_RANGE;
    range.memory = buf.memory;
    range.offset = 0;
    range.size   = VK_WHOLE_SIZE;
    vkFlushMappedMemoryRanges(vk.device, 1, &range);
}

static bool UploadSampledImage(const VulkanScratch& vk,
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
        toTransfer.sType                           = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER;
        toTransfer.srcAccessMask                   = 0;
        toTransfer.dstAccessMask                   = VK_ACCESS_TRANSFER_WRITE_BIT;
        toTransfer.oldLayout                       = VK_IMAGE_LAYOUT_UNDEFINED;
        toTransfer.newLayout                       = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;
        toTransfer.srcQueueFamilyIndex             = VK_QUEUE_FAMILY_IGNORED;
        toTransfer.dstQueueFamilyIndex             = VK_QUEUE_FAMILY_IGNORED;
        toTransfer.image                           = img.image;
        toTransfer.subresourceRange.aspectMask     = VK_IMAGE_ASPECT_COLOR_BIT;
        toTransfer.subresourceRange.levelCount     = 1;
        toTransfer.subresourceRange.layerCount     = 1;
        vkCmdPipelineBarrier(cb, VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT,
                             0, 0, nullptr, 0, nullptr, 1, &toTransfer);

        VkBufferImageCopy region{};
        region.imageSubresource.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
        region.imageSubresource.layerCount = 1;
        region.imageExtent                 = {width, height, 1};
        vkCmdCopyBufferToImage(cb, staging.buffer, img.image, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &region);

        VkImageMemoryBarrier toSampled = toTransfer;
        toSampled.srcAccessMask        = VK_ACCESS_TRANSFER_WRITE_BIT;
        toSampled.dstAccessMask        = VK_ACCESS_SHADER_READ_BIT;
        toSampled.oldLayout            = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;
        toSampled.newLayout            = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
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
    if (vk.queue != VK_NULL_HANDLE) {
        vkQueueWaitIdle(vk.queue);
    }
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

static std::string JsonEscape(const std::string& in) {
    std::string out;
    out.reserve(in.size() + 8);
    for (const char c : in) {
        if (c == '"') out += "\\\"";
        else if (c == '\\') out += "\\\\";
        else if (c == '\n') out += "\\n";
        else if (c == '\r') out += "\\r";
        else if (c == '\t') out += "\\t";
        else if ((unsigned char)c < 0x20) {
            char buf[8];
            std::snprintf(buf, sizeof(buf), "\\u%04x", (unsigned)c);
            out += buf;
        } else out += c;
    }
    return out;
}

class DetailsBuilder {
public:
    void Str(const char* key, const std::string& value) { Raw(key, "\"" + JsonEscape(value) + "\""); }
    void Bool(const char* key, bool value) { Raw(key, value ? "true" : "false"); }
    void U64(const char* key, uint64_t value) { Raw(key, std::to_string(value)); }
    std::string Json() const {
        std::string out = "{";
        for (size_t i = 0; i < entries_.size(); ++i) {
            if (i != 0) out += ",";
            out += entries_[i];
        }
        return out + "}";
    }
private:
    void Raw(const char* key, const std::string& raw) {
        entries_.push_back("\"" + std::string(key) + "\":" + raw);
    }
    std::vector<std::string> entries_;
};

extern "C" JNIEXPORT jstring JNICALL
Java_com_connects_vanguard_1media_1engine_bridge_VanguardNativeBridge_renderAndroidDuetVulkanPreviewPresentation(
    JNIEnv* env,
    jobject /* this */,
    jobject surface,
    jint surfaceWidth,
    jint surfaceHeight,
    jobject cameraHardwareBuffer,
    jint cameraWidth,
    jint cameraHeight,
    jobject decoderHardwareBuffer,
    jint decoderWidth,
    jint decoderHeight) {

    bool pass = false;
    bool argumentValidationOk = false;
    bool nativeWindowOk = false;
    bool vulkanSetupOk = false;
    bool swapchainCreateOk = false;
    bool cameraImportOk = false;
    bool decoderImportOk = false;
    bool resolveOk = false;
    bool maskUploadOk = false;
    bool blendRenderNoReadbackOk = false;
    bool swapchainPresentOk = false;
    bool resourceReleaseOk = false;
    bool diagnosticTeardownOk = false;
    bool allNativeLanesPass = false;

    std::string failureReason;
    std::string status = "FAIL";
    DetailsBuilder details;

    ANativeWindow* nativeWindow = nullptr;
    AndroidBufferApi api;
    VulkanScratch vk;
    VkInstance instance = VK_NULL_HANDLE;
    VkSurfaceKHR surfaceKhr = VK_NULL_HANDLE;
    VkDevice device = VK_NULL_HANDLE;
    VkQueue queue = VK_NULL_HANDLE;
    VkCommandPool commandPool = VK_NULL_HANDLE;
    VkSwapchainKHR swapchain = VK_NULL_HANDLE;
    VkRenderPass swapchainRenderPass = VK_NULL_HANDLE;
    VkImageView swapchainView = VK_NULL_HANDLE;
    VkFramebuffer swapchainFramebuffer = VK_NULL_HANDLE;
    VkDescriptorSetLayout descSetLayout = VK_NULL_HANDLE;
    VkDescriptorPool descPool = VK_NULL_HANDLE;
    VkPipelineLayout presentPipelineLayout = VK_NULL_HANDLE;
    VkCommandBuffer cb = VK_NULL_HANDLE;
    VkSemaphore acquireSemaphore = VK_NULL_HANDLE;
    VkSemaphore renderCompleteSemaphore = VK_NULL_HANDLE;
    VulkanShaderModule vertModule;
    VulkanShaderModule fragModule;
    VulkanGraphicsPipeline presentPipeline;

    ImportedFrame cameraImported;
    ImportedFrame decoderImported;
    ScratchImage cameraResolved;
    ScratchImage decoderResolved;
    ScratchImage maskScratch;
    ScratchImage targetScratch;

    VkFormat chosenFormat = VK_FORMAT_UNDEFINED;
    VkExtent2D chosenExtent{0, 0};
    bool unsupported = false;

    // 1. Argument validation
    argumentValidationOk = (surface != nullptr && surfaceWidth > 0 && surfaceHeight > 0 &&
                            cameraHardwareBuffer != nullptr && cameraWidth > 0 && cameraHeight > 0 &&
                            decoderHardwareBuffer != nullptr && decoderWidth > 0 && decoderHeight > 0);
    if (!argumentValidationOk) {
        failureReason = "invalid_arguments";
        goto end;
    }

    // 2. Wrap Surface with ANativeWindow
    nativeWindow = ANativeWindow_fromSurface(env, surface);
    if (!nativeWindow) {
        failureReason = "native_window_null";
        goto end;
    }
    nativeWindowOk = true;

    // 3. Load Android buffer API
    if (!api.Load(&failureReason)) {
        goto end;
    }

    // 4. Vulkan setup: create VkInstance with VK_KHR_surface + VK_KHR_android_surface
    {
        uint32_t instExtCount = 0;
        if (vkEnumerateInstanceExtensionProperties(nullptr, &instExtCount, nullptr) != VK_SUCCESS || instExtCount == 0) {
            unsupported = true;
            failureReason = "vulkan_enumerate_instance_extensions_failed";
            goto end;
        }
        std::vector<VkExtensionProperties> availableInstExts(instExtCount);
        vkEnumerateInstanceExtensionProperties(nullptr, &instExtCount, availableInstExts.data());

        bool hasKhrSurface = false;
        bool hasKhrAndroidSurface = false;
        for (const auto& ext : availableInstExts) {
            if (std::strcmp(ext.extensionName, VK_KHR_SURFACE_EXTENSION_NAME) == 0) {
                hasKhrSurface = true;
            } else if (std::strcmp(ext.extensionName, VK_KHR_ANDROID_SURFACE_EXTENSION_NAME) == 0) {
                hasKhrAndroidSurface = true;
            }
        }
        if (!hasKhrSurface || !hasKhrAndroidSurface) {
            unsupported = true;
            failureReason = "vulkan_surface_extensions_missing";
            goto end;
        }

        std::vector<const char*> enabledInstExts = {
            VK_KHR_SURFACE_EXTENSION_NAME,
            VK_KHR_ANDROID_SURFACE_EXTENSION_NAME,
        };

        VkApplicationInfo appInfo{};
        appInfo.sType              = VK_STRUCTURE_TYPE_APPLICATION_INFO;
        appInfo.pApplicationName   = "VanguardDuetPreviewPresentationSmoke";
        appInfo.applicationVersion = VK_MAKE_VERSION(0, 1, 0);
        appInfo.pEngineName        = "VanguardRenderEngine";
        appInfo.engineVersion      = VK_MAKE_VERSION(0, 1, 0);
        appInfo.apiVersion         = VK_API_VERSION_1_1;

        VkInstanceCreateInfo instCI{};
        instCI.sType                   = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO;
        instCI.pApplicationInfo        = &appInfo;
        instCI.enabledExtensionCount   = static_cast<uint32_t>(enabledInstExts.size());
        instCI.ppEnabledExtensionNames = enabledInstExts.data();

        VkResult vr = vkCreateInstance(&instCI, nullptr, &instance);
        if (vr != VK_SUCCESS) {
            unsupported = true;
            failureReason = "vkCreateInstance_failed:" + std::to_string(static_cast<int>(vr));
            goto end;
        }
    }

    // 5. Create VkSurfaceKHR
    {
        VkAndroidSurfaceCreateInfoKHR surfCI{};
        surfCI.sType  = VK_STRUCTURE_TYPE_ANDROID_SURFACE_CREATE_INFO_KHR;
        surfCI.window = nativeWindow;
        VkResult vr = vkCreateAndroidSurfaceKHR(instance, &surfCI, nullptr, &surfaceKhr);
        if (vr != VK_SUCCESS) {
            failureReason = "vkCreateAndroidSurfaceKHR_failed:" + std::to_string(static_cast<int>(vr));
            goto end;
        }
    }

    // 6. Select Physical Device & Graphics+Present Queue Family
    {
        auto fnFeatures2 = reinterpret_cast<PFN_vkGetPhysicalDeviceFeatures2>(
            vkGetInstanceProcAddr(instance, "vkGetPhysicalDeviceFeatures2"));
        if (!fnFeatures2) {
            fnFeatures2 = reinterpret_cast<PFN_vkGetPhysicalDeviceFeatures2>(
                vkGetInstanceProcAddr(instance, "vkGetPhysicalDeviceFeatures2KHR"));
        }
        if (!fnFeatures2) {
            unsupported = true;
            failureReason = "vulkan_get_physical_device_features2_unavailable";
            goto end;
        }

        uint32_t devCount = 0;
        vkEnumeratePhysicalDevices(instance, &devCount, nullptr);
        if (devCount == 0) {
            unsupported = true;
            failureReason = "vulkan_no_physical_devices";
            goto end;
        }
        std::vector<VkPhysicalDevice> devices(devCount);
        vkEnumeratePhysicalDevices(instance, &devCount, devices.data());

        VkPhysicalDevice chosenPhysDev = VK_NULL_HANDLE;
        uint32_t chosenQueueFamily = UINT32_MAX;
        VkPhysicalDeviceProperties chosenProps{};
        bool foreignQueueAvailable = false;

        for (VkPhysicalDevice dev : devices) {
            VkPhysicalDeviceProperties props{};
            vkGetPhysicalDeviceProperties(dev, &props);
            if (props.deviceType == VK_PHYSICAL_DEVICE_TYPE_CPU) continue;

            uint32_t qfCount = 0;
            vkGetPhysicalDeviceQueueFamilyProperties(dev, &qfCount, nullptr);
            std::vector<VkQueueFamilyProperties> qfProps(qfCount);
            vkGetPhysicalDeviceQueueFamilyProperties(dev, &qfCount, qfProps.data());

            uint32_t qfIndex = UINT32_MAX;
            for (uint32_t i = 0; i < qfCount; ++i) {
                if ((qfProps[i].queueFlags & VK_QUEUE_GRAPHICS_BIT) != 0) {
                    VkBool32 presentSupported = VK_FALSE;
                    if (vkGetPhysicalDeviceSurfaceSupportKHR(dev, i, surfaceKhr, &presentSupported) == VK_SUCCESS &&
                        presentSupported == VK_TRUE) {
                        qfIndex = i;
                        break;
                    }
                }
            }
            if (qfIndex == UINT32_MAX) continue;

            uint32_t devExtCount = 0;
            vkEnumerateDeviceExtensionProperties(dev, nullptr, &devExtCount, nullptr);
            std::vector<VkExtensionProperties> devExts(devExtCount);
            if (devExtCount > 0) {
                vkEnumerateDeviceExtensionProperties(dev, nullptr, &devExtCount, devExts.data());
            }

            bool hasSwapchain = false;
            bool hasAhb = false;
            bool hasForeign = false;
            for (const auto& e : devExts) {
                if (std::strcmp(e.extensionName, VK_KHR_SWAPCHAIN_EXTENSION_NAME) == 0) hasSwapchain = true;
                if (std::strcmp(e.extensionName, "VK_ANDROID_external_memory_android_hardware_buffer") == 0) hasAhb = true;
                if (std::strcmp(e.extensionName, "VK_EXT_queue_family_foreign") == 0) hasForeign = true;
            }
            if (!hasSwapchain || !hasAhb) continue;

            VkPhysicalDeviceSamplerYcbcrConversionFeatures ycbcr{};
            ycbcr.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_SAMPLER_YCBCR_CONVERSION_FEATURES;
            VkPhysicalDeviceFeatures2 f2{};
            f2.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2;
            f2.pNext = &ycbcr;
            fnFeatures2(dev, &f2);
            if (ycbcr.samplerYcbcrConversion != VK_TRUE) continue;

            VkFormatProperties fmtProps{};
            vkGetPhysicalDeviceFormatProperties(dev, VK_FORMAT_R8G8B8A8_UNORM, &fmtProps);
            const VkFormatFeatureFlags needed =
                VK_FORMAT_FEATURE_COLOR_ATTACHMENT_BIT | VK_FORMAT_FEATURE_SAMPLED_IMAGE_BIT;
            if ((fmtProps.optimalTilingFeatures & needed) != needed) continue;

            chosenPhysDev = dev;
            chosenQueueFamily = qfIndex;
            chosenProps = props;
            foreignQueueAvailable = hasForeign;
            break;
        }

        if (chosenPhysDev == VK_NULL_HANDLE) {
            unsupported = true;
            failureReason = "no_suitable_vulkan_device_with_surface_and_ahb_support";
            goto end;
        }

        // 7. Create VkDevice
        float qPriority = 1.0f;
        VkDeviceQueueCreateInfo queueCI{};
        queueCI.sType            = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO;
        queueCI.queueFamilyIndex = chosenQueueFamily;
        queueCI.queueCount       = 1;
        queueCI.pQueuePriorities = &qPriority;

        VkPhysicalDeviceSamplerYcbcrConversionFeatures ycbcrFeature{};
        ycbcrFeature.sType                  = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_SAMPLER_YCBCR_CONVERSION_FEATURES;
        ycbcrFeature.samplerYcbcrConversion = VK_TRUE;

        std::vector<const char*> enabledDevExts = {
            VK_KHR_SWAPCHAIN_EXTENSION_NAME,
            "VK_ANDROID_external_memory_android_hardware_buffer",
        };
        if (foreignQueueAvailable) {
            enabledDevExts.push_back("VK_EXT_queue_family_foreign");
        }

        VkDeviceCreateInfo devCI{};
        devCI.sType                   = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO;
        devCI.pNext                   = &ycbcrFeature;
        devCI.queueCreateInfoCount    = 1;
        devCI.pQueueCreateInfos       = &queueCI;
        devCI.enabledExtensionCount   = static_cast<uint32_t>(enabledDevExts.size());
        devCI.ppEnabledExtensionNames = enabledDevExts.data();

        VkResult vr = vkCreateDevice(chosenPhysDev, &devCI, nullptr, &device);
        if (vr != VK_SUCCESS) {
            unsupported = true;
            failureReason = "vkCreateDevice_failed:" + std::to_string(static_cast<int>(vr));
            goto end;
        }

        vkGetDeviceQueue(device, chosenQueueFamily, 0, &queue);

        VkCommandPoolCreateInfo poolCI{};
        poolCI.sType            = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO;
        poolCI.flags            = VK_COMMAND_POOL_CREATE_TRANSIENT_BIT | VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT;
        poolCI.queueFamilyIndex = chosenQueueFamily;
        vr = vkCreateCommandPool(device, &poolCI, nullptr, &commandPool);
        if (vr != VK_SUCCESS) {
            failureReason = "vkCreateCommandPool_failed";
            goto end;
        }

        vk.instance      = instance;
        vk.physDev       = chosenPhysDev;
        vk.device        = device;
        vk.queue         = queue;
        vk.queueFamily   = chosenQueueFamily;
        vk.commandPool   = commandPool;
        vk.deviceName    = chosenProps.deviceName;
        vk.deviceType    = static_cast<uint32_t>(chosenProps.deviceType);
        vk.apiVersion    = chosenProps.apiVersion;
        vk.driverVersion = chosenProps.driverVersion;
        vkGetPhysicalDeviceMemoryProperties(chosenPhysDev, &vk.memProps);

        vk.fnGetAhbProps = reinterpret_cast<PFN_vkGetAndroidHardwareBufferPropertiesANDROID>(
            vkGetDeviceProcAddr(device, "vkGetAndroidHardwareBufferPropertiesANDROID"));
        vk.fnCreateYcbcr = reinterpret_cast<PFN_vkCreateSamplerYcbcrConversion>(
            vkGetDeviceProcAddr(device, "vkCreateSamplerYcbcrConversion"));
        if (!vk.fnCreateYcbcr) {
            vk.fnCreateYcbcr = reinterpret_cast<PFN_vkCreateSamplerYcbcrConversion>(
                vkGetDeviceProcAddr(device, "vkCreateSamplerYcbcrConversionKHR"));
        }
        vk.fnDestroyYcbcr = reinterpret_cast<PFN_vkDestroySamplerYcbcrConversion>(
            vkGetDeviceProcAddr(device, "vkDestroySamplerYcbcrConversion"));
        if (!vk.fnDestroyYcbcr) {
            vk.fnDestroyYcbcr = reinterpret_cast<PFN_vkDestroySamplerYcbcrConversion>(
                vkGetDeviceProcAddr(device, "vkDestroySamplerYcbcrConversionKHR"));
        }

        if (!vk.fnGetAhbProps || !vk.fnCreateYcbcr || !vk.fnDestroyYcbcr) {
            unsupported = true;
            failureReason = "vulkan_ahb_proc_addr_unavailable";
            goto end;
        }

        vulkanSetupOk = true;
    }

    // 8. Create Swapchain
    {
        VkSurfaceCapabilitiesKHR caps{};
        VkResult vr = vkGetPhysicalDeviceSurfaceCapabilitiesKHR(vk.physDev, surfaceKhr, &caps);
        if (vr != VK_SUCCESS || !(caps.supportedUsageFlags & VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT)) {
            failureReason = "surface_capabilities_color_attachment_unsupported";
            goto end;
        }

        uint32_t fmtCount = 0;
        vkGetPhysicalDeviceSurfaceFormatsKHR(vk.physDev, surfaceKhr, &fmtCount, nullptr);
        if (fmtCount == 0) {
            failureReason = "surface_has_no_formats";
            goto end;
        }
        std::vector<VkSurfaceFormatKHR> formats(fmtCount);
        vkGetPhysicalDeviceSurfaceFormatsKHR(vk.physDev, surfaceKhr, &fmtCount, formats.data());

        chosenFormat = formats[0].format;
        VkColorSpaceKHR chosenColorSpace = formats[0].colorSpace;
        for (const auto& f : formats) {
            if (f.colorSpace == VK_COLOR_SPACE_SRGB_NONLINEAR_KHR) {
                if (f.format == VK_FORMAT_R8G8B8A8_UNORM || f.format == VK_FORMAT_B8G8R8A8_UNORM) {
                    chosenFormat = f.format;
                    chosenColorSpace = f.colorSpace;
                    break;
                }
            }
        }

        if (caps.currentExtent.width != std::numeric_limits<uint32_t>::max() &&
            caps.currentExtent.width > 0 && caps.currentExtent.height > 0) {
            chosenExtent = caps.currentExtent;
        } else {
            chosenExtent.width = std::max(caps.minImageExtent.width,
                                          std::min(caps.maxImageExtent.width, static_cast<uint32_t>(surfaceWidth)));
            chosenExtent.height = std::max(caps.minImageExtent.height,
                                           std::min(caps.maxImageExtent.height, static_cast<uint32_t>(surfaceHeight)));
        }

        uint32_t imageCount = caps.minImageCount + 1;
        if (imageCount < 2) imageCount = 2;
        if (caps.maxImageCount > 0 && imageCount > caps.maxImageCount) {
            imageCount = caps.maxImageCount;
        }

        VkCompositeAlphaFlagBitsKHR compositeAlpha = VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR;
        if (!(caps.supportedCompositeAlpha & VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR)) {
            if (caps.supportedCompositeAlpha & VK_COMPOSITE_ALPHA_INHERIT_BIT_KHR) {
                compositeAlpha = VK_COMPOSITE_ALPHA_INHERIT_BIT_KHR;
            } else if (caps.supportedCompositeAlpha & VK_COMPOSITE_ALPHA_PRE_MULTIPLIED_BIT_KHR) {
                compositeAlpha = VK_COMPOSITE_ALPHA_PRE_MULTIPLIED_BIT_KHR;
            }
        }

        VkSwapchainCreateInfoKHR sci{};
        sci.sType            = VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR;
        sci.surface          = surfaceKhr;
        sci.minImageCount    = imageCount;
        sci.imageFormat      = chosenFormat;
        sci.imageColorSpace  = chosenColorSpace;
        sci.imageExtent      = chosenExtent;
        sci.imageArrayLayers = 1;
        sci.imageUsage       = VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT;
        sci.imageSharingMode = VK_SHARING_MODE_EXCLUSIVE;
        sci.preTransform     = caps.currentTransform;
        sci.compositeAlpha   = compositeAlpha;
        sci.presentMode      = VK_PRESENT_MODE_FIFO_KHR;
        sci.clipped          = VK_TRUE;

        vr = vkCreateSwapchainKHR(device, &sci, nullptr, &swapchain);
        if (vr != VK_SUCCESS) {
            failureReason = "vkCreateSwapchainKHR_failed:" + std::to_string(static_cast<int>(vr));
            goto end;
        }

        uint32_t actualImageCount = 0;
        vkGetSwapchainImagesKHR(device, swapchain, &actualImageCount, nullptr);
        if (actualImageCount == 0) {
            failureReason = "swapchain_has_zero_images";
            goto end;
        }
        swapchainCreateOk = true;
    }

    // 9. Import frames
    if (!ImportFrame(env, api, vk, cameraHardwareBuffer, cameraWidth, cameraHeight, "camera", cameraImported, &failureReason)) {
        goto end;
    }
    cameraImportOk = true;

    if (!ImportFrame(env, api, vk, decoderHardwareBuffer, decoderWidth, decoderHeight, "decoder", decoderImported, &failureReason)) {
        goto end;
    }
    decoderImportOk = true;

    // 10. Resolve frames
    if (!CreateDeviceImage(vk, cameraImported.cropWidth, cameraImported.cropHeight,
                           VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | VK_IMAGE_USAGE_SAMPLED_BIT, true,
                           cameraResolved, &failureReason)) {
        goto end;
    }
    if (!ResolveImportedFrame(vk, cameraImported, cameraResolved, &failureReason)) {
        goto end;
    }

    if (!CreateDeviceImage(vk, decoderImported.cropWidth, decoderImported.cropHeight,
                           VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | VK_IMAGE_USAGE_SAMPLED_BIT, true,
                           decoderResolved, &failureReason)) {
        goto end;
    }
    if (!ResolveImportedFrame(vk, decoderImported, decoderResolved, &failureReason)) {
        goto end;
    }
    resolveOk = true;

    // 11. Upload deterministic mask
    if (!CreateDeviceImage(vk, kMaskWidth, kMaskHeight,
                           VK_IMAGE_USAGE_TRANSFER_DST_BIT | VK_IMAGE_USAGE_SAMPLED_BIT, false,
                           maskScratch, &failureReason)) {
        goto end;
    }
    {
        std::vector<uint8_t> maskData(kMaskWidth * kMaskHeight, 0);
        for (uint32_t y = 0; y < kMaskHeight; ++y) {
            for (uint32_t x = 0; x < kMaskWidth; ++x) {
                maskData[y * kMaskWidth + x] = kMaskRowValues[y];
            }
        }
        if (!UploadSampledImage(vk, maskScratch, maskData.data(), kMaskWidth, kMaskHeight, 1, &failureReason)) {
            goto end;
        }
    }
    maskUploadOk = true;

    // 12. Blend green screen into offscreen RGBA8 target (no readback)
    {
        const uint32_t blendWidth = chosenExtent.width;
        const uint32_t blendHeight = chosenExtent.height;

        if (!CreateDeviceImage(vk, blendWidth, blendHeight,
                               VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | VK_IMAGE_USAGE_SAMPLED_BIT, true,
                               targetScratch, &failureReason)) {
            goto end;
        }

        VulkanGreenScreenCompositor compositorStack;

        VulkanGreenScreenInputs inputs;
        inputs.background.imageView = decoderResolved.view;
        inputs.background.sampler   = decoderResolved.sampler;
        inputs.foreground.imageView = cameraResolved.view;
        inputs.foreground.sampler   = cameraResolved.sampler;
        inputs.mask.imageView       = maskScratch.view;
        inputs.mask.sampler         = maskScratch.sampler;
        inputs.maskWidth            = kMaskWidth;
        inputs.maskHeight           = kMaskHeight;

        VulkanGreenScreenRenderTarget target;
        target.device                  = vk.device;
        target.queue                   = vk.queue;
        target.commandPool             = vk.commandPool;
        target.colorImage              = targetScratch.image;
        target.colorImageView          = targetScratch.view;
        target.colorFormat             = VK_FORMAT_R8G8B8A8_UNORM;
        target.readbackEnabled         = false;
        target.readbackBuffer          = VK_NULL_HANDLE;
        target.readbackBufferSizeBytes = 0;
        target.finalLayout             = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
        target.extentWidth             = blendWidth;
        target.extentHeight            = blendHeight;

        if (!compositorStack.blendGreenScreen(target, inputs, &failureReason)) {
            goto end;
        }
    }
    blendRenderNoReadbackOk = true;

    // 13. Present one frame to the swapchain
    {
        VkSemaphoreCreateInfo semCI{};
        semCI.sType = VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO;
        if (vkCreateSemaphore(device, &semCI, nullptr, &acquireSemaphore) != VK_SUCCESS ||
            vkCreateSemaphore(device, &semCI, nullptr, &renderCompleteSemaphore) != VK_SUCCESS) {
            failureReason = "semaphore_create_failed";
            goto end;
        }

        uint32_t imageIndex = 0;
        VkResult vr = vkAcquireNextImageKHR(device, swapchain, 2000000000ull, acquireSemaphore, VK_NULL_HANDLE, &imageIndex);
        if (vr != VK_SUCCESS && vr != VK_SUBOPTIMAL_KHR) {
            failureReason = "vkAcquireNextImageKHR_failed:" + std::to_string(static_cast<int>(vr));
            goto end;
        }

        uint32_t actualImageCount = 0;
        vkGetSwapchainImagesKHR(device, swapchain, &actualImageCount, nullptr);
        std::vector<VkImage> swapchainImages(actualImageCount);
        vkGetSwapchainImagesKHR(device, swapchain, &actualImageCount, swapchainImages.data());

        // Presentation pass: render targetScratch (RGBA8) into swapchain image (chosenFormat)
        // using swapchain render pass + framebuffer + passthrough shaders.
        VkAttachmentDescription colorAttachment{};
        colorAttachment.format         = chosenFormat;
        colorAttachment.samples        = VK_SAMPLE_COUNT_1_BIT;
        colorAttachment.loadOp         = VK_ATTACHMENT_LOAD_OP_DONT_CARE;
        colorAttachment.storeOp        = VK_ATTACHMENT_STORE_OP_STORE;
        colorAttachment.stencilLoadOp  = VK_ATTACHMENT_LOAD_OP_DONT_CARE;
        colorAttachment.stencilStoreOp = VK_ATTACHMENT_STORE_OP_DONT_CARE;
        colorAttachment.initialLayout  = VK_IMAGE_LAYOUT_UNDEFINED;
        colorAttachment.finalLayout    = VK_IMAGE_LAYOUT_PRESENT_SRC_KHR;

        VkAttachmentReference colorRef{};
        colorRef.attachment = 0;
        colorRef.layout     = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL;

        VkSubpassDescription subpass{};
        subpass.pipelineBindPoint    = VK_PIPELINE_BIND_POINT_GRAPHICS;
        subpass.colorAttachmentCount = 1;
        subpass.pColorAttachments    = &colorRef;

        VkSubpassDependency dep{};
        dep.srcSubpass    = VK_SUBPASS_EXTERNAL;
        dep.dstSubpass    = 0;
        dep.srcStageMask  = VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT;
        dep.dstStageMask  = VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT;
        dep.srcAccessMask = 0;
        dep.dstAccessMask = VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT;

        VkRenderPassCreateInfo rpCI{};
        rpCI.sType           = VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO;
        rpCI.attachmentCount = 1;
        rpCI.pAttachments    = &colorAttachment;
        rpCI.subpassCount    = 1;
        rpCI.pSubpasses      = &subpass;
        rpCI.dependencyCount = 1;
        rpCI.pDependencies   = &dep;

        if (vkCreateRenderPass(device, &rpCI, nullptr, &swapchainRenderPass) != VK_SUCCESS) {
            failureReason = "swapchain_render_pass_create_failed";
            goto end;
        }

        VkImageViewCreateInfo viewCI{};
        viewCI.sType                           = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO;
        viewCI.image                           = swapchainImages[imageIndex];
        viewCI.viewType                        = VK_IMAGE_VIEW_TYPE_2D;
        viewCI.format                          = chosenFormat;
        viewCI.subresourceRange.aspectMask     = VK_IMAGE_ASPECT_COLOR_BIT;
        viewCI.subresourceRange.baseMipLevel   = 0;
        viewCI.subresourceRange.levelCount     = 1;
        viewCI.subresourceRange.baseArrayLayer = 0;
        viewCI.subresourceRange.layerCount     = 1;
        if (vkCreateImageView(device, &viewCI, nullptr, &swapchainView) != VK_SUCCESS) {
            failureReason = "swapchain_image_view_create_failed";
            goto end;
        }

        VkFramebufferCreateInfo fbCI{};
        fbCI.sType           = VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO;
        fbCI.renderPass      = swapchainRenderPass;
        fbCI.attachmentCount = 1;
        fbCI.pAttachments    = &swapchainView;
        fbCI.width           = chosenExtent.width;
        fbCI.height          = chosenExtent.height;
        fbCI.layers          = 1;
        if (vkCreateFramebuffer(device, &fbCI, nullptr, &swapchainFramebuffer) != VK_SUCCESS) {
            failureReason = "swapchain_framebuffer_create_failed";
            goto end;
        }

        VkDescriptorSetLayoutBinding b{};
        b.binding            = 0;
        b.descriptorType     = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
        b.descriptorCount    = 1;
        b.stageFlags         = VK_SHADER_STAGE_FRAGMENT_BIT;

        VkDescriptorSetLayoutCreateInfo layoutCI{};
        layoutCI.sType        = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO;
        layoutCI.bindingCount = 1;
        layoutCI.pBindings    = &b;
        if (vkCreateDescriptorSetLayout(device, &layoutCI, nullptr, &descSetLayout) != VK_SUCCESS) {
            failureReason = "swapchain_desc_layout_create_failed";
            goto end;
        }

        VkDescriptorPoolSize poolSize{};
        poolSize.type            = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
        poolSize.descriptorCount = 1;

        VkDescriptorPoolCreateInfo descPoolCI{};
        descPoolCI.sType         = VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO;
        descPoolCI.maxSets       = 1;
        descPoolCI.poolSizeCount = 1;
        descPoolCI.pPoolSizes    = &poolSize;
        if (vkCreateDescriptorPool(device, &descPoolCI, nullptr, &descPool) != VK_SUCCESS) {
            failureReason = "swapchain_desc_pool_create_failed";
            goto end;
        }

        VkDescriptorSet descSet = VK_NULL_HANDLE;
        VkDescriptorSetAllocateInfo allocInfo{};
        allocInfo.sType              = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO;
        allocInfo.descriptorPool     = descPool;
        allocInfo.descriptorSetCount = 1;
        allocInfo.pSetLayouts        = &descSetLayout;
        if (vkAllocateDescriptorSets(device, &allocInfo, &descSet) != VK_SUCCESS) {
            failureReason = "swapchain_desc_set_alloc_failed";
            goto end;
        }

        VkDescriptorImageInfo imgInfo{};
        imgInfo.sampler     = targetScratch.sampler;
        imgInfo.imageView   = targetScratch.view;
        imgInfo.imageLayout = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;

        VkWriteDescriptorSet write{};
        write.sType           = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
        write.dstSet          = descSet;
        write.dstBinding      = 0;
        write.descriptorCount = 1;
        write.descriptorType  = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
        write.pImageInfo      = &imgInfo;
        vkUpdateDescriptorSets(device, 1, &write, 0, nullptr);

        VkPushConstantRange pcRange{};
        pcRange.stageFlags = VK_SHADER_STAGE_VERTEX_BIT | VK_SHADER_STAGE_FRAGMENT_BIT;
        pcRange.offset     = 0;
        pcRange.size       = 112;

        VkPipelineLayoutCreateInfo plCI{};
        plCI.sType                  = VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO;
        plCI.setLayoutCount         = 1;
        plCI.pSetLayouts            = &descSetLayout;
        plCI.pushConstantRangeCount = 1;
        plCI.pPushConstantRanges    = &pcRange;
        if (vkCreatePipelineLayout(device, &plCI, nullptr, &presentPipelineLayout) != VK_SUCCESS) {
            failureReason = "swapchain_pipeline_layout_create_failed";
            goto end;
        }

        if (!vertModule.create(device, vanguard::render::shaders::kPassthroughVertSpv,
                               vanguard::render::shaders::kPassthroughVertSpvSize, "present_vert") ||
            !fragModule.create(device, vanguard::render::shaders::kPassthroughFragSpv,
                               vanguard::render::shaders::kPassthroughFragSpvSize, "present_frag")) {
            failureReason = "present_shaders_create_failed";
            goto end;
        }

        if (!presentPipeline.create(device, presentPipelineLayout, swapchainRenderPass,
                                    vertModule.get(), fragModule.get())) {
            failureReason = "present_pipeline_create_failed";
            goto end;
        }

        VkCommandBufferAllocateInfo cbAI{};
        cbAI.sType              = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO;
        cbAI.commandPool        = commandPool;
        cbAI.level              = VK_COMMAND_BUFFER_LEVEL_PRIMARY;
        cbAI.commandBufferCount = 1;
        if (vkAllocateCommandBuffers(device, &cbAI, &cb) != VK_SUCCESS) {
            failureReason = "present_command_buffer_alloc_failed";
            goto end;
        }

        VkCommandBufferBeginInfo beginInfo{};
        beginInfo.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
        beginInfo.flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
        if (vkBeginCommandBuffer(cb, &beginInfo) != VK_SUCCESS) {
            failureReason = "present_command_buffer_begin_failed";
            goto end;
        }

        VkRenderPassBeginInfo rpBegin{};
        rpBegin.sType             = VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO;
        rpBegin.renderPass        = swapchainRenderPass;
        rpBegin.framebuffer       = swapchainFramebuffer;
        rpBegin.renderArea.offset = {0, 0};
        rpBegin.renderArea.extent = chosenExtent;
        rpBegin.clearValueCount   = 0;
        vkCmdBeginRenderPass(cb, &rpBegin, VK_SUBPASS_CONTENTS_INLINE);

        VkViewport viewport{};
        viewport.x        = 0.0f;
        viewport.y        = 0.0f;
        viewport.width    = static_cast<float>(chosenExtent.width);
        viewport.height   = static_cast<float>(chosenExtent.height);
        viewport.minDepth = 0.0f;
        viewport.maxDepth = 1.0f;
        vkCmdSetViewport(cb, 0, 1, &viewport);

        VkRect2D scissor{};
        scissor.offset = {0, 0};
        scissor.extent = chosenExtent;
        vkCmdSetScissor(cb, 0, 1, &scissor);

        vkCmdBindPipeline(cb, VK_PIPELINE_BIND_POINT_GRAPHICS, presentPipeline.get());
        vkCmdBindDescriptorSets(cb, VK_PIPELINE_BIND_POINT_GRAPHICS, presentPipelineLayout, 0, 1, &descSet, 0, nullptr);

        VideoTransformFullPushConstants pc{};
        pc.uv.uvTransform0[0] = 1.0f;
        pc.uv.uvTransform1[1] = 1.0f;
        pc.color.row0[0]      = 1.0f;
        pc.color.row1[1]      = 1.0f;
        pc.color.row2[2]      = 1.0f;
        pc.color.row3[3]      = 1.0f;
        vkCmdPushConstants(cb, presentPipelineLayout,
                           VK_SHADER_STAGE_VERTEX_BIT | VK_SHADER_STAGE_FRAGMENT_BIT,
                           0, sizeof(pc), &pc);

        vkCmdDraw(cb, 3, 1, 0, 0);
        vkCmdEndRenderPass(cb);
        if (vkEndCommandBuffer(cb) != VK_SUCCESS) {
            failureReason = "present_command_buffer_end_failed";
            goto end;
        }

        VkPipelineStageFlags waitStage = VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT;
        VkSubmitInfo submitInfo{};
        submitInfo.sType                = VK_STRUCTURE_TYPE_SUBMIT_INFO;
        submitInfo.waitSemaphoreCount   = 1;
        submitInfo.pWaitSemaphores      = &acquireSemaphore;
        submitInfo.pWaitDstStageMask    = &waitStage;
        submitInfo.commandBufferCount   = 1;
        submitInfo.pCommandBuffers      = &cb;
        submitInfo.signalSemaphoreCount = 1;
        submitInfo.pSignalSemaphores    = &renderCompleteSemaphore;

        if (vkQueueSubmit(queue, 1, &submitInfo, VK_NULL_HANDLE) != VK_SUCCESS) {
            failureReason = "present_queue_submit_failed";
            goto end;
        }

        VkPresentInfoKHR presentInfo{};
        presentInfo.sType              = VK_STRUCTURE_TYPE_PRESENT_INFO_KHR;
        presentInfo.waitSemaphoreCount = 1;
        presentInfo.pWaitSemaphores    = &renderCompleteSemaphore;
        presentInfo.swapchainCount     = 1;
        presentInfo.pSwapchains        = &swapchain;
        presentInfo.pImageIndices      = &imageIndex;
        vr = vkQueuePresentKHR(queue, &presentInfo);
        if (vr == VK_SUCCESS || vr == VK_SUBOPTIMAL_KHR) {
            swapchainPresentOk = true;
        } else {
            failureReason = "vkQueuePresentKHR_failed:" + std::to_string(static_cast<int>(vr));
            goto end;
        }
    }

end:
    if (queue != VK_NULL_HANDLE) {
        vkQueueWaitIdle(queue);
    }

    if (cb != VK_NULL_HANDLE && commandPool != VK_NULL_HANDLE && device != VK_NULL_HANDLE) {
        vkFreeCommandBuffers(device, commandPool, 1, &cb);
    }
    presentPipeline.destroy(device);
    fragModule.destroy(device);
    vertModule.destroy(device);
    if (device != VK_NULL_HANDLE) {
        if (presentPipelineLayout != VK_NULL_HANDLE) vkDestroyPipelineLayout(device, presentPipelineLayout, nullptr);
        if (descPool != VK_NULL_HANDLE) vkDestroyDescriptorPool(device, descPool, nullptr);
        if (descSetLayout != VK_NULL_HANDLE) vkDestroyDescriptorSetLayout(device, descSetLayout, nullptr);
        if (swapchainFramebuffer != VK_NULL_HANDLE) vkDestroyFramebuffer(device, swapchainFramebuffer, nullptr);
        if (swapchainView != VK_NULL_HANDLE) vkDestroyImageView(device, swapchainView, nullptr);
        if (swapchainRenderPass != VK_NULL_HANDLE) vkDestroyRenderPass(device, swapchainRenderPass, nullptr);
        if (acquireSemaphore != VK_NULL_HANDLE) vkDestroySemaphore(device, acquireSemaphore, nullptr);
        if (renderCompleteSemaphore != VK_NULL_HANDLE) vkDestroySemaphore(device, renderCompleteSemaphore, nullptr);
    }

    targetScratch.Destroy(device);
    maskScratch.Destroy(device);
    cameraResolved.Destroy(device);
    decoderResolved.Destroy(device);

    cameraImported.Destroy(vk, api);
    decoderImported.Destroy(vk, api);

    if (device != VK_NULL_HANDLE && swapchain != VK_NULL_HANDLE) {
        vkDestroySwapchainKHR(device, swapchain, nullptr);
        swapchain = VK_NULL_HANDLE;
    }
    if (instance != VK_NULL_HANDLE && surfaceKhr != VK_NULL_HANDLE) {
        vkDestroySurfaceKHR(instance, surfaceKhr, nullptr);
        surfaceKhr = VK_NULL_HANDLE;
    }

    resourceReleaseOk = true;

    vk.Teardown();
    diagnosticTeardownOk = vk.AllHandlesNull();
    api.Unload();

    if (nativeWindow != nullptr) {
        ANativeWindow_release(nativeWindow);
        nativeWindow = nullptr;
    }

    allNativeLanesPass = argumentValidationOk && nativeWindowOk && vulkanSetupOk &&
                         swapchainCreateOk && cameraImportOk && decoderImportOk &&
                         resolveOk && maskUploadOk && blendRenderNoReadbackOk &&
                         swapchainPresentOk && resourceReleaseOk && diagnosticTeardownOk;

    if (allNativeLanesPass) {
        pass = true;
        status = "PASS";
    } else if (unsupported) {
        status = "UNSUPPORTED";
    }

    details.Str("deviceName", vk.deviceName);
    details.U64("deviceType", vk.deviceType);
    details.U64("apiVersion", vk.apiVersion);
    details.U64("driverVersion", vk.driverVersion);
    details.U64("queueFamilyIndex", vk.queueFamily);
    details.U64("swapchainExtentWidth", chosenExtent.width);
    details.U64("swapchainExtentHeight", chosenExtent.height);
    details.U64("swapchainFormat", chosenFormat);
    details.Str("swapchainFormatName", chosenFormat == VK_FORMAT_R8G8B8A8_UNORM ? "VK_FORMAT_R8G8B8A8_UNORM" : (chosenFormat == VK_FORMAT_B8G8R8A8_UNORM ? "VK_FORMAT_B8G8R8A8_UNORM" : std::to_string(chosenFormat)));
    details.Str("presentationPath", "minimal_shader_passthrough");
    details.U64("maskWidth", kMaskWidth);
    details.U64("maskHeight", kMaskHeight);
    details.Str("proofBoundary", kProofBoundary);

    std::string json = "{";
    json += "\"pass\":" + std::string(pass ? "true" : "false") + ",";
    json += "\"status\":\"" + status + "\",";
    json += "\"failureReason\":\"" + JsonEscape(failureReason) + "\",";
    json += "\"proofBoundary\":\"" + std::string(kProofBoundary) + "\",";
    json += "\"marker\":\"" + std::string(pass ? kPassMarker : kFailMarker) + "\",";
    json += "\"allNativeLanesPass\":" + std::string(allNativeLanesPass ? "true" : "false") + ",";
    json += "\"gates\":{";
    json += "\"argumentValidationOk\":" + std::string(argumentValidationOk ? "true" : "false") + ",";
    json += "\"nativeWindowOk\":" + std::string(nativeWindowOk ? "true" : "false") + ",";
    json += "\"vulkanSetupOk\":" + std::string(vulkanSetupOk ? "true" : "false") + ",";
    json += "\"swapchainCreateOk\":" + std::string(swapchainCreateOk ? "true" : "false") + ",";
    json += "\"cameraImportOk\":" + std::string(cameraImportOk ? "true" : "false") + ",";
    json += "\"decoderImportOk\":" + std::string(decoderImportOk ? "true" : "false") + ",";
    json += "\"resolveOk\":" + std::string(resolveOk ? "true" : "false") + ",";
    json += "\"maskUploadOk\":" + std::string(maskUploadOk ? "true" : "false") + ",";
    json += "\"blendRenderNoReadbackOk\":" + std::string(blendRenderNoReadbackOk ? "true" : "false") + ",";
    json += "\"swapchainPresentOk\":" + std::string(swapchainPresentOk ? "true" : "false") + ",";
    json += "\"resourceReleaseOk\":" + std::string(resourceReleaseOk ? "true" : "false") + ",";
    json += "\"diagnosticTeardownOk\":" + std::string(diagnosticTeardownOk ? "true" : "false") + ",";
    json += "\"allNativeLanesPass\":" + std::string(allNativeLanesPass ? "true" : "false");
    json += "},";
    json += "\"argumentValidationOk\":" + std::string(argumentValidationOk ? "true" : "false") + ",";
    json += "\"nativeWindowOk\":" + std::string(nativeWindowOk ? "true" : "false") + ",";
    json += "\"vulkanSetupOk\":" + std::string(vulkanSetupOk ? "true" : "false") + ",";
    json += "\"swapchainCreateOk\":" + std::string(swapchainCreateOk ? "true" : "false") + ",";
    json += "\"cameraImportOk\":" + std::string(cameraImportOk ? "true" : "false") + ",";
    json += "\"decoderImportOk\":" + std::string(decoderImportOk ? "true" : "false") + ",";
    json += "\"resolveOk\":" + std::string(resolveOk ? "true" : "false") + ",";
    json += "\"maskUploadOk\":" + std::string(maskUploadOk ? "true" : "false") + ",";
    json += "\"blendRenderNoReadbackOk\":" + std::string(blendRenderNoReadbackOk ? "true" : "false") + ",";
    json += "\"swapchainPresentOk\":" + std::string(swapchainPresentOk ? "true" : "false") + ",";
    json += "\"resourceReleaseOk\":" + std::string(resourceReleaseOk ? "true" : "false") + ",";
    json += "\"diagnosticTeardownOk\":" + std::string(diagnosticTeardownOk ? "true" : "false") + ",";
    json += "\"details\":" + details.Json();
    json += "}";

    return env->NewStringUTF(json.c_str());
}
