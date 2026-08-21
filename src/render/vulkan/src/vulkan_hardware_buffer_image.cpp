// vulkan_hardware_buffer_image.cpp
// Phase 2E: Vulkan hardware buffer image resource encapsulation.

#include "vulkan_hardware_buffer_image.h"

#if defined(__ANDROID__)

#include <android/log.h>

#define VGLOG_AHB(...) \
    __android_log_print(ANDROID_LOG_DEBUG, "VanguardAHBImport", __VA_ARGS__)

namespace vanguard {
namespace render {

HardwareBufferImportResult VulkanHardwareBufferImage::create(
    VkDevice device,
    VkPhysicalDevice physDev,
    AHardwareBuffer* ahbRef,
    const AHardwareBuffer_Desc& desc,
    PFN_vkGetAndroidHardwareBufferPropertiesANDROID fnGetAHBProps,
    PFN_vkCreateSamplerYcbcrConversion fnCreateYcbcr,
    PFN_vkDestroySamplerYcbcrConversion fnDestroyYcbcr)
{
    // --- Query Vulkan AHardwareBuffer properties ---
    VkAndroidHardwareBufferFormatPropertiesANDROID fmtProps{};
    fmtProps.sType =
        VK_STRUCTURE_TYPE_ANDROID_HARDWARE_BUFFER_FORMAT_PROPERTIES_ANDROID;
    fmtProps.pNext = nullptr;

    VkAndroidHardwareBufferPropertiesANDROID ahbProps{};
    ahbProps.sType =
        VK_STRUCTURE_TYPE_ANDROID_HARDWARE_BUFFER_PROPERTIES_ANDROID;
    ahbProps.pNext = &fmtProps;

    VkResult vr = fnGetAHBProps(device, ahbRef, &ahbProps);
    if (vr != VK_SUCCESS) {
        VGLOG_AHB("vkGetAndroidHardwareBufferPropertiesANDROID failed: %d",
                  static_cast<int>(vr));
        destroy(device, fnDestroyYcbcr);
        return HardwareBufferImportResult::kVulkanFailure;
    }

    // Require SAMPLED_IMAGE format feature.
    if (!(fmtProps.formatFeatures & VK_FORMAT_FEATURE_SAMPLED_IMAGE_BIT)) {
        VGLOG_AHB("Buffer lacks SAMPLED_IMAGE feature (formatFeatures=0x%x)",
                  static_cast<uint32_t>(fmtProps.formatFeatures));
        destroy(device, fnDestroyYcbcr);
        return HardwareBufferImportResult::kIncompatibleBuffer;
    }

    // --- Select memory type ---
    VkPhysicalDeviceMemoryProperties memProps{};
    vkGetPhysicalDeviceMemoryProperties(physDev, &memProps);

    uint32_t memTypeIndex = UINT32_MAX;
    for (uint32_t i = 0; i < memProps.memoryTypeCount; ++i) {
        if (ahbProps.memoryTypeBits & (1u << i)) {
            memTypeIndex = i;
            break;
        }
    }

    if (memTypeIndex == UINT32_MAX) {
        VGLOG_AHB("No compatible memory type (memoryTypeBits=0x%x)",
                  ahbProps.memoryTypeBits);
        destroy(device, fnDestroyYcbcr);
        return HardwareBufferImportResult::kVulkanFailure;
    }

    // --- Create VkImage ---
    // Chain VkExternalMemoryImageCreateInfo to signal the external handle type.
    VkExternalMemoryImageCreateInfo extImgCI{};
    extImgCI.sType = VK_STRUCTURE_TYPE_EXTERNAL_MEMORY_IMAGE_CREATE_INFO;
    extImgCI.handleTypes =
        VK_EXTERNAL_MEMORY_HANDLE_TYPE_ANDROID_HARDWARE_BUFFER_BIT_ANDROID;

    // For VK_FORMAT_UNDEFINED buffers, chain VkExternalFormatANDROID with
    // the driver-provided externalFormat value.
    VkExternalFormatANDROID extFmt{};
    extFmt.sType          = VK_STRUCTURE_TYPE_EXTERNAL_FORMAT_ANDROID;
    extFmt.externalFormat = 0;

    const bool isExternal = (fmtProps.format == VK_FORMAT_UNDEFINED);
    VkFormat imageFormat = fmtProps.format;

    if (isExternal) {
        if (fmtProps.externalFormat == 0) {
            VGLOG_AHB("format=VK_FORMAT_UNDEFINED but externalFormat=0");
            destroy(device, fnDestroyYcbcr);
            return HardwareBufferImportResult::kIncompatibleBuffer;
        }
        extFmt.pNext          = nullptr;
        extFmt.externalFormat = fmtProps.externalFormat;
        extImgCI.pNext        = &extFmt;
    } else {
        extImgCI.pNext = nullptr;
    }

    VkImageCreateInfo imgCI{};
    imgCI.sType         = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO;
    imgCI.pNext         = &extImgCI;
    imgCI.imageType     = VK_IMAGE_TYPE_2D;
    imgCI.format        = imageFormat;
    imgCI.extent        = { desc.width, desc.height, 1 };
    imgCI.mipLevels     = 1;
    imgCI.arrayLayers   = desc.layers;
    imgCI.samples       = VK_SAMPLE_COUNT_1_BIT;
    imgCI.tiling        = VK_IMAGE_TILING_OPTIMAL;
    imgCI.usage         = VK_IMAGE_USAGE_SAMPLED_BIT;
    imgCI.sharingMode   = VK_SHARING_MODE_EXCLUSIVE;
    imgCI.initialLayout = VK_IMAGE_LAYOUT_UNDEFINED;

    vr = vkCreateImage(device, &imgCI, nullptr, &image);
    if (vr != VK_SUCCESS) {
        VGLOG_AHB("vkCreateImage failed: %d", static_cast<int>(vr));
        destroy(device, fnDestroyYcbcr);
        return HardwareBufferImportResult::kVulkanFailure;
    }

    // --- Allocate and bind memory ---
    VkImportAndroidHardwareBufferInfoANDROID importInfo{};
    importInfo.sType  =
        VK_STRUCTURE_TYPE_IMPORT_ANDROID_HARDWARE_BUFFER_INFO_ANDROID;
    importInfo.pNext  = nullptr;
    importInfo.buffer = ahbRef;

    VkMemoryDedicatedAllocateInfo dedicatedInfo{};
    dedicatedInfo.sType  = VK_STRUCTURE_TYPE_MEMORY_DEDICATED_ALLOCATE_INFO;
    dedicatedInfo.pNext  = &importInfo;
    dedicatedInfo.image  = image;
    dedicatedInfo.buffer = VK_NULL_HANDLE;

    VkMemoryAllocateInfo allocInfo{};
    allocInfo.sType           = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
    allocInfo.pNext           = &dedicatedInfo;
    allocInfo.allocationSize  = ahbProps.allocationSize;
    allocInfo.memoryTypeIndex = memTypeIndex;

    vr = vkAllocateMemory(device, &allocInfo, nullptr, &memory);
    if (vr != VK_SUCCESS) {
        VGLOG_AHB("vkAllocateMemory failed: %d", static_cast<int>(vr));
        destroy(device, fnDestroyYcbcr);
        return HardwareBufferImportResult::kVulkanFailure;
    }

    vr = vkBindImageMemory(device, image, memory, 0);
    if (vr != VK_SUCCESS) {
        VGLOG_AHB("vkBindImageMemory failed: %d", static_cast<int>(vr));
        destroy(device, fnDestroyYcbcr);
        return HardwareBufferImportResult::kVulkanFailure;
    }

    // -------------------------------------------------------------------------
    // Phase 2D: Create sampling resources after successful vkBindImageMemory.
    // -------------------------------------------------------------------------

    if (isExternal) {
        // External-format (e.g., YUV/YCbCr hardware codec planes):
        // VkSamplerYcbcrConversionCreateInfo requires VkExternalFormatANDROID
        // chained in pNext with the driver opaque externalFormat value.
        // Spec: when format == VK_FORMAT_UNDEFINED, components/model/range/
        // chroma offsets come from fmtProps; chroma filter must be NEAREST
        // for conservative compatibility.
        VkExternalFormatANDROID convExtFmt{};
        convExtFmt.sType          = VK_STRUCTURE_TYPE_EXTERNAL_FORMAT_ANDROID;
        convExtFmt.pNext          = nullptr;
        convExtFmt.externalFormat = fmtProps.externalFormat;

        VkSamplerYcbcrConversionCreateInfo ycbcrCI{};
        ycbcrCI.sType      = VK_STRUCTURE_TYPE_SAMPLER_YCBCR_CONVERSION_CREATE_INFO;
        ycbcrCI.pNext      = &convExtFmt;
        ycbcrCI.format     = VK_FORMAT_UNDEFINED; // must match image format
        ycbcrCI.ycbcrModel = fmtProps.suggestedYcbcrModel;
        ycbcrCI.ycbcrRange = fmtProps.suggestedYcbcrRange;
        ycbcrCI.components = fmtProps.samplerYcbcrConversionComponents;
        ycbcrCI.xChromaOffset             = fmtProps.suggestedXChromaOffset;
        ycbcrCI.yChromaOffset             = fmtProps.suggestedYChromaOffset;
        ycbcrCI.chromaFilter              = VK_FILTER_NEAREST; // conservative
        ycbcrCI.forceExplicitReconstruction = VK_FALSE;

        vr = fnCreateYcbcr(device, &ycbcrCI, nullptr, &ycbcrConversion);
        if (vr != VK_SUCCESS) {
            VGLOG_AHB("vkCreateSamplerYcbcrConversion failed: %d",
                      static_cast<int>(vr));
            destroy(device, fnDestroyYcbcr);
            return HardwareBufferImportResult::kVulkanFailure;
        }
    }

    // --- Create VkImageView ---
    // For external-format images: chain VkSamplerYcbcrConversionInfo, set
    // format = VK_FORMAT_UNDEFINED, and use identity component swizzle.
    // For non-external images: plain 2D color view, no conversion chain.

    VkSamplerYcbcrConversionInfo viewYcbcrInfo{};
    viewYcbcrInfo.sType      = VK_STRUCTURE_TYPE_SAMPLER_YCBCR_CONVERSION_INFO;
    viewYcbcrInfo.pNext      = nullptr;
    viewYcbcrInfo.conversion = ycbcrConversion; // VK_NULL_HANDLE if non-external

    const VkImageViewType viewType =
        (desc.layers > 1) ? VK_IMAGE_VIEW_TYPE_2D_ARRAY
                          : VK_IMAGE_VIEW_TYPE_2D;

    VkImageViewCreateInfo viewCI{};
    viewCI.sType    = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO;
    viewCI.pNext    = isExternal
                          ? static_cast<void*>(&viewYcbcrInfo)
                          : nullptr;
    viewCI.image    = image;
    viewCI.viewType = viewType;
    viewCI.format   = isExternal ? VK_FORMAT_UNDEFINED : imageFormat;
    // Identity swizzle (required for external-format; safe for all).
    viewCI.components.r = VK_COMPONENT_SWIZZLE_IDENTITY;
    viewCI.components.g = VK_COMPONENT_SWIZZLE_IDENTITY;
    viewCI.components.b = VK_COMPONENT_SWIZZLE_IDENTITY;
    viewCI.components.a = VK_COMPONENT_SWIZZLE_IDENTITY;
    viewCI.subresourceRange.aspectMask     = VK_IMAGE_ASPECT_COLOR_BIT;
    viewCI.subresourceRange.baseMipLevel   = 0;
    viewCI.subresourceRange.levelCount     = 1;
    viewCI.subresourceRange.baseArrayLayer = 0;
    viewCI.subresourceRange.layerCount     = desc.layers;

    vr = vkCreateImageView(device, &viewCI, nullptr, &imageView);
    if (vr != VK_SUCCESS) {
        VGLOG_AHB("vkCreateImageView failed: %d", static_cast<int>(vr));
        destroy(device, fnDestroyYcbcr);
        return HardwareBufferImportResult::kVulkanFailure;
    }

    // --- Create VkSampler ---
    // For external-format images: chain VkSamplerYcbcrConversionInfo.
    // Common settings: clamp-to-edge, normalized coordinates, no anisotropy,
    // no compare, nearest filtering, nearest mipmap (conservative).

    VkSamplerYcbcrConversionInfo samplerYcbcrInfo{};
    samplerYcbcrInfo.sType      = VK_STRUCTURE_TYPE_SAMPLER_YCBCR_CONVERSION_INFO;
    samplerYcbcrInfo.pNext      = nullptr;
    samplerYcbcrInfo.conversion = ycbcrConversion; // VK_NULL_HANDLE if non-external

    VkSamplerCreateInfo samplerCI{};
    samplerCI.sType            = VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO;
    samplerCI.pNext            = isExternal
                                     ? static_cast<void*>(&samplerYcbcrInfo)
                                     : nullptr;
    samplerCI.magFilter        = VK_FILTER_NEAREST;
    samplerCI.minFilter        = VK_FILTER_NEAREST;
    samplerCI.mipmapMode       = VK_SAMPLER_MIPMAP_MODE_NEAREST;
    samplerCI.addressModeU     = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE;
    samplerCI.addressModeV     = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE;
    samplerCI.addressModeW     = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE;
    samplerCI.mipLodBias       = 0.0f;
    samplerCI.anisotropyEnable = VK_FALSE;
    samplerCI.maxAnisotropy    = 1.0f;
    samplerCI.compareEnable    = VK_FALSE;
    samplerCI.compareOp        = VK_COMPARE_OP_ALWAYS;
    samplerCI.minLod           = 0.0f;
    samplerCI.maxLod           = 0.0f;
    samplerCI.borderColor      = VK_BORDER_COLOR_FLOAT_TRANSPARENT_BLACK;
    samplerCI.unnormalizedCoordinates = VK_FALSE;

    vr = vkCreateSampler(device, &samplerCI, nullptr, &sampler);
    if (vr != VK_SUCCESS) {
        VGLOG_AHB("vkCreateSampler failed: %d", static_cast<int>(vr));
        destroy(device, fnDestroyYcbcr);
        return HardwareBufferImportResult::kVulkanFailure;
    }

    cachedFormat         = imageFormat;
    cachedExternalFormat = isExternal ? fmtProps.externalFormat : 0;
    cachedLayerCount     = desc.layers; // Phase 2F

    return HardwareBufferImportResult::kSuccess;
}

void VulkanHardwareBufferImage::destroy(
    VkDevice device,
    PFN_vkDestroySamplerYcbcrConversion fnDestroyYcbcr)
{
    if (sampler != VK_NULL_HANDLE) {
        vkDestroySampler(device, sampler, nullptr);
        sampler = VK_NULL_HANDLE;
    }
    if (imageView != VK_NULL_HANDLE) {
        vkDestroyImageView(device, imageView, nullptr);
        imageView = VK_NULL_HANDLE;
    }
    if (ycbcrConversion != VK_NULL_HANDLE && fnDestroyYcbcr) {
        fnDestroyYcbcr(device, ycbcrConversion, nullptr);
        ycbcrConversion = VK_NULL_HANDLE;
    }
    if (image != VK_NULL_HANDLE) {
        vkDestroyImage(device, image, nullptr);
        image = VK_NULL_HANDLE;
    }
    if (memory != VK_NULL_HANDLE) {
        vkFreeMemory(device, memory, nullptr);
        memory = VK_NULL_HANDLE;
    }
    cachedFormat         = VK_FORMAT_UNDEFINED;
    cachedExternalFormat = 0;
    cachedLayerCount     = 1; // Phase 2F
}

// Phase 2F: Records one VkImageMemoryBarrier via vkCmdPipelineBarrier.
// Does NOT submit the command buffer.
void VulkanHardwareBufferImage::recordLayoutTransition(
    VkCommandBuffer commandBuffer,
    VkImageLayout oldLayout,
    VkImageLayout newLayout,
    VkPipelineStageFlags srcStageMask,
    VkPipelineStageFlags dstStageMask,
    VkAccessFlags srcAccessMask,
    VkAccessFlags dstAccessMask,
    uint32_t srcQueueFamilyIndex,
    uint32_t dstQueueFamilyIndex) const
{
    // Guard: must have a recording command buffer and a valid image.
    if (commandBuffer == VK_NULL_HANDLE || image == VK_NULL_HANDLE) {
        return;
    }

    // Guard: for external-format images, only UNDEFINED -> SHADER_READ_ONLY_OPTIMAL
    // is a valid transition.  All other layout pairs are silently ignored.
    if (isExternalFormat()) {
        if (oldLayout != VK_IMAGE_LAYOUT_UNDEFINED ||
            newLayout != VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL) {
            return;
        }
    }

    VkImageMemoryBarrier barrier{};
    barrier.sType               = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER;
    barrier.pNext               = nullptr;
    barrier.srcAccessMask       = srcAccessMask;
    barrier.dstAccessMask       = dstAccessMask;
    barrier.oldLayout           = oldLayout;
    barrier.newLayout           = newLayout;
    barrier.srcQueueFamilyIndex = srcQueueFamilyIndex;
    barrier.dstQueueFamilyIndex = dstQueueFamilyIndex;
    barrier.image               = image;
    barrier.subresourceRange.aspectMask     = VK_IMAGE_ASPECT_COLOR_BIT;
    barrier.subresourceRange.baseMipLevel   = 0;
    barrier.subresourceRange.levelCount     = 1;
    barrier.subresourceRange.baseArrayLayer = 0;
    barrier.subresourceRange.layerCount     = cachedLayerCount;

    vkCmdPipelineBarrier(
        commandBuffer,
        srcStageMask,
        dstStageMask,
        /*dependencyFlags=*/0,
        /*memoryBarrierCount=*/0,    nullptr,
        /*bufferMemoryBarrierCount=*/0, nullptr,
        /*imageMemoryBarrierCount=*/1,  &barrier);
}

} // namespace render
} // namespace vanguard

#else // !__ANDROID__

namespace vanguard {
namespace render {
// Stubs for host build
} // namespace render
} // namespace vanguard

#endif // __ANDROID__
