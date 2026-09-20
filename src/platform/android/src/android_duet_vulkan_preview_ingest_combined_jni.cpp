#include <jni.h>
#define VK_USE_PLATFORM_ANDROID_KHR 1
#include <vulkan/vulkan.h>
#include <android/hardware_buffer.h>

#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <sstream>
#include <string>
#include <vector>

#include "android_phase5_timeline_dual_decoder_sync_vulkan_support.h"
#include "vulkan_greenscreen_compositor.h"

using vanguard::android_diag::dual_decoder_sync::AndroidBufferApi;
using vanguard::android_diag::dual_decoder_sync::CreateDeviceImage;
using vanguard::android_diag::dual_decoder_sync::CreateHostBuffer;
using vanguard::android_diag::dual_decoder_sync::ImportedFrame;
using vanguard::android_diag::dual_decoder_sync::ImportFrame;
using vanguard::android_diag::dual_decoder_sync::InvalidateIfNeeded;
using vanguard::android_diag::dual_decoder_sync::ResolveImportedFrame;
using vanguard::android_diag::dual_decoder_sync::ScratchBuffer;
using vanguard::android_diag::dual_decoder_sync::ScratchImage;
using vanguard::android_diag::dual_decoder_sync::VulkanScratch;

using vanguard::render::ComputeVulkanGreenScreenReferencePixel;
using vanguard::render::kVulkanGreenScreenBlendFormula;
using vanguard::render::kVulkanGreenScreenColorContract;
using vanguard::render::kVulkanGreenScreenReferenceColorTolerance;
using vanguard::render::MapVulkanGreenScreenMaskTexel;
using vanguard::render::VulkanGreenScreenCompositor;
using vanguard::render::VulkanGreenScreenInputs;
using vanguard::render::VulkanGreenScreenPixelWithinTolerance;
using vanguard::render::VulkanGreenScreenRenderTarget;
using vanguard::render::VulkanGreenScreenSampledImage;

constexpr uint32_t kMaskWidth = 17;
constexpr uint32_t kMaskHeight = 19;
constexpr uint8_t kMaskRowValues[kMaskHeight] = {
    0, 0, 16, 32, 48, 64, 80, 96, 112, 128, 144, 160, 176, 192, 208, 224, 240, 255, 255,
};

constexpr uint8_t kBackground[4] = {30, 60, 200, 255};
constexpr uint8_t kForeground[4] = {230, 120, 20, 180};

constexpr const char* kProofBoundary =
    "native_android_duet_preview_ingest_combined_camera_ahb_decoder_ahb_vulkan_greenscreen_mask_blend_diagnostic_only_no_camerax_no_production_preview_no_export_no_segmentation_model";
constexpr const char* kPassMarker =
    "ANDROID_DUET_VULKAN_PREVIEW_INGEST_COMBINED_PHYSICAL_PASS";
constexpr const char* kFailMarker =
    "ANDROID_DUET_VULKAN_PREVIEW_INGEST_COMBINED_PHYSICAL_FAIL";

