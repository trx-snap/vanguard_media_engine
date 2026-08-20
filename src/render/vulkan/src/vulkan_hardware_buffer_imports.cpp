// vulkan_hardware_buffer_imports.cpp
// Phase 2E: AHardwareBuffer Vulkan import management & table helper.
//
// Manages the handle map, monotonic handle allocation, AHardwareBuffer NDK
// reference acquisition/release (libandroid.so), acquire fence fd ownership,
// and delegates Vulkan resource creation/teardown to VulkanHardwareBufferImage.
//
// Android-only: all implementation is inside #if defined(__ANDROID__) ... #endif.
// Non-Android translation unit compiles to stubs only.
//
// AHardwareBuffer_acquire, AHardwareBuffer_release, AHardwareBuffer_describe
// are loaded via dlopen/dlsym at runtime (no strong symbol references).
//
// vkGetAndroidHardwareBufferPropertiesANDROID,
// vkCreateSamplerYcbcrConversion, and vkDestroySamplerYcbcrConversion
// are loaded via vkGetDeviceProcAddr.
//
// Forbidden (Phase 2E boundary):
//   JNI, AHardwareBuffer_allocate, lock/unlock, fromHardwareBuffer,
//   descriptor sets, immutable sampler layouts, shaders, pipelines,
//   command buffers, render passes, queue submit, presentation,
//   semaphore import/wait, sync-fd GPU wait.

#include "vulkan_hardware_buffer_imports.h"
#include "vulkan_hardware_buffer_image.h"

#if defined(__ANDROID__)

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
#include <utility>

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
// ---------------------------------------------------------------------------

using VG_PFN_AcquireBuffer =
    void (*)(AHardwareBuffer*);

using VG_PFN_ReleaseBuffer =
    void (*)(AHardwareBuffer*);

using VG_PFN_DescribeBuffer =
    void (*)(const AHardwareBuffer*, AHardwareBuffer_Desc*);

// ---------------------------------------------------------------------------
// Per-import record
// Phase 2E: encapsulates Vulkan resources in VulkanHardwareBufferImage.
// ---------------------------------------------------------------------------

struct ImportRecord {
    AHardwareBuffer*          ahbPtr         = nullptr; // acquired ref (AHardwareBuffer*)
    int                       acquireFenceFd = -1;      // stored fd; -1 if none/closed
    VulkanHardwareBufferImage image;
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

    // Resolved Vulkan extension functions (from vkGetDeviceProcAddr).
    PFN_vkGetAndroidHardwareBufferPropertiesANDROID fnGetAHBProps = nullptr;

    // Phase 2D/2E: Vulkan 1.1 sampler YCbCr conversion entry points.
    PFN_vkCreateSamplerYcbcrConversion  fnCreateYcbcr  = nullptr;
    PFN_vkDestroySamplerYcbcrConversion fnDestroyYcbcr = nullptr;

    // Handle table and monotonic counter.
    std::unordered_map<HardwareBufferHandle, ImportRecord> records;
    std::atomic<uint64_t> nextHandle{1};

    bool initialized = false;

