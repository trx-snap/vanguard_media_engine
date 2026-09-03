// vulkan_overlay_texture_store.cpp
// P5-OVERLAYS-TRANS / P5-OVERLAYS-PRODUCTION-EXPORT-ROUTE-A backend seam
// sub-slice N4: VulkanOverlayTextureStore implementation.
//
// On Android (__ANDROID__): real Vulkan resource store (transient command
// pool, shared sampler, per-handle persistent image/memory/view, per-upload
// fenced submit).
// On non-Android host builds: no Vulkan headers included; every method is a
// safe stub returning false / no-op.

#include "vulkan_overlay_texture_store.h"

#if defined(__ANDROID__)

#include <vulkan/vulkan.h>
#include <android/log.h>

#include <cstring>
#include <unordered_map>

#define VGLOG_OTS(...) __android_log_print(ANDROID_LOG_DEBUG, "VanguardOverlayTexStore", __VA_ARGS__)

#endif // __ANDROID__

namespace vanguard {
namespace render {

#if defined(__ANDROID__)

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

// Portable helper: convert any Vulkan non-dispatchable handle to uint64_t
// without truncation or undefined behaviour (mirrors vkHandleToU64 in
// vulkan_backend.cpp; duplicated locally since each helper is its own
// translation unit).
template <typename VkHandle>
uint64_t VkHandleToU64(VkHandle h) {
    static_assert(sizeof(VkHandle) <= sizeof(uint64_t),
                  "VkHandle too large for uint64_t");
    uint64_t v = 0;
    // NOLINTNEXTLINE(bugprone-undefined-memory-manipulation)
    std::memcpy(&v, &h, sizeof(VkHandle));
    return v;
}

struct OverlayTextureRecord {
    VkImage        image  = VK_NULL_HANDLE;
    VkDeviceMemory memory = VK_NULL_HANDLE;
    VkImageView    view   = VK_NULL_HANDLE;
    uint32_t       width  = 0;
    uint32_t       height = 0;
};

void DestroyRecord(VkDevice device, OverlayTextureRecord& record) {
    if (device == VK_NULL_HANDLE) return;
    if (record.view != VK_NULL_HANDLE) {
        vkDestroyImageView(device, record.view, nullptr);
        record.view = VK_NULL_HANDLE;
    }
    if (record.image != VK_NULL_HANDLE) {
        vkDestroyImage(device, record.image, nullptr);
        record.image = VK_NULL_HANDLE;
    }
    if (record.memory != VK_NULL_HANDLE) {
        vkFreeMemory(device, record.memory, nullptr);
        record.memory = VK_NULL_HANDLE;
    }
}

} // anonymous namespace

struct VulkanOverlayTextureStore::Impl {
    VkDevice         device           = VK_NULL_HANDLE;
    VkPhysicalDevice physDev          = VK_NULL_HANDLE;
    VkQueue          queue            = VK_NULL_HANDLE;
    uint32_t         queueFamilyIndex = UINT32_MAX;
    VkCommandPool    transientCommandPool = VK_NULL_HANDLE;
    VkSampler        sharedSampler        = VK_NULL_HANDLE;
    bool             initialized      = false;

