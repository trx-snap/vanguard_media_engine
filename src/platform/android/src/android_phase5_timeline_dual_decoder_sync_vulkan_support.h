// P5-COMPOSITOR-TRANS (sub-slice DUAL-DECODER-SYNC): private diagnostic
// Vulkan / AHardwareBuffer support for the dual MediaCodec synchronized
// ingest -> AHardwareBuffer -> Vulkan crossfade proof JNI.
//
// Android-only private header. It is included only by
// android_phase5_timeline_dual_decoder_sync_jni.cpp (the composition root
// that owns argument validation, result shaping and the exported JNI symbol)
// and its own .cpp. Nothing here is part of the public vanguard render API
// and no production VulkanBackend state is touched.
//
// Ownership split:
//   - This header/.cpp own the diagnostic mechanics: libandroid dynamic
//     lookup, the temporary VkInstance/VkDevice with the AHardwareBuffer
//     import extension + samplerYcbcrConversion feature, scratch images /
//     host readback buffers, AHardwareBuffer import through the private
//     VulkanHardwareBufferImage helper, the YCbCr -> RGBA8 resolve pass with
//     the existing AOT passthrough SPIR-V, geometry conversion, transition
//     render + readback, and pixel telemetry arithmetic.
//   - The JNI translation unit owns argument validation, lane orchestration,
//     JSON result shaping and the exported function.
//
// Diagnostic only: no export session, no encoder/mux, no audio, no app UI.

#ifndef VANGUARD_ANDROID_PHASE5_TIMELINE_DUAL_DECODER_SYNC_VULKAN_SUPPORT_H_
#define VANGUARD_ANDROID_PHASE5_TIMELINE_DUAL_DECODER_SYNC_VULKAN_SUPPORT_H_

#include <jni.h>

#ifndef VK_USE_PLATFORM_ANDROID_KHR
#define VK_USE_PLATFORM_ANDROID_KHR
#endif
#include <vulkan/vulkan.h>

#include <android/hardware_buffer.h>

#include <cstdint>
#include <string>
#include <vector>

#include "vanguard/compositors/vg_timeline_compositor_node.h"
#include "vanguard/render/hardware_buffer_import.h"
#include "vulkan_hardware_buffer_image.h"
#include "vulkan_timeline_transition_compositor.h"

namespace vanguard::android_diag::dual_decoder_sync {

// ── Diagnostic constants ────────────────────────────────────────────────────

constexpr uint32_t kCanvasWidth    = 128;
constexpr uint32_t kCanvasHeight   = 128;
constexpr int      kColorTolerance = 8;
constexpr double   kMaxMismatchFraction = 0.01;
constexpr uint32_t kMaxFrameDimension   = 16384;
constexpr uint64_t kFenceTimeoutNs = 5ull * 1000ull * 1000ull * 1000ull;
constexpr VkFormat kColorFormat    = VK_FORMAT_R8G8B8A8_UNORM;
constexpr VkDeviceSize kReadbackBytes =
    static_cast<VkDeviceSize>(kCanvasWidth) * kCanvasHeight * 4;

constexpr const char* kAhbExtensionName    = "VK_ANDROID_external_memory_android_hardware_buffer";
constexpr const char* kForeignQueueExtName = "VK_EXT_queue_family_foreign";

// ── libandroid dynamic lookup ───────────────────────────────────────────────

using FnAHardwareBufferFromHardwareBuffer = AHardwareBuffer* (*)(JNIEnv*, jobject);
using FnAHardwareBufferAcquire            = void (*)(AHardwareBuffer*);
using FnAHardwareBufferRelease            = void (*)(AHardwareBuffer*);
using FnAHardwareBufferDescribe           = void (*)(const AHardwareBuffer*, AHardwareBuffer_Desc*);

// AHardwareBuffer_* entry points resolved with dlsym so the library keeps no
// strong reference to symbols that are missing below API 26 (minSdk 24).
struct AndroidBufferApi {
    void* lib = nullptr;
    FnAHardwareBufferFromHardwareBuffer fromHardwareBuffer = nullptr;
    FnAHardwareBufferAcquire            acquire            = nullptr;
    FnAHardwareBufferRelease            release            = nullptr;
    FnAHardwareBufferDescribe           describe           = nullptr;