    // Destroy a single record in Phase 2D teardown order.
    // Does NOT remove it from the records map.
    //
    // Required order:
    //   Vulkan resources (sampler -> imageView -> ycbcrConversion -> image -> memory)
    //   -> AHardwareBuffer_release
    //   -> close(acquireFenceFd)
    void destroyRecord(ImportRecord& rec) {
        rec.image.destroy(device, fnDestroyYcbcr);
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

    // Phase 2D/2E: resolve Vulkan 1.1 sampler YCbCr conversion entry points.
    s.fnCreateYcbcr =
        reinterpret_cast<PFN_vkCreateSamplerYcbcrConversion>(
            vkGetDeviceProcAddr(s.device, "vkCreateSamplerYcbcrConversion"));
    if (!s.fnCreateYcbcr) {
        VGLOG_AHB("vkGetDeviceProcAddr(vkCreateSamplerYcbcrConversion) returned null");
        dlclose(s.libAndroid);
        s.libAndroid = nullptr;
        return false;
    }

    s.fnDestroyYcbcr =
        reinterpret_cast<PFN_vkDestroySamplerYcbcrConversion>(
            vkGetDeviceProcAddr(s.device, "vkDestroySamplerYcbcrConversion"));
    if (!s.fnDestroyYcbcr) {
        VGLOG_AHB("vkGetDeviceProcAddr(vkDestroySamplerYcbcrConversion) returned null");
        dlclose(s.libAndroid);
        s.libAndroid = nullptr;
        return false;
    }

    s.initialized = true;
    VGLOG_AHB("VulkanHardwareBufferImports initialized (Phase 2E)");
    return true;
}

// ---------------------------------------------------------------------------
// shutdown()
// ---------------------------------------------------------------------------

void VulkanHardwareBufferImports::shutdown() {
    if (!impl_) return;
    Impl& s = *impl_;

    // Destroy all import records in Phase 2D teardown order.
    for (auto& kv : s.records) {
        s.destroyRecord(kv.second);
    }
    s.records.clear();

    if (s.libAndroid) {
        dlclose(s.libAndroid);
        s.libAndroid = nullptr;
    }

    s.fnAcquire      = nullptr;
    s.fnRelease      = nullptr;
    s.fnDescribe     = nullptr;
    s.fnGetAHBProps  = nullptr;
    s.fnCreateYcbcr  = nullptr;
    s.fnDestroyYcbcr = nullptr;
    s.device         = VK_NULL_HANDLE;
    s.physDev        = VK_NULL_HANDLE;
    s.initialized    = false;
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

    // Helper: release AHB ref if acquired, close fence, zero outputs, and return result.
    auto fail = [&](HardwareBufferImportResult r,
                    AHardwareBuffer* ahbRef) -> HardwareBufferImportResult {
        if (ahbRef && s.fnRelease)   s.fnRelease(ahbRef);
        if (acquireFenceFd >= 0)     ::close(acquireFenceFd);
        if (outHandle)     *outHandle     = kInvalidHardwareBufferHandle;
        if (outDescriptor) *outDescriptor = HardwareBufferDescriptor{};
        return r;
    };

    // --- Argument validation ---
    if (!hardwareBuffer || !outHandle || !outDescriptor) {
        return fail(HardwareBufferImportResult::kInvalidArgument, nullptr);
    }

    if (!s.initialized) {
        return fail(HardwareBufferImportResult::kBackendNotInitialized, nullptr);
    }

    if (!s.fnAcquire || !s.fnRelease || !s.fnDescribe || !s.fnGetAHBProps ||
        !s.fnCreateYcbcr || !s.fnDestroyYcbcr) {
        return fail(HardwareBufferImportResult::kVulkanFunctionUnavailable, nullptr);
    }

    auto* ahbRaw = static_cast<AHardwareBuffer*>(hardwareBuffer);

    // --- Duplicate import check (same AHardwareBuffer* already active) ---
    for (const auto& kv : s.records) {
        if (kv.second.ahbPtr == ahbRaw) {
            return fail(HardwareBufferImportResult::kDuplicateImport, nullptr);
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
        return fail(HardwareBufferImportResult::kInvalidArgument, ahbRef);
    }

    // Reject BLOB format.
    if (desc.format == AHARDWAREBUFFER_FORMAT_BLOB) {
        return fail(HardwareBufferImportResult::kInvalidArgument, ahbRef);
    }

    // Require GPU_SAMPLED_IMAGE usage.
    if (!(desc.usage & AHARDWAREBUFFER_USAGE_GPU_SAMPLED_IMAGE)) {
        return fail(HardwareBufferImportResult::kIncompatibleBuffer, ahbRef);
    }

    // --- Create Vulkan image and sampling resources via modular component ---
    VulkanHardwareBufferImage vkImage;
    HardwareBufferImportResult imgResult = vkImage.create(
        s.device,
        s.physDev,
        ahbRef,
        desc,
        s.fnGetAHBProps,
        s.fnCreateYcbcr,
        s.fnDestroyYcbcr);

    if (imgResult != HardwareBufferImportResult::kSuccess) {
        return fail(imgResult, ahbRef);
    }

    // --- Register in handle table ---
    HardwareBufferHandle handle = s.nextHandle.fetch_add(1);

    const bool isExternal = vkImage.isExternalFormat();
    const bool hasYcbcr = vkImage.hasYcbcrConversion();

    ImportRecord rec{};
    rec.ahbPtr         = ahbRef;
    rec.acquireFenceFd = acquireFenceFd; // ownership transferred; stored here
    rec.image          = std::move(vkImage);

    s.records.emplace(handle, std::move(rec));

    // --- Populate outputs ---
    *outHandle = handle;
    outDescriptor->width  = desc.width;
    outDescriptor->height = desc.height;
    outDescriptor->layers = desc.layers;
    outDescriptor->format = desc.format;
    outDescriptor->stride = desc.stride;
    outDescriptor->usage  = desc.usage;

    VGLOG_AHB("importBuffer: handle=%" PRIu64
              " ahb=%p externalFmt=%s ycbcr=%s layers=%u",
              static_cast<uint64_t>(handle),
              static_cast<void*>(ahbRef),
              isExternal ? "yes" : "no",
              hasYcbcr ? "yes" : "no",
              desc.layers);

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