static uint32_t FindMemoryType(const VkPhysicalDeviceMemoryProperties& props,
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

static bool CreateDeviceImageExplicit(const VulkanScratch& vk,
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

static void FlushIfNeeded(const VulkanScratch& vk, const ScratchBuffer& buf) {
    if (buf.coherent) return;
    VkMappedMemoryRange range{};
    range.sType = VK_STRUCTURE_TYPE_MAPPED_MEMORY_RANGE;
    range.memory = buf.memory;
    range.offset = 0;
    range.size = VK_WHOLE_SIZE;
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
        cbAI.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO;
        cbAI.commandPool = vk.commandPool;
        cbAI.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY;
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
        toTransfer.sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER;
        toTransfer.srcAccessMask = 0;
        toTransfer.dstAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT;
        toTransfer.oldLayout = VK_IMAGE_LAYOUT_UNDEFINED;
        toTransfer.newLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;
        toTransfer.srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
        toTransfer.dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
        toTransfer.image = img.image;
        toTransfer.subresourceRange.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
        toTransfer.subresourceRange.levelCount = 1;
        toTransfer.subresourceRange.layerCount = 1;
        vkCmdPipelineBarrier(cb, VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT,
                             0, 0, nullptr, 0, nullptr, 1, &toTransfer);

        VkBufferImageCopy region{};
        region.imageSubresource.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
        region.imageSubresource.layerCount = 1;
        region.imageExtent = {width, height, 1};
        vkCmdCopyBufferToImage(cb, staging.buffer, img.image, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &region);

        VkImageMemoryBarrier toSampled = toTransfer;
        toSampled.srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT;
        toSampled.dstAccessMask = VK_ACCESS_SHADER_READ_BIT;
        toSampled.oldLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;
        toSampled.newLayout = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
        vkCmdPipelineBarrier(cb, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT,
                             0, 0, nullptr, 0, nullptr, 1, &toSampled);

        ok = vkEndCommandBuffer(cb) == VK_SUCCESS;
        if (!ok) *outError = "upload_command_buffer_end_failed";
    }
    if (ok) {
        VkSubmitInfo submit{};
        submit.sType = VK_STRUCTURE_TYPE_SUBMIT_INFO;
        submit.commandBufferCount = 1;
        submit.pCommandBuffers = &cb;
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
    samplerCI.sType = VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO;
    samplerCI.magFilter = VK_FILTER_NEAREST;
    samplerCI.minFilter = VK_FILTER_NEAREST;
    samplerCI.mipmapMode = VK_SAMPLER_MIPMAP_MODE_NEAREST;
    samplerCI.addressModeU = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE;
    samplerCI.addressModeV = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE;
    samplerCI.addressModeW = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE;
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

static std::string RgbaString(const uint8_t* p) {
    char buf[48];
    std::snprintf(buf, sizeof(buf), "%u,%u,%u,%u", p[0], p[1], p[2], p[3]);
    return buf;
}

class DetailsBuilder {
public:
    void Str(const char* key, const std::string& value) { Raw(key, "\"" + JsonEscape(value) + "\""); }
    void Bool(const char* key, bool value) { Raw(key, value ? "true" : "false"); }
    void U64(const char* key, uint64_t value) { Raw(key, std::to_string(value)); }
    void Int(const char* key, int64_t value) { Raw(key, std::to_string(value)); }
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
Java_com_connects_vanguard_1media_1engine_bridge_VanguardNativeBridge_renderAndroidDuetVulkanPreviewIngestCombined(
    JNIEnv* env,
    jobject /* this */,
    jobject cameraHardwareBuffer,
    jint cameraWidth,
    jint cameraHeight,
    jobject decoderHardwareBuffer,
    jint decoderWidth,
    jint decoderHeight) {

    bool pass = false;
    bool vulkanSetupOk = false;
    bool cameraImportOk = false;
    bool decoderImportOk = false;
    bool resolveOk = false;
    bool maskUploadOk = false;
    bool blendRenderOk = false;
    bool readbackOk = false;
    bool cpuReferenceParityOk = false;
    bool alphaZeroPreservesBackgroundOk = false;
    bool alphaFullForegroundOk = false;
    bool alphaFractionalBlendOk = false;
    bool maskResolutionMismatchOk = false;
    bool resourceReleaseOk = false;
    bool diagnosticTeardownOk = false;
    bool allNativeLanesPass = false;

    std::string failureReason;
    std::string status = "FAIL";
    DetailsBuilder details;

    AndroidBufferApi api;
    VulkanScratch vk;
    ImportedFrame cameraImported;
    ImportedFrame decoderImported;
    ScratchImage cameraResolved;
    ScratchImage decoderResolved;
    ScratchImage maskScratch;
    ScratchImage targetScratch;
    ScratchBuffer readbackScratch;

    ScratchImage syntheticBackground;
    ScratchImage syntheticForeground;
    ScratchImage syntheticTarget;
    ScratchBuffer syntheticReadback;

    VulkanGreenScreenCompositor compositorStack;

    uint64_t realNonZero = 0;
    uint64_t mismatchCount = 0;
    std::string firstMismatch;
    uint64_t zeroCount = 0, fullCount = 0, fractionalCount = 0;
    bool zeroOk = true, fullOk = true, fractionalOk = true;

    bool unsupported = false;
    if (!api.Load(&failureReason)) {
        goto end;
    }

    if (!vk.Setup(&failureReason, &unsupported)) {
        if (unsupported) status = "UNSUPPORTED";
        goto end;
    }
    vulkanSetupOk = true;

    if (!ImportFrame(env, api, vk, cameraHardwareBuffer, cameraWidth, cameraHeight, "camera", cameraImported, &failureReason)) {
        goto end;
    }
    cameraImportOk = true;

    if (!ImportFrame(env, api, vk, decoderHardwareBuffer, decoderWidth, decoderHeight, "decoder", decoderImported, &failureReason)) {
        goto end;
    }
    decoderImportOk = true;

    if (!ResolveImportedFrame(vk, cameraImported, cameraResolved, &failureReason)) {
        goto end;
    }
    if (!ResolveImportedFrame(vk, decoderImported, decoderResolved, &failureReason)) {
        goto end;
    }
    resolveOk = true;

    if (!CreateDeviceImageExplicit(vk, VK_FORMAT_R8_UNORM, kMaskWidth, kMaskHeight,
                                   VK_IMAGE_USAGE_TRANSFER_DST_BIT | VK_IMAGE_USAGE_SAMPLED_BIT,
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

    // 1. Real camera AHB + decoder AHB blend into 128x128 target with non-zero readback check
    if (!CreateDeviceImage(vk, 128, 128,
                           VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | VK_IMAGE_USAGE_TRANSFER_SRC_BIT, false,
                           targetScratch, &failureReason)) {
        goto end;
    }
    if (!CreateHostBuffer(vk, 128 * 128 * 4, VK_BUFFER_USAGE_TRANSFER_DST_BIT, readbackScratch, &failureReason)) {
        goto end;
    }

    {
        VulkanGreenScreenInputs inputs;
        inputs.background.imageView = decoderResolved.view;
        inputs.background.sampler = decoderResolved.sampler;
        inputs.foreground.imageView = cameraResolved.view;
        inputs.foreground.sampler = cameraResolved.sampler;
        inputs.mask.imageView = maskScratch.view;
        inputs.mask.sampler = maskScratch.sampler;
        inputs.maskWidth = kMaskWidth;
        inputs.maskHeight = kMaskHeight;

        VulkanGreenScreenRenderTarget target;
        target.device = vk.device;
        target.queue = vk.queue;
        target.commandPool = vk.commandPool;
        target.colorImage = targetScratch.image;
        target.colorImageView = targetScratch.view;
        target.colorFormat = VK_FORMAT_R8G8B8A8_UNORM;
        target.readbackBuffer = readbackScratch.buffer;
        target.readbackBufferSizeBytes = 128 * 128 * 4;
        target.extentWidth = 128;
        target.extentHeight = 128;

        if (!compositorStack.blendGreenScreen(target, inputs, &failureReason)) {
            goto end;
        }
    }
    blendRenderOk = true;

    {
        InvalidateIfNeeded(vk, readbackScratch);
        const uint8_t* pixels = static_cast<const uint8_t*>(readbackScratch.mapped);
        for (uint32_t i = 0; i < 128 * 128 * 4; ++i) {
            if (pixels[i] != 0) realNonZero++;
        }
        if (realNonZero > 0) {
            readbackOk = true;
        } else {
            failureReason = "real_readback_empty";
            goto end;
        }
    }

    // 2. Deterministic synthetic sub-lane in the same Vulkan context proving full pixel parity
    if (!CreateDeviceImageExplicit(vk, VK_FORMAT_R8G8B8A8_UNORM, 1, 1,
                                   VK_IMAGE_USAGE_TRANSFER_DST_BIT | VK_IMAGE_USAGE_SAMPLED_BIT,
                                   syntheticBackground, &failureReason)) {
        goto end;
    }
    if (!UploadSampledImage(vk, syntheticBackground, kBackground, 1, 1, 4, &failureReason)) {
        goto end;
    }

    if (!CreateDeviceImageExplicit(vk, VK_FORMAT_R8G8B8A8_UNORM, 1, 1,
                                   VK_IMAGE_USAGE_TRANSFER_DST_BIT | VK_IMAGE_USAGE_SAMPLED_BIT,
                                   syntheticForeground, &failureReason)) {
        goto end;
    }
    if (!UploadSampledImage(vk, syntheticForeground, kForeground, 1, 1, 4, &failureReason)) {
        goto end;
    }

    if (!CreateDeviceImage(vk, 128, 128,
                           VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | VK_IMAGE_USAGE_TRANSFER_SRC_BIT, false,
                           syntheticTarget, &failureReason)) {
        goto end;
    }
    if (!CreateHostBuffer(vk, 128 * 128 * 4, VK_BUFFER_USAGE_TRANSFER_DST_BIT, syntheticReadback, &failureReason)) {
        goto end;
    }

    {
        VulkanGreenScreenInputs synInputs;
        synInputs.background.imageView = syntheticBackground.view;
        synInputs.background.sampler = syntheticBackground.sampler;
        synInputs.foreground.imageView = syntheticForeground.view;
        synInputs.foreground.sampler = syntheticForeground.sampler;
        synInputs.mask.imageView = maskScratch.view;
        synInputs.mask.sampler = maskScratch.sampler;
        synInputs.maskWidth = kMaskWidth;
        synInputs.maskHeight = kMaskHeight;

        VulkanGreenScreenRenderTarget synTarget;
        synTarget.device = vk.device;
        synTarget.queue = vk.queue;
        synTarget.commandPool = vk.commandPool;
        synTarget.colorImage = syntheticTarget.image;
        synTarget.colorImageView = syntheticTarget.view;
        synTarget.colorFormat = VK_FORMAT_R8G8B8A8_UNORM;
        synTarget.readbackBuffer = syntheticReadback.buffer;
        synTarget.readbackBufferSizeBytes = 128 * 128 * 4;
        synTarget.extentWidth = 128;
        synTarget.extentHeight = 128;

        if (!compositorStack.blendGreenScreen(synTarget, synInputs, &failureReason)) {
            goto end;
        }
    }

    {
        InvalidateIfNeeded(vk, syntheticReadback);
        const uint8_t* pixels = static_cast<const uint8_t*>(syntheticReadback.mapped);

        for (uint32_t y = 0; y < 128; ++y) {
            for (uint32_t x = 0; x < 128; ++x) {
                uint32_t mx = 0, my = 0;
                MapVulkanGreenScreenMaskTexel(x, y, 128, 128, kMaskWidth, kMaskHeight, &mx, &my);
                const uint8_t maskValue = kMaskRowValues[my];
                uint8_t expected[4];
                ComputeVulkanGreenScreenReferencePixel(kBackground, kForeground, maskValue, expected);

                const uint8_t* actual = &pixels[(static_cast<size_t>(y) * 128 + x) * 4];
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
                    const bool matchesBackground = std::memcmp(actual, kBackground, 4) == 0;
                    const bool matchesForeground = std::memcmp(actual, kForeground, 4) == 0;
                    if (!withinTolerance || matchesBackground || matchesForeground) {
                        fractionalOk = false;
                    }
                }
            }
        }

        cpuReferenceParityOk = (mismatchCount == 0);
        alphaZeroPreservesBackgroundOk = zeroOk && (zeroCount > 0);
        alphaFullForegroundOk = fullOk && (fullCount > 0);
        alphaFractionalBlendOk = fractionalOk && (fractionalCount > 0);
        maskResolutionMismatchOk = (kMaskWidth != 128) && (kMaskHeight != 128) && cpuReferenceParityOk;

        if (!cpuReferenceParityOk) {
            if (failureReason.empty()) failureReason = "cpu_reference_parity_failed";
        } else if (!alphaZeroPreservesBackgroundOk) {
            if (failureReason.empty()) failureReason = "alpha_zero_preserves_background_failed";
        } else if (!alphaFullForegroundOk) {
            if (failureReason.empty()) failureReason = "alpha_full_foreground_failed";
        } else if (!alphaFractionalBlendOk) {
            if (failureReason.empty()) failureReason = "alpha_fractional_blend_failed";
        } else if (!maskResolutionMismatchOk) {
            if (failureReason.empty()) failureReason = "mask_resolution_mismatch_failed";
        }
    }

end:
    if (vk.queue != VK_NULL_HANDLE) {
        vkQueueWaitIdle(vk.queue);
    }

    syntheticTarget.Destroy(vk.device);
    syntheticReadback.Destroy(vk.device);
    syntheticForeground.Destroy(vk.device);
    syntheticBackground.Destroy(vk.device);

    targetScratch.Destroy(vk.device);
    readbackScratch.Destroy(vk.device);
    maskScratch.Destroy(vk.device);
    decoderResolved.Destroy(vk.device);
    cameraResolved.Destroy(vk.device);

    cameraImported.Destroy(vk, api);
    decoderImported.Destroy(vk, api);

    const bool allScratchNull =
        cameraResolved.IsNull() && decoderResolved.IsNull() &&
        maskScratch.IsNull() && targetScratch.IsNull() && readbackScratch.IsNull() &&
        syntheticBackground.IsNull() && syntheticForeground.IsNull() &&
        syntheticTarget.IsNull() && syntheticReadback.IsNull() &&
        cameraImported.IsNull() && decoderImported.IsNull();
    const bool helperClean =
        compositorStack.temporaryObjectsCreated() == compositorStack.temporaryObjectsReleased();
    resourceReleaseOk = allScratchNull && helperClean;

    vk.Teardown();
    diagnosticTeardownOk = vk.AllHandlesNull();
    api.Unload();

    allNativeLanesPass = vulkanSetupOk && cameraImportOk && decoderImportOk && resolveOk &&
                         maskUploadOk && blendRenderOk && readbackOk &&
                         cpuReferenceParityOk && alphaZeroPreservesBackgroundOk &&
                         alphaFullForegroundOk && alphaFractionalBlendOk &&
                         maskResolutionMismatchOk &&
                         resourceReleaseOk && diagnosticTeardownOk;

    if (allNativeLanesPass && failureReason.empty()) {
        pass = true;
        status = "PASS";
    }

    details.Str("proofBoundary", kProofBoundary);
    details.U64("realOutputWidth", 128);
    details.U64("realOutputHeight", 128);
    details.U64("realReadbackNonZeroCount", realNonZero);
    details.Bool("syntheticPixelParityLane", true);
    details.Str("pixelParityMode", "synthetic_deterministic_sublane");
    details.U64("syntheticMismatchCount", mismatchCount);
    details.Str("firstMismatch", mismatchCount == 0 ? "" : firstMismatch);
    details.U64("alphaZeroPixelCount", zeroCount);
    details.U64("alphaFullPixelCount", fullCount);
    details.U64("alphaFractionalPixelCount", fractionalCount);
    details.Int("colorTolerance", kVulkanGreenScreenReferenceColorTolerance);
    details.Str("colorContract", kVulkanGreenScreenColorContract);
    details.Str("blendFormula", kVulkanGreenScreenBlendFormula);
    details.U64("maskWidth", kMaskWidth);
    details.U64("maskHeight", kMaskHeight);
    details.U64("syntheticOutputWidth", 128);
    details.U64("syntheticOutputHeight", 128);
    details.U64("helperTemporaryObjectsCreated", compositorStack.temporaryObjectsCreated());
    details.U64("helperTemporaryObjectsReleased", compositorStack.temporaryObjectsReleased());
    details.Bool("pixelParityIsSynthetic", true);
    details.Str("diagnosticNote", "diagnostic_proof_only_no_camerax_no_production_preview_no_export_no_segmentation_model");

    std::string json = "{";
    json += "\"pass\":" + std::string(pass ? "true" : "false") + ",";
    json += "\"status\":\"" + status + "\",";
    json += "\"failureReason\":\"" + JsonEscape(failureReason) + "\",";
    json += "\"proofBoundary\":\"" + std::string(kProofBoundary) + "\",";
    json += "\"marker\":\"" + std::string(pass ? kPassMarker : kFailMarker) + "\",";
    json += "\"vulkanSetupOk\":" + std::string(vulkanSetupOk ? "true" : "false") + ",";
    json += "\"cameraImportOk\":" + std::string(cameraImportOk ? "true" : "false") + ",";
    json += "\"decoderImportOk\":" + std::string(decoderImportOk ? "true" : "false") + ",";
    json += "\"resolveOk\":" + std::string(resolveOk ? "true" : "false") + ",";
    json += "\"maskUploadOk\":" + std::string(maskUploadOk ? "true" : "false") + ",";
    json += "\"blendRenderOk\":" + std::string(blendRenderOk ? "true" : "false") + ",";
    json += "\"readbackOk\":" + std::string(readbackOk ? "true" : "false") + ",";
    json += "\"cpuReferenceParityOk\":" + std::string(cpuReferenceParityOk ? "true" : "false") + ",";
    json += "\"alphaZeroPreservesBackgroundOk\":" + std::string(alphaZeroPreservesBackgroundOk ? "true" : "false") + ",";
    json += "\"alphaFullForegroundOk\":" + std::string(alphaFullForegroundOk ? "true" : "false") + ",";
    json += "\"alphaFractionalBlendOk\":" + std::string(alphaFractionalBlendOk ? "true" : "false") + ",";
    json += "\"maskResolutionMismatchOk\":" + std::string(maskResolutionMismatchOk ? "true" : "false") + ",";
    json += "\"resourceReleaseOk\":" + std::string(resourceReleaseOk ? "true" : "false") + ",";
    json += "\"diagnosticTeardownOk\":" + std::string(diagnosticTeardownOk ? "true" : "false") + ",";
    json += "\"allNativeLanesPass\":" + std::string(allNativeLanesPass ? "true" : "false") + ",";
    json += "\"details\":" + details.Json();
    json += "}";

    return env->NewStringUTF(json.c_str());
}
