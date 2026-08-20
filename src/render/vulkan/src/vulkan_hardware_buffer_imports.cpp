// vulkan_hardware_buffer_imports.cpp
// Phase 2C: AHardwareBuffer import foundation - Vulkan backend helper.
//
// Android-only: all implementation is inside #if defined(__ANDROID__) ... #endif.
// Non-Android translation unit compiles to stubs only.
//
// AHardwareBuffer_acquire, AHardwareBuffer_release, AHardwareBuffer_describe
// are loaded via dlopen/dlsym at runtime (no strong symbol references).
//
// vkGetAndroidHardwareBufferPropertiesANDROID is loaded via vkGetDeviceProcAddr.
//
// Forbidden: JNI, AHardwareBuffer_allocate, lock/unlock, fromHardwareBuffer,
// image views, samplers, YCbCr conversion objects, semaphores, sync fd
// waiting/import, command buffers, render pass, pipeline, sampling,
// presentation.

#include "vulkan_hardware_buffer_imports.h"

#if defined(__ANDROID__)

// VK_USE_PLATFORM_ANDROID_KHR must be defined before <vulkan/vulkan.h> to
// enable the Android platform extensions declared in vulkan_android.h, which
// include VkAndroidHardwareBufferPropertiesANDROID, VkExternalFormatANDROID,
// VkImportAndroidHardwareBufferInfoANDROID, PFN_vkGetAndroidHardwareBufferPropertiesANDROID,
// and the forward declaration of struct AHardwareBuffer.
#define VK_USE_PLATFORM_ANDROID_KHR

#include <vulkan/vulkan.h>
#include <android/log.h>
#include <android/hardware_buffer.h>

#include <dlfcn.h>
#include <inttypes.h>
#include <unistd.h>

#include <cstring>
#include <unordered_map>
#include <atomic>

#define VGLOG_AHB(...) \
    __android_log_print(ANDROID_LOG_DEBUG, "VanguardAHBImport", __VA_ARGS__)

namespace vanguard {
namespace render {

// ---------------------------------------------------------------------------
// AHardwareBuffer function pointer typedefs (loaded from libandroid.so).
//
// Named with VG_ prefix to avoid any collision with NDK-provided names.
// The NDK signatures (from <android/hardware_buffer.h>):
//   void AHardwareBuffer_acquire(AHardwareBuffer*)
//   void AHardwareBuffer_release(AHardwareBuffer*)
//   void AHardwareBuffer_describe(const AHardwareBuffer*, AHardwareBuffer_Desc*)
//
// AHardwareBuffer and AHardwareBuffer_Desc are provided by the NDK header
// included above.  We cast to/from void* in our dlsym wrappers.
// ---------------------------------------------------------------------------

using VG_PFN_AcquireBuffer =
    void (*)(AHardwareBuffer*);

using VG_PFN_ReleaseBuffer =
    void (*)(AHardwareBuffer*);

using VG_PFN_DescribeBuffer =
    void (*)(const AHardwareBuffer*, AHardwareBuffer_Desc*);

// PFN_vkGetAndroidHardwareBufferPropertiesANDROID is declared in
// <vulkan/vulkan_android.h> (included transitively above).
// We use that type directly.

// ---------------------------------------------------------------------------
// Per-import record
// ---------------------------------------------------------------------------

struct ImportRecord {
    AHardwareBuffer*        ahbPtr;  // acquired ref (AHardwareBuffer*)
    VkImage                 image;
    VkDeviceMemory          memory;
    int                     acquireFenceFd; // stored fd; -1 if none/closed
};

// ---------------------------------------------------------------------------
// Impl
// ---------------------------------------------------------------------------

struct VulkanHardwareBufferImports::Impl {
    // Vulkan handles (not owned here - owned by VulkanBackend::Impl).
    VkDevice         device  = VK_NULL_HANDLE;
    VkPhysicalDevice physDev = VK_NULL_HANDLE;

    // dlopen handle for libandroid.so.
    void* libAndroid = nullptr;