    // Returns false with a stable error token when libandroid or any of the
    // four entry points is unavailable. Never throws.
    bool Load(std::string* outError);
    void Unload();
};

// One resolved + acquired AHardwareBuffer reference owned by the diagnostic.
struct AcquiredBuffer {
    AHardwareBuffer*     ahb = nullptr;
    AHardwareBuffer_Desc desc{};
    bool                 acquired = false;

    void Release(const AndroidBufferApi& api);
};

// ── Temporary Vulkan device (owned entirely by this diagnostic) ─────────────

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
    bool             foreignQueueExtEnabled = false;
    bool             teardownWaitIdleOk = false;

    PFN_vkGetAndroidHardwareBufferPropertiesANDROID fnGetAhbProps  = nullptr;
    PFN_vkCreateSamplerYcbcrConversion              fnCreateYcbcr  = nullptr;
    PFN_vkDestroySamplerYcbcrConversion             fnDestroyYcbcr = nullptr;

    // Creates instance -> selects a non-CPU graphics device exposing the
    // AHardwareBuffer extension + samplerYcbcrConversion feature -> creates
    // device / queue / transient command pool. Returns false with
    // *outUnsupported == true when Vulkan or the AHardwareBuffer import path
    // is structurally unavailable on this device (no crash), or
    // *outUnsupported == false for a genuine failure. Tears down on failure.
    bool Setup(std::string* outError, bool* outUnsupported);

    // Destroys pool -> device -> instance. Safe to call repeatedly.
    void Teardown();

    bool AllHandlesNull() const;
};

// ── Scratch images / buffers ────────────────────────────────────────────────

struct ScratchImage {
    VkImage        image   = VK_NULL_HANDLE;
    VkDeviceMemory memory  = VK_NULL_HANDLE;
    VkImageView    view    = VK_NULL_HANDLE;
    VkSampler      sampler = VK_NULL_HANDLE;
    uint32_t       width   = 0;
    uint32_t       height  = 0;

    void Destroy(VkDevice device);
    bool IsNull() const;
};

struct ScratchBuffer {
    VkBuffer       buffer   = VK_NULL_HANDLE;
    VkDeviceMemory memory   = VK_NULL_HANDLE;
    VkDeviceSize   size     = 0;
    void*          mapped   = nullptr;
    bool           coherent = false;

    void Destroy(VkDevice device);
    bool IsNull() const;
};

// RGBA8 optimal-tiling device-local image (+ optional NEAREST/CLAMP sampler).
bool CreateDeviceImage(const VulkanScratch& vk,
                       uint32_t width,
                       uint32_t height,
                       VkImageUsageFlags usage,
                       bool withSampler,
                       ScratchImage& out,
                       std::string* outError);

// Host-visible (coherent when available) persistently mapped buffer.
bool CreateHostBuffer(const VulkanScratch& vk,
                      VkDeviceSize size,
                      VkBufferUsageFlags usage,
                      ScratchBuffer& out,
                      std::string* outError);

// vkInvalidateMappedMemoryRanges for non-coherent readback memory; no-op
// when the buffer memory is host-coherent.
void InvalidateIfNeeded(const VulkanScratch& vk, const ScratchBuffer& buf);

// ── AHardwareBuffer import (through the private production helper) ──────────

struct ImportedFrame {
    AcquiredBuffer                             buffer;
    vanguard::render::VulkanHardwareBufferImage image;
    uint32_t    cropWidth  = 0;
    uint32_t    cropHeight = 0;
    // True once AHardwareBuffer_describe filled buffer.desc (telemetry may
    // be recorded even when a later validation step fails).
    bool        described  = false;
    // Stable token of the helper's HardwareBufferImportResult, empty until
    // the import was attempted.
    std::string importResultName;
    bool        imported   = false;