    uint64_t nextHandle = 1; // 0 == kInvalidOverlayTextureHandle; never reused.
    std::unordered_map<uint64_t, OverlayTextureRecord> records;
};

VulkanOverlayTextureStore::VulkanOverlayTextureStore()
    : impl_(std::make_unique<Impl>()) {}

VulkanOverlayTextureStore::~VulkanOverlayTextureStore() {
    clear();
}

bool VulkanOverlayTextureStore::initialize(void* device, void* physDev, void* queue,
                                           uint32_t queueFamilyIndex) {
    if (!device || !physDev || !queue || queueFamilyIndex == UINT32_MAX) {
        return false;
    }
    Impl& s = *impl_;
    if (s.initialized) {
        return true; // idempotent
    }

    s.device           = static_cast<VkDevice>(device);
    s.physDev          = static_cast<VkPhysicalDevice>(physDev);
    s.queue            = static_cast<VkQueue>(queue);
    s.queueFamilyIndex = queueFamilyIndex;

    VkCommandPoolCreateInfo poolCI{};
    poolCI.sType            = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO;
    poolCI.flags            = VK_COMMAND_POOL_CREATE_TRANSIENT_BIT;
    poolCI.queueFamilyIndex = queueFamilyIndex;
    if (vkCreateCommandPool(s.device, &poolCI, nullptr, &s.transientCommandPool) != VK_SUCCESS) {
        VGLOG_OTS("vkCreateCommandPool (transient) failed");
        s.transientCommandPool = VK_NULL_HANDLE;
        s.device = VK_NULL_HANDLE;
        s.physDev = VK_NULL_HANDLE;
        s.queue = VK_NULL_HANDLE;
        s.queueFamilyIndex = UINT32_MAX;
        return false;
    }

    VkSamplerCreateInfo samplerCI{};
    samplerCI.sType         = VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO;
    samplerCI.magFilter     = VK_FILTER_LINEAR;
    samplerCI.minFilter     = VK_FILTER_LINEAR;
    samplerCI.mipmapMode    = VK_SAMPLER_MIPMAP_MODE_NEAREST;
    samplerCI.addressModeU  = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_BORDER;
    samplerCI.addressModeV  = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_BORDER;
    samplerCI.addressModeW  = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_BORDER;
    samplerCI.maxAnisotropy = 1.0f;
    samplerCI.borderColor   = VK_BORDER_COLOR_FLOAT_TRANSPARENT_BLACK;
    if (vkCreateSampler(s.device, &samplerCI, nullptr, &s.sharedSampler) != VK_SUCCESS) {
        VGLOG_OTS("vkCreateSampler (shared) failed");
        s.sharedSampler = VK_NULL_HANDLE;
        vkDestroyCommandPool(s.device, s.transientCommandPool, nullptr);
        s.transientCommandPool = VK_NULL_HANDLE;
        s.device = VK_NULL_HANDLE;
        s.physDev = VK_NULL_HANDLE;
        s.queue = VK_NULL_HANDLE;
        s.queueFamilyIndex = UINT32_MAX;
        return false;
    }

    s.initialized = true;
    return true;
}

bool VulkanOverlayTextureStore::createTextureRgba8888(
    const uint8_t* rgba,
    size_t rgbaByteCount,
    uint32_t width,
    uint32_t height,
    uint32_t rowStrideBytes,
    VulkanOverlayTextureHandle* outHandle,
    VulkanOverlayTextureInfo* outInfo) {
    Impl& s = *impl_;

    auto fail = [&]() -> bool {
        if (outHandle) *outHandle = kInvalidOverlayTextureHandle;
        if (outInfo) *outInfo = VulkanOverlayTextureInfo{};
        return false;
    };

    // --- Validation (fails closed, in order, before any Vulkan call) ---
    if (!s.initialized || s.device == VK_NULL_HANDLE || s.physDev == VK_NULL_HANDLE ||
        s.queue == VK_NULL_HANDLE) {
        return fail();
    }
    if (!rgba || !outHandle) {
        return fail();
    }
    if (width == 0 || height == 0) {
        return fail();
    }

    VkPhysicalDeviceProperties physProps{};
    vkGetPhysicalDeviceProperties(s.physDev, &physProps);
    if (width > physProps.limits.maxImageDimension2D ||
        height > physProps.limits.maxImageDimension2D) {
        return fail();
    }

    const uint64_t minStride = static_cast<uint64_t>(width) * 4ull;
    const uint64_t stride = rowStrideBytes == 0 ? minStride : static_cast<uint64_t>(rowStrideBytes);
    if (stride < minStride) {
        return fail();
    }
    if (stride * static_cast<uint64_t>(height) > static_cast<uint64_t>(rgbaByteCount)) {
        return fail();
    }

    // --- Transient state for this call; destroyAll() reverses whatever of
    //     this was created so far on any failure path below. ---
    VkImage        image         = VK_NULL_HANDLE;
    VkDeviceMemory memory        = VK_NULL_HANDLE;
    VkImageView    view          = VK_NULL_HANDLE;
    VkBuffer       stagingBuffer = VK_NULL_HANDLE;
    VkDeviceMemory stagingMemory = VK_NULL_HANDLE;
    void*          stagingMapped = nullptr;
    VkCommandBuffer cmd          = VK_NULL_HANDLE;
    VkFence        fence         = VK_NULL_HANDLE;

    auto destroyAll = [&]() {
        if (fence != VK_NULL_HANDLE) {
            vkDestroyFence(s.device, fence, nullptr);
            fence = VK_NULL_HANDLE;
        }
        if (cmd != VK_NULL_HANDLE) {
            vkFreeCommandBuffers(s.device, s.transientCommandPool, 1, &cmd);
            cmd = VK_NULL_HANDLE;
        }
        if (stagingMapped != nullptr && stagingMemory != VK_NULL_HANDLE) {
            vkUnmapMemory(s.device, stagingMemory);
            stagingMapped = nullptr;
        }
        if (stagingBuffer != VK_NULL_HANDLE) {
            vkDestroyBuffer(s.device, stagingBuffer, nullptr);
            stagingBuffer = VK_NULL_HANDLE;
        }
        if (stagingMemory != VK_NULL_HANDLE) {
            vkFreeMemory(s.device, stagingMemory, nullptr);
            stagingMemory = VK_NULL_HANDLE;
        }
        if (view != VK_NULL_HANDLE) {
            vkDestroyImageView(s.device, view, nullptr);
            view = VK_NULL_HANDLE;
        }
        if (image != VK_NULL_HANDLE) {
            vkDestroyImage(s.device, image, nullptr);
            image = VK_NULL_HANDLE;
        }
        if (memory != VK_NULL_HANDLE) {
            vkFreeMemory(s.device, memory, nullptr);
            memory = VK_NULL_HANDLE;
        }
    };

    // --- 1. Persistent device-local sampled image ---
    VkImageCreateInfo imageCI{};
    imageCI.sType         = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO;
    imageCI.imageType     = VK_IMAGE_TYPE_2D;
    imageCI.format        = VK_FORMAT_R8G8B8A8_UNORM;
    imageCI.extent        = {width, height, 1};
    imageCI.mipLevels     = 1;
    imageCI.arrayLayers   = 1;
    imageCI.samples       = VK_SAMPLE_COUNT_1_BIT;
    imageCI.tiling        = VK_IMAGE_TILING_OPTIMAL;
    imageCI.usage         = VK_IMAGE_USAGE_TRANSFER_DST_BIT | VK_IMAGE_USAGE_SAMPLED_BIT;
    imageCI.sharingMode   = VK_SHARING_MODE_EXCLUSIVE;
    imageCI.initialLayout = VK_IMAGE_LAYOUT_UNDEFINED;
    if (vkCreateImage(s.device, &imageCI, nullptr, &image) != VK_SUCCESS) {
        image = VK_NULL_HANDLE;
        destroyAll();
        return fail();
    }

    VkPhysicalDeviceMemoryProperties memProps{};
    vkGetPhysicalDeviceMemoryProperties(s.physDev, &memProps);

    VkMemoryRequirements imageMemReq{};
    vkGetImageMemoryRequirements(s.device, image, &imageMemReq);
    uint32_t imageTypeIndex = FindMemoryType(memProps, imageMemReq.memoryTypeBits,
                                             VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT);
    if (imageTypeIndex == UINT32_MAX) {
        imageTypeIndex = FindMemoryType(memProps, imageMemReq.memoryTypeBits, 0);
    }
    if (imageTypeIndex == UINT32_MAX) {
        destroyAll();
        return fail();
    }
    VkMemoryAllocateInfo imageAlloc{};
    imageAlloc.sType           = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
    imageAlloc.allocationSize  = imageMemReq.size;
    imageAlloc.memoryTypeIndex = imageTypeIndex;
    if (vkAllocateMemory(s.device, &imageAlloc, nullptr, &memory) != VK_SUCCESS) {
        memory = VK_NULL_HANDLE;
        destroyAll();
        return fail();
    }
    if (vkBindImageMemory(s.device, image, memory, 0) != VK_SUCCESS) {
        destroyAll();
        return fail();
    }

    VkImageViewCreateInfo viewCI{};
    viewCI.sType                       = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO;
    viewCI.image                       = image;
    viewCI.viewType                    = VK_IMAGE_VIEW_TYPE_2D;
    viewCI.format                      = VK_FORMAT_R8G8B8A8_UNORM;
    viewCI.subresourceRange.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
    viewCI.subresourceRange.levelCount = 1;
    viewCI.subresourceRange.layerCount = 1;
    if (vkCreateImageView(s.device, &viewCI, nullptr, &view) != VK_SUCCESS) {
        view = VK_NULL_HANDLE;
        destroyAll();
        return fail();
    }

    // --- 2. Host-visible tightly packed staging buffer ---
    // Copy row-by-row from `rgba` (read at `stride` bytes/row, never past
    // rgbaByteCount) into a tightly packed (`minStride` bytes/row) buffer.
    const VkDeviceSize stagingSize = static_cast<VkDeviceSize>(minStride) * height;
    VkBufferCreateInfo bufferCI{};
    bufferCI.sType       = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO;
    bufferCI.size        = stagingSize;
    bufferCI.usage       = VK_BUFFER_USAGE_TRANSFER_SRC_BIT;
    bufferCI.sharingMode = VK_SHARING_MODE_EXCLUSIVE;
    if (vkCreateBuffer(s.device, &bufferCI, nullptr, &stagingBuffer) != VK_SUCCESS) {
        stagingBuffer = VK_NULL_HANDLE;
        destroyAll();
        return fail();
    }

    VkMemoryRequirements bufMemReq{};
    vkGetBufferMemoryRequirements(s.device, stagingBuffer, &bufMemReq);
    bool coherent = true;
    uint32_t bufTypeIndex = FindMemoryType(
        memProps, bufMemReq.memoryTypeBits,
        VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT);
    if (bufTypeIndex == UINT32_MAX) {
        coherent = false;
        bufTypeIndex = FindMemoryType(memProps, bufMemReq.memoryTypeBits,
                                      VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT);
    }
    if (bufTypeIndex == UINT32_MAX) {
        destroyAll();
        return fail();
    }
    VkMemoryAllocateInfo bufAlloc{};
    bufAlloc.sType           = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
    bufAlloc.allocationSize  = bufMemReq.size;
    bufAlloc.memoryTypeIndex = bufTypeIndex;
    if (vkAllocateMemory(s.device, &bufAlloc, nullptr, &stagingMemory) != VK_SUCCESS) {
        stagingMemory = VK_NULL_HANDLE;
        destroyAll();
        return fail();
    }
    if (vkBindBufferMemory(s.device, stagingBuffer, stagingMemory, 0) != VK_SUCCESS) {
        destroyAll();
        return fail();
    }
    if (vkMapMemory(s.device, stagingMemory, 0, stagingSize, 0, &stagingMapped) != VK_SUCCESS) {
        stagingMapped = nullptr;
        destroyAll();
        return fail();
    }

    {
        uint8_t* dst = static_cast<uint8_t*>(stagingMapped);
        const uint8_t* src = rgba;
        const size_t rowBytes = static_cast<size_t>(minStride);
        const size_t srcStride = static_cast<size_t>(stride);
        for (uint32_t row = 0; row < height; ++row) {
            std::memcpy(dst + static_cast<size_t>(row) * rowBytes,
                        src + static_cast<size_t>(row) * srcStride,
                        rowBytes);
        }
    }

    if (!coherent) {
        VkMappedMemoryRange range{};
        range.sType  = VK_STRUCTURE_TYPE_MAPPED_MEMORY_RANGE;
        range.memory = stagingMemory;
        range.offset = 0;
        range.size   = VK_WHOLE_SIZE;
        vkFlushMappedMemoryRanges(s.device, 1, &range);
    }

    // --- 3. Record + submit the upload on this store's own transient
    //        command pool, waited on a fresh per-call fence. ---
    VkCommandBufferAllocateInfo cmdAI{};
    cmdAI.sType              = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO;
    cmdAI.commandPool        = s.transientCommandPool;
    cmdAI.level              = VK_COMMAND_BUFFER_LEVEL_PRIMARY;
    cmdAI.commandBufferCount = 1;
    if (vkAllocateCommandBuffers(s.device, &cmdAI, &cmd) != VK_SUCCESS) {
        cmd = VK_NULL_HANDLE;
        destroyAll();
        return fail();
    }

    VkCommandBufferBeginInfo beginInfo{};
    beginInfo.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
    beginInfo.flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
    if (vkBeginCommandBuffer(cmd, &beginInfo) != VK_SUCCESS) {
        destroyAll();
        return fail();
    }

    VkImageMemoryBarrier toTransferDst{};
    toTransferDst.sType                       = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER;
    toTransferDst.srcAccessMask               = 0;
    toTransferDst.dstAccessMask               = VK_ACCESS_TRANSFER_WRITE_BIT;
    toTransferDst.oldLayout                   = VK_IMAGE_LAYOUT_UNDEFINED;
    toTransferDst.newLayout                   = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;
    toTransferDst.srcQueueFamilyIndex         = VK_QUEUE_FAMILY_IGNORED;
    toTransferDst.dstQueueFamilyIndex         = VK_QUEUE_FAMILY_IGNORED;
    toTransferDst.image                       = image;
    toTransferDst.subresourceRange.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
    toTransferDst.subresourceRange.levelCount = 1;
    toTransferDst.subresourceRange.layerCount = 1;
    vkCmdPipelineBarrier(cmd, VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT,
                         0, 0, nullptr, 0, nullptr, 1, &toTransferDst);

    VkBufferImageCopy copyRegion{};
    copyRegion.imageSubresource.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
    copyRegion.imageSubresource.layerCount = 1;
    copyRegion.imageExtent                 = {width, height, 1};
    vkCmdCopyBufferToImage(cmd, stagingBuffer, image, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
                           1, &copyRegion);

    VkImageMemoryBarrier toShaderRead = toTransferDst;
    toShaderRead.srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT;
    toShaderRead.dstAccessMask = VK_ACCESS_SHADER_READ_BIT;
    toShaderRead.oldLayout     = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;
    toShaderRead.newLayout     = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
    vkCmdPipelineBarrier(cmd, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT,
                         0, 0, nullptr, 0, nullptr, 1, &toShaderRead);

    if (vkEndCommandBuffer(cmd) != VK_SUCCESS) {
        destroyAll();
        return fail();
    }

    VkFenceCreateInfo fenceCI{};
    fenceCI.sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO;
    if (vkCreateFence(s.device, &fenceCI, nullptr, &fence) != VK_SUCCESS) {
        fence = VK_NULL_HANDLE;
        destroyAll();
        return fail();
    }

    VkSubmitInfo submitInfo{};
    submitInfo.sType              = VK_STRUCTURE_TYPE_SUBMIT_INFO;
    submitInfo.commandBufferCount = 1;
    submitInfo.pCommandBuffers    = &cmd;
    if (vkQueueSubmit(s.queue, 1, &submitInfo, fence) != VK_SUCCESS) {
        destroyAll();
        return fail();
    }

    if (vkWaitForFences(s.device, 1, &fence, VK_TRUE, UINT64_MAX) != VK_SUCCESS) {
        destroyAll();
        return fail();
    }

    // Upload complete; release the transient upload-only objects. Only the
    // persistent image/memory/view survive past this call.
    vkDestroyFence(s.device, fence, nullptr);
    fence = VK_NULL_HANDLE;
    vkFreeCommandBuffers(s.device, s.transientCommandPool, 1, &cmd);
    cmd = VK_NULL_HANDLE;
    vkUnmapMemory(s.device, stagingMemory);
    stagingMapped = nullptr;
    vkDestroyBuffer(s.device, stagingBuffer, nullptr);
    stagingBuffer = VK_NULL_HANDLE;
    vkFreeMemory(s.device, stagingMemory, nullptr);
    stagingMemory = VK_NULL_HANDLE;

    // --- 4. Store the persistent record under a fresh, never-reused handle ---
    const VulkanOverlayTextureHandle handle = s.nextHandle++;
    OverlayTextureRecord record;
    record.image  = image;
    record.memory = memory;
    record.view   = view;
    record.width  = width;
    record.height = height;
    s.records.emplace(handle, record);

    *outHandle = handle;
    if (outInfo) {
        outInfo->imageViewHandle = VkHandleToU64(view);
        outInfo->samplerHandle   = VkHandleToU64(s.sharedSampler);
        outInfo->width           = width;
        outInfo->height          = height;
    }
    return true;
}

bool VulkanOverlayTextureStore::releaseTexture(VulkanOverlayTextureHandle handle) {
    Impl& s = *impl_;
    auto it = s.records.find(handle);
    if (it == s.records.end()) {
        return false;
    }
    if (s.device != VK_NULL_HANDLE) {
        vkDeviceWaitIdle(s.device);
    }
    DestroyRecord(s.device, it->second);
    s.records.erase(it);
    return true;
}

bool VulkanOverlayTextureStore::getTextureInfo(VulkanOverlayTextureHandle handle,
                                               VulkanOverlayTextureInfo* outInfo) const {
    if (!outInfo) {
        return false;
    }
    const Impl& s = *impl_;
    auto it = s.records.find(handle);
    if (it == s.records.end()) {
        *outInfo = VulkanOverlayTextureInfo{};
        return false;
    }
    outInfo->imageViewHandle = VkHandleToU64(it->second.view);
    outInfo->samplerHandle   = VkHandleToU64(s.sharedSampler);
    outInfo->width           = it->second.width;
    outInfo->height          = it->second.height;
    return true;
}

void VulkanOverlayTextureStore::clear() {
    Impl& s = *impl_;
    if (s.device != VK_NULL_HANDLE) {
        vkDeviceWaitIdle(s.device);
    }
    for (auto& kv : s.records) {
        DestroyRecord(s.device, kv.second);
    }
    s.records.clear();

    if (s.sharedSampler != VK_NULL_HANDLE && s.device != VK_NULL_HANDLE) {
        vkDestroySampler(s.device, s.sharedSampler, nullptr);
    }
    s.sharedSampler = VK_NULL_HANDLE;

    if (s.transientCommandPool != VK_NULL_HANDLE && s.device != VK_NULL_HANDLE) {
        vkDestroyCommandPool(s.device, s.transientCommandPool, nullptr);
    }
    s.transientCommandPool = VK_NULL_HANDLE;

    s.device           = VK_NULL_HANDLE;
    s.physDev          = VK_NULL_HANDLE;
    s.queue            = VK_NULL_HANDLE;
    s.queueFamilyIndex = UINT32_MAX;
    s.initialized      = false;
}

#else // !__ANDROID__

struct VulkanOverlayTextureStore::Impl {};

VulkanOverlayTextureStore::VulkanOverlayTextureStore()
    : impl_(std::make_unique<Impl>()) {}

VulkanOverlayTextureStore::~VulkanOverlayTextureStore() = default;

bool VulkanOverlayTextureStore::initialize(void*, void*, void*, uint32_t) {
    return false;
}

bool VulkanOverlayTextureStore::createTextureRgba8888(
    const uint8_t*, size_t, uint32_t, uint32_t, uint32_t,
    VulkanOverlayTextureHandle* outHandle, VulkanOverlayTextureInfo* outInfo) {
    if (outHandle) *outHandle = kInvalidOverlayTextureHandle;
    if (outInfo) *outInfo = VulkanOverlayTextureInfo{};
    return false;
}

bool VulkanOverlayTextureStore::releaseTexture(VulkanOverlayTextureHandle) {
    return false;
}

bool VulkanOverlayTextureStore::getTextureInfo(VulkanOverlayTextureHandle,
                                               VulkanOverlayTextureInfo* outInfo) const {
    if (outInfo) *outInfo = VulkanOverlayTextureInfo{};
    return false;
}

void VulkanOverlayTextureStore::clear() {
    // no-op on host builds
}

#endif // __ANDROID__

} // namespace render
} // namespace vanguard