    // Resolved AHardwareBuffer functions (from libandroid.so via dlsym).
    VG_PFN_AcquireBuffer  fnAcquire  = nullptr;
    VG_PFN_ReleaseBuffer  fnRelease  = nullptr;
    VG_PFN_DescribeBuffer fnDescribe = nullptr;

    // Resolved Vulkan extension function (from vkGetDeviceProcAddr).
    PFN_vkGetAndroidHardwareBufferPropertiesANDROID fnGetAHBProps = nullptr;

    // Handle table and monotonic counter.
    std::unordered_map<HardwareBufferHandle, ImportRecord> records;
    std::atomic<uint64_t> nextHandle{1};

    bool initialized = false;

    // Destroy a single record. Does NOT remove it from the records map.
    void destroyRecord(ImportRecord& rec) {
        if (rec.image != VK_NULL_HANDLE) {
            vkDestroyImage(device, rec.image, nullptr);
            rec.image = VK_NULL_HANDLE;
        }
        if (rec.memory != VK_NULL_HANDLE) {
            vkFreeMemory(device, rec.memory, nullptr);
            rec.memory = VK_NULL_HANDLE;
        }
        if (rec.ahbPtr && fnRelease) {
            fnRelease(rec.ahbPtr);
            rec.ahbPtr = nullptr;
        }
        if (rec.acquireFenceFd >= 0) {
            ::close(rec.acquireFenceFd);
            rec.acquireFenceFd = -1;
        }
    }
};

// ---------------------------------------------------------------------------
// Constructor / destructor
// ---------------------------------------------------------------------------

VulkanHardwareBufferImports::VulkanHardwareBufferImports()
    : impl_(std::make_unique<Impl>()) {}

VulkanHardwareBufferImports::~VulkanHardwareBufferImports() {
    shutdown();
}

// ---------------------------------------------------------------------------
// initialize()
// ---------------------------------------------------------------------------

bool VulkanHardwareBufferImports::initialize(void* deviceHandle,
                                              void* physDevHandle) {
    Impl& s = *impl_;
    if (s.initialized) return true;

    s.device  = static_cast<VkDevice>(deviceHandle);
    s.physDev = static_cast<VkPhysicalDevice>(physDevHandle);

    // Load libandroid.so for AHardwareBuffer functions.
    s.libAndroid = dlopen("libandroid.so", RTLD_NOW | RTLD_LOCAL);
    if (!s.libAndroid) {
        VGLOG_AHB("dlopen(libandroid.so) failed: %s", dlerror());
        return false;
    }

    s.fnAcquire = reinterpret_cast<VG_PFN_AcquireBuffer>(
        dlsym(s.libAndroid, "AHardwareBuffer_acquire"));
    s.fnRelease = reinterpret_cast<VG_PFN_ReleaseBuffer>(
        dlsym(s.libAndroid, "AHardwareBuffer_release"));
    s.fnDescribe = reinterpret_cast<VG_PFN_DescribeBuffer>(
        dlsym(s.libAndroid, "AHardwareBuffer_describe"));

    if (!s.fnAcquire || !s.fnRelease || !s.fnDescribe) {
        VGLOG_AHB("Failed to resolve AHardwareBuffer_* from libandroid.so");
        dlclose(s.libAndroid);
        s.libAndroid = nullptr;
        return false;
    }

    // Load vkGetAndroidHardwareBufferPropertiesANDROID via device proc addr.
    s.fnGetAHBProps =
        reinterpret_cast<PFN_vkGetAndroidHardwareBufferPropertiesANDROID>(
            vkGetDeviceProcAddr(s.device,
                                "vkGetAndroidHardwareBufferPropertiesANDROID"));
    if (!s.fnGetAHBProps) {
        VGLOG_AHB("vkGetDeviceProcAddr("
                  "vkGetAndroidHardwareBufferPropertiesANDROID) returned null");
        dlclose(s.libAndroid);
        s.libAndroid = nullptr;
        return false;
    }

    s.initialized = true;
    VGLOG_AHB("VulkanHardwareBufferImports initialized");
    return true;
}

// ---------------------------------------------------------------------------
// shutdown()
// ---------------------------------------------------------------------------

void VulkanHardwareBufferImports::shutdown() {
    if (!impl_) return;
    Impl& s = *impl_;

    // Destroy all import records (VkImage, VkDeviceMemory, AHB refs, fds).
    for (auto& kv : s.records) {
        s.destroyRecord(kv.second);
    }
    s.records.clear();

    if (s.libAndroid) {
        dlclose(s.libAndroid);
        s.libAndroid = nullptr;
    }

    s.fnAcquire    = nullptr;
    s.fnRelease    = nullptr;
    s.fnDescribe   = nullptr;
    s.fnGetAHBProps = nullptr;
    s.device       = VK_NULL_HANDLE;
    s.physDev      = VK_NULL_HANDLE;
    s.initialized  = false;
}

// ---------------------------------------------------------------------------
// importBuffer()
// ---------------------------------------------------------------------------

HardwareBufferImportResult VulkanHardwareBufferImports::importBuffer(
    void* hardwareBuffer,
    int acquireFenceFd,
    HardwareBufferHandle* outHandle,
    HardwareBufferDescriptor* outDescriptor)
{
    Impl& s = *impl_;

    // Helper: close fence, release any acquired GPU resources and AHB ref,
    // zero outputs, and return the given result code.
    auto fail = [&](HardwareBufferImportResult r,
                    int fenceToClose,
                    AHardwareBuffer* ahbRef,
                    VkImage img,
                    VkDeviceMemory mem) -> HardwareBufferImportResult {
        if (fenceToClose >= 0) ::close(fenceToClose);
        if (img  != VK_NULL_HANDLE) vkDestroyImage(s.device, img, nullptr);
        if (mem  != VK_NULL_HANDLE) vkFreeMemory(s.device, mem, nullptr);
        if (ahbRef && s.fnRelease)  s.fnRelease(ahbRef);
        if (outHandle)     *outHandle     = kInvalidHardwareBufferHandle;
        if (outDescriptor) *outDescriptor = HardwareBufferDescriptor{};
        return r;
    };

    // --- Argument validation ---
    if (!hardwareBuffer || !outHandle || !outDescriptor) {
        return fail(HardwareBufferImportResult::kInvalidArgument,
                    acquireFenceFd, nullptr, VK_NULL_HANDLE, VK_NULL_HANDLE);
    }

    if (!s.initialized) {
        return fail(HardwareBufferImportResult::kBackendNotInitialized,
                    acquireFenceFd, nullptr, VK_NULL_HANDLE, VK_NULL_HANDLE);
    }

    if (!s.fnAcquire || !s.fnRelease || !s.fnDescribe || !s.fnGetAHBProps) {
        return fail(HardwareBufferImportResult::kVulkanFunctionUnavailable,
                    acquireFenceFd, nullptr, VK_NULL_HANDLE, VK_NULL_HANDLE);
    }

    auto* ahbRaw = static_cast<AHardwareBuffer*>(hardwareBuffer);

    // --- Duplicate import check (same AHardwareBuffer* already active) ---
    for (const auto& kv : s.records) {
        if (kv.second.ahbPtr == ahbRaw) {
            return fail(HardwareBufferImportResult::kDuplicateImport,
                        acquireFenceFd, nullptr,
                        VK_NULL_HANDLE, VK_NULL_HANDLE);
        }
    }

    // --- Acquire AHardwareBuffer ref ---
    s.fnAcquire(ahbRaw);
    AHardwareBuffer* ahbRef = ahbRaw; // we now hold our own ref

    // --- Describe the buffer ---
    AHardwareBuffer_Desc desc{};
    s.fnDescribe(ahbRef, &desc);

    // Validate dimensions and layers.
    if (desc.width == 0 || desc.height == 0 || desc.layers == 0) {
        return fail(HardwareBufferImportResult::kInvalidArgument,
                    acquireFenceFd, ahbRef, VK_NULL_HANDLE, VK_NULL_HANDLE);
    }

    // Reject BLOB format.
    if (desc.format == AHARDWAREBUFFER_FORMAT_BLOB) {
        return fail(HardwareBufferImportResult::kInvalidArgument,
                    acquireFenceFd, ahbRef, VK_NULL_HANDLE, VK_NULL_HANDLE);
    }

    // Require GPU_SAMPLED_IMAGE usage.
    if (!(desc.usage & AHARDWAREBUFFER_USAGE_GPU_SAMPLED_IMAGE)) {
        return fail(HardwareBufferImportResult::kIncompatibleBuffer,
                    acquireFenceFd, ahbRef, VK_NULL_HANDLE, VK_NULL_HANDLE);
    }

    // --- Query Vulkan AHardwareBuffer properties ---
    VkAndroidHardwareBufferFormatPropertiesANDROID fmtProps{};
    fmtProps.sType =
        VK_STRUCTURE_TYPE_ANDROID_HARDWARE_BUFFER_FORMAT_PROPERTIES_ANDROID;
    fmtProps.pNext = nullptr;

    VkAndroidHardwareBufferPropertiesANDROID ahbProps{};
    ahbProps.sType =
        VK_STRUCTURE_TYPE_ANDROID_HARDWARE_BUFFER_PROPERTIES_ANDROID;
    ahbProps.pNext = &fmtProps;

    VkResult vr = s.fnGetAHBProps(s.device, ahbRef, &ahbProps);
    if (vr != VK_SUCCESS) {
        VGLOG_AHB("vkGetAndroidHardwareBufferPropertiesANDROID failed: %d",
                  static_cast<int>(vr));
        return fail(HardwareBufferImportResult::kVulkanFailure,
                    acquireFenceFd, ahbRef, VK_NULL_HANDLE, VK_NULL_HANDLE);
    }

    // Require SAMPLED_IMAGE format feature.
    if (!(fmtProps.formatFeatures & VK_FORMAT_FEATURE_SAMPLED_IMAGE_BIT)) {
        VGLOG_AHB("Buffer lacks SAMPLED_IMAGE feature (formatFeatures=0x%x)",
                  static_cast<uint32_t>(fmtProps.formatFeatures));
        return fail(HardwareBufferImportResult::kIncompatibleBuffer,
                    acquireFenceFd, ahbRef, VK_NULL_HANDLE, VK_NULL_HANDLE);
    }

    // --- Select memory type ---
    VkPhysicalDeviceMemoryProperties memProps{};
    vkGetPhysicalDeviceMemoryProperties(s.physDev, &memProps);

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
        return fail(HardwareBufferImportResult::kVulkanFailure,
                    acquireFenceFd, ahbRef, VK_NULL_HANDLE, VK_NULL_HANDLE);
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

    VkFormat imageFormat = fmtProps.format;
    if (imageFormat == VK_FORMAT_UNDEFINED) {
        if (fmtProps.externalFormat == 0) {
            VGLOG_AHB("format=VK_FORMAT_UNDEFINED but externalFormat=0");
            return fail(HardwareBufferImportResult::kIncompatibleBuffer,
                        acquireFenceFd, ahbRef, VK_NULL_HANDLE, VK_NULL_HANDLE);
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

    VkImage image = VK_NULL_HANDLE;
    vr = vkCreateImage(s.device, &imgCI, nullptr, &image);
    if (vr != VK_SUCCESS) {
        VGLOG_AHB("vkCreateImage failed: %d", static_cast<int>(vr));
        return fail(HardwareBufferImportResult::kVulkanFailure,
                    acquireFenceFd, ahbRef, VK_NULL_HANDLE, VK_NULL_HANDLE);
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

    VkDeviceMemory memory = VK_NULL_HANDLE;
    vr = vkAllocateMemory(s.device, &allocInfo, nullptr, &memory);
    if (vr != VK_SUCCESS) {
        VGLOG_AHB("vkAllocateMemory failed: %d", static_cast<int>(vr));
        return fail(HardwareBufferImportResult::kVulkanFailure,
                    acquireFenceFd, ahbRef, image, VK_NULL_HANDLE);
    }

    vr = vkBindImageMemory(s.device, image, memory, 0);
    if (vr != VK_SUCCESS) {
        VGLOG_AHB("vkBindImageMemory failed: %d", static_cast<int>(vr));
        return fail(HardwareBufferImportResult::kVulkanFailure,
                    acquireFenceFd, ahbRef, image, memory);
    }

    // --- Register in handle table ---
    HardwareBufferHandle handle = s.nextHandle.fetch_add(1);

    ImportRecord rec{};
    rec.ahbPtr         = ahbRef;
    rec.image          = image;
    rec.memory         = memory;
    rec.acquireFenceFd = acquireFenceFd; // ownership transferred; stored here

    s.records.emplace(handle, rec);

    // --- Populate outputs ---
    *outHandle = handle;
    outDescriptor->width  = desc.width;
    outDescriptor->height = desc.height;
    outDescriptor->layers = desc.layers;
    outDescriptor->format = desc.format;
    outDescriptor->stride = desc.stride;
    outDescriptor->usage  = desc.usage;

    VGLOG_AHB("importBuffer: handle=%" PRIu64 " ahb=%p",
              static_cast<uint64_t>(handle),
              static_cast<void*>(ahbRef));

    return HardwareBufferImportResult::kSuccess;
}

// ---------------------------------------------------------------------------
// releaseBuffer()
// ---------------------------------------------------------------------------

HardwareBufferImportResult VulkanHardwareBufferImports::releaseBuffer(
    HardwareBufferHandle handle,
    int* outReleaseFenceFd)
{
    Impl& s = *impl_;

    if (outReleaseFenceFd) {
        *outReleaseFenceFd = -1;
    }

    auto it = s.records.find(handle);
    if (it == s.records.end()) {
        return HardwareBufferImportResult::kUnknownHandle;
    }

    s.destroyRecord(it->second);
    s.records.erase(it);

    VGLOG_AHB("releaseBuffer: handle=%" PRIu64, static_cast<uint64_t>(handle));
    return HardwareBufferImportResult::kSuccess;
}

// ---------------------------------------------------------------------------
// hasBuffer()
// ---------------------------------------------------------------------------

bool VulkanHardwareBufferImports::hasBuffer(HardwareBufferHandle handle) const {
    const Impl& s = *impl_;
    return s.records.find(handle) != s.records.end();
}

} // namespace render
} // namespace vanguard

#else // !__ANDROID__

// Non-Android translation unit: provide stub definitions so the TU compiles
// cleanly on host (macOS/Linux) without any Android or Vulkan headers.
//
// Impl must be fully defined in this TU so that unique_ptr<Impl> can
// instantiate its default_delete destructor.

#if !defined(_WIN32)
#include <unistd.h>
#endif

namespace vanguard {
namespace render {

// Minimal Impl definition for host builds (no Vulkan/Android fields).
struct VulkanHardwareBufferImports::Impl {};

VulkanHardwareBufferImports::VulkanHardwareBufferImports()
    : impl_(std::make_unique<Impl>()) {}

VulkanHardwareBufferImports::~VulkanHardwareBufferImports() {}

bool VulkanHardwareBufferImports::initialize(void*, void*) {
    return false;
}

void VulkanHardwareBufferImports::shutdown() {}

HardwareBufferImportResult VulkanHardwareBufferImports::importBuffer(
    void* /*hardwareBuffer*/,
    int acquireFenceFd,
    HardwareBufferHandle* outHandle,
    HardwareBufferDescriptor* outDescriptor)
{
    // Ownership of acquireFenceFd transfers at call entry; close it if valid.
#if !defined(_WIN32)
    if (acquireFenceFd >= 0) ::close(acquireFenceFd);
#else
    (void)acquireFenceFd;
#endif
    if (outHandle)     *outHandle     = kInvalidHardwareBufferHandle;
    if (outDescriptor) *outDescriptor = HardwareBufferDescriptor{};
    return HardwareBufferImportResult::kUnavailable;
}

HardwareBufferImportResult VulkanHardwareBufferImports::releaseBuffer(
    HardwareBufferHandle /*handle*/,
    int* outReleaseFenceFd)
{
    if (outReleaseFenceFd) *outReleaseFenceFd = -1;
    return HardwareBufferImportResult::kUnavailable;
}

bool VulkanHardwareBufferImports::hasBuffer(HardwareBufferHandle /*handle*/) const {
    return false;
}

} // namespace render
} // namespace vanguard

#endif // __ANDROID__
