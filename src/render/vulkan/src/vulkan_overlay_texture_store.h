// vulkan_overlay_texture_store.h
// P5-OVERLAYS-TRANS / P5-OVERLAYS-PRODUCTION-EXPORT-ROUTE-A backend seam
// sub-slice N4: private helper - VulkanOverlayTextureStore.
//
// Backend-owned Vulkan texture store for static sticker overlay RGBA8888
// pixels and dynamic R8 masks (for future Android Duet Vulkan green-screen
// preview). Callers upload once via createTextureRgba8888() or
// createTextureR8() and receive a stable VulkanOverlayTextureHandle plus the
// VkImageView/VkSampler pair (as uint64_t) needed to populate a
// VulkanOverlayFrameDraw (imageViewHandle/samplerHandle); this store never
// records draws itself and is not wired into VulkanFrameRenderer,
// VulkanOverlayFrameRenderer, JNI, or Kotlin by this sub-slice.
//
// Each created texture is a persistent, device-local, optimally-tiled
// VK_FORMAT_R8G8B8A8_UNORM (or VK_FORMAT_R8_UNORM) VkImage (TRANSFER_DST |
// SAMPLED usage) left in VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL, with its
// own VkImageView. Every texture created by this store shares one LINEAR-filtered,
// CLAMP_TO_BORDER / transparent-black VkSampler created once by initialize()
// and destroyed by clear() -- the sampler is never per-texture.
//
// Upload is store-owned end-to-end: initialize() creates a dedicated
// VK_COMMAND_POOL_CREATE_TRANSIENT_BIT command pool for the caller's queue
// family (never the caller's own long-lived command pool); every
// createTextureRgba8888() call allocates one one-time command buffer from
// that pool, records the host-visible-staging-buffer upload and the
// UNDEFINED -> TRANSFER_DST_OPTIMAL -> SHADER_READ_ONLY_OPTIMAL layout
// transitions, submits it against a fresh per-call VkFence, waits on that
// fence (never vkQueueWaitIdle, so concurrent submits on the same queue are
// never globally stalled by this store), then frees the command buffer and
// destroys the fence -- only the persistent image/memory/view survive past
// the call.
//
// rowStrideBytes lets the caller pass a source buffer whose rows are padded
// wider than width * 4 bytes (e.g. a platform bitmap's native stride):
// rowStrideBytes == 0 means "tightly packed" (stride == width * 4); when
// rowStrideBytes is nonzero it must be >= width * 4. This store copies
// exactly `height` rows of `width * 4` bytes each -- read at the given
// stride -- into a tightly packed staging buffer before upload.
// rgbaByteCount is the caller-declared size of `rgba` in bytes and must be
// >= stride * height; this store never reads past rgbaByteCount and never
// reads any row padding beyond width * 4 bytes.
//
// Handles are a monotonically increasing uint64_t counter starting at 1
// (0 == kInvalidOverlayTextureHandle) that is never reused, even after
// releaseTexture()/clear() -- a stale or unknown handle passed to
// releaseTexture() or getTextureInfo() simply returns false.
//
// On any failure partway through createTextureRgba8888() (image, memory,
// view, staging buffer, command buffer, fence, or submit), every Vulkan
// object already created by that call is destroyed before returning false;
// no partial record is ever stored.
//
// releaseTexture()/clear() wait for device idle before destroying an
// image's view/image/memory (matching VulkanBackend::shutdown()'s existing
// wait-idle-before-teardown contract); clear() additionally destroys the
// shared sampler and the transient command pool.
//
// Confined to the private Vulkan render backend implementation; never
// included from a public header. This header includes
// vanguard/render/vulkan_backend.h only to reuse the already-public
// VulkanOverlayTextureHandle / VulkanOverlayTextureInfo types, and never
// includes a Vulkan or Android header itself; on non-Android host builds
// every method compiles to a safe stub that returns false (or is a no-op)
// without touching any Vulkan symbol.
//
// Threading contract (Opus validation): this store has no internal locking
// and provides no external synchronization of its own. initialize(),
// createTextureRgba8888(), releaseTexture(), getTextureInfo(), and clear()
// must all be invoked from the same thread/serialized lane that owns the
// enclosing VulkanBackend's render loop/session, and must never be called
// concurrently with that backend's renderFrame()/releaseOverlayTexture()/
// clearOverlayTextures() (or with each other) -- callers own serialization.