    void Destroy(const VulkanScratch& vk, const AndroidBufferApi& api);
    bool IsNull() const;
};

const char* ImportResultName(vanguard::render::HardwareBufferImportResult r);

// Resolves the java HardwareBuffer, acquires a native reference, describes
// it, validates it against the Kotlin-declared crop extent and imports it as
// a sampled (external-format YCbCr when applicable) image. `prefix` ("from"
// / "to") is used only to build stable error tokens.
bool ImportFrame(JNIEnv* env,
                 const AndroidBufferApi& api,
                 const VulkanScratch& vk,
                 jobject jHardwareBuffer,
                 uint32_t cropWidth,
                 uint32_t cropHeight,
                 const std::string& prefix,
                 ImportedFrame& out,
                 std::string* outError);

// ── Resolve pass: imported (possibly YCbCr) image -> RGBA8 intermediate ─────

// Draws the imported frame's declared crop (top-left cropWidth x cropHeight
// of the possibly padded buffer) as a fullscreen triangle into a fresh RGBA8
// image of the crop extent using the imported image's own immutable-sampler
// descriptor set / pipeline layout and the AOT passthrough SPIR-V. Leaves the
// intermediate in SHADER_READ_ONLY_OPTIMAL with a NEAREST/CLAMP sampler.
// Every temporary object is destroyed before returning; `outRgba` is left for
// the caller to destroy.
bool ResolveImportedFrame(const VulkanScratch& vk,
                          const ImportedFrame& frame,
                          ScratchImage& outRgba,
                          std::string* outError);

// ── Transition geometry conversion ──────────────────────────────────────────

vanguard::render::VulkanTimelineTransitionGeometry ToVulkanGeometry(
    const vanguard::compositors::TimelineTransitionProgress& p);

vanguard::render::VulkanTimelineTransitionLayerImage LayerOf(const ScratchImage& img);

// ── Transition render + readback ────────────────────────────────────────────

struct RenderContext {
    const VulkanScratch* vk = nullptr;
    vanguard::render::VulkanTimelineTransitionCompositor* compositor = nullptr;
    vanguard::render::VulkanTimelineTransitionRenderTarget target;
    const ScratchBuffer* readback = nullptr;
};

// Binds the canvas-sized color target / readback buffer of `vk` into
// `ctx.target` (clear = opaque black).
void BindRenderTarget(RenderContext& ctx,
                      const VulkanScratch& vk,
                      vanguard::render::VulkanTimelineTransitionCompositor& compositor,
                      const ScratchImage& colorTarget,
                      const ScratchBuffer& readback);

// Renders one transition through the compositor helper and copies the
// kReadbackBytes RGBA8 canvas into `outPixels`.
bool RenderAndRead(RenderContext& ctx,
                   const ScratchImage& from,
                   const ScratchImage& to,
                   const vanguard::render::VulkanTimelineTransitionGeometry& geometry,
                   std::vector<uint8_t>& outPixels,
                   std::string* outError);

// ── Pixel telemetry ─────────────────────────────────────────────────────────

const uint8_t* PixelAt(const std::vector<uint8_t>& px, uint32_t x, uint32_t yTop);
std::string    RgbString(const uint8_t* p);
uint64_t       Checksum(const std::vector<uint8_t>& px);
double         MeanLuma(const std::vector<uint8_t>& px);
uint64_t       SumAbsDiff(const std::vector<uint8_t>& a, const std::vector<uint8_t>& b);

// Counts canvas pixels where any RGB channel of `mid` differs from the
// per-channel blend of `from`/`to` at weight p by more than kColorTolerance.
uint32_t CountBlendMismatches(const std::vector<uint8_t>& from,
                              const std::vector<uint8_t>& to,
                              const std::vector<uint8_t>& mid,
                              double p);

std::string VersionString(uint32_t v);

} // namespace vanguard::android_diag::dual_decoder_sync

#endif // VANGUARD_ANDROID_PHASE5_TIMELINE_DUAL_DECODER_SYNC_VULKAN_SUPPORT_H_