#pragma once

#include "vanguard/render/vulkan_backend.h"

#include <cstddef>
#include <cstdint>
#include <memory>

namespace vanguard {
namespace render {

class VulkanOverlayTextureStore {
public:
    VulkanOverlayTextureStore();
    ~VulkanOverlayTextureStore();

    VulkanOverlayTextureStore(const VulkanOverlayTextureStore&) = delete;
    VulkanOverlayTextureStore& operator=(const VulkanOverlayTextureStore&) = delete;

    // Must be called once, after the owning VulkanBackend has a live
    // VkDevice/VkPhysicalDevice/VkQueue. device/physDev/queue are VkDevice /
    // VkPhysicalDevice / VkQueue cast to void*; queueFamilyIndex is the
    // family `queue` was retrieved from (used to create this store's own
    // transient command pool). Creates the transient command pool and the
    // one shared sampler; returns false (leaving the store uninitialized)
    // if either creation fails.
    bool initialize(void* device, void* physDev, void* queue, uint32_t queueFamilyIndex);

    // Uploads `rgba` into a brand-new persistent, sampled RGBA8 texture and
    // returns its handle plus VkImageView/VkSampler (as uint64_t) via
    // outInfo. Fails closed (returns false, *outHandle ==
    // kInvalidOverlayTextureHandle, *outInfo zeroed when non-null, and
    // nothing is created or stored) if: the store is not initialized; rgba
    // or outHandle is null; width or height is 0; width or height exceeds
    // VkPhysicalDeviceLimits::maxImageDimension2D; the effective row stride
    // (rowStrideBytes, or width * 4 when rowStrideBytes == 0) is smaller
    // than width * 4; or stride * height exceeds rgbaByteCount. outInfo may
    // be null when the caller only needs the handle.
    bool createTextureRgba8888(const uint8_t* rgba,
                               size_t rgbaByteCount,
                               uint32_t width,
                               uint32_t height,
                               uint32_t rowStrideBytes,
                               VulkanOverlayTextureHandle* outHandle,
                               VulkanOverlayTextureInfo* outInfo);

    // Uploads `mask` into a brand-new persistent, sampled R8 texture and returns
    // its handle plus info. Same fail-closed style and semantics as createTextureRgba8888.
    bool createTextureR8(const uint8_t* mask,
                         size_t maskByteCount,
                         uint32_t width,
                         uint32_t height,
                         uint32_t rowStrideBytes,
                         VulkanOverlayTextureHandle* outHandle,
                         VulkanOverlayTextureInfo* outInfo);

    // Updates an existing R8 texture in-place with new `mask` pixels. Fails closed
    // without modifying the image if handle is unknown, format is not R8, size
    // mismatches the existing texture, or parameters are invalid. Do not recreate
    // the image; it uploads to the existing one.
    bool updateTextureR8(VulkanOverlayTextureHandle handle,
                         const uint8_t* mask,
                         size_t maskByteCount,
                         uint32_t width,
                         uint32_t height,
                         uint32_t rowStrideBytes,
                         VulkanOverlayTextureInfo* outInfo = nullptr);

    // Waits for device idle, then destroys handle's VkImageView/VkImage/
    // VkDeviceMemory and forgets the handle. Returns false (no-op) for an
    // unknown or already-released handle; the shared sampler is never
    // touched.
    bool releaseTexture(VulkanOverlayTextureHandle handle);

    // Returns true and fills *outInfo iff handle is an active texture and
    // outInfo is non-null. Returns false otherwise, zeroing *outInfo when
    // it is non-null but handle is unknown.
    bool getTextureInfo(VulkanOverlayTextureHandle handle, VulkanOverlayTextureInfo* outInfo) const;

    // Waits for device idle, destroys every active texture's VkImageView/
    // VkImage/VkDeviceMemory, then destroys the shared sampler and the
    // transient command pool. Idempotent; safe to call with zero active
    // textures or before initialize() has ever succeeded. Must be called by
    // the owning VulkanBackend before its VkDevice is destroyed.
    void clear();

private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};

} // namespace render
} // namespace vanguard
