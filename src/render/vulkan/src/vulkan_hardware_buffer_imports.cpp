// vulkan_hardware_buffer_imports.cpp
// Phase 2E/2G/2O1: AHardwareBuffer Vulkan import management & table helper.
//
// Manages the handle map, monotonic handle allocation, AHardwareBuffer NDK
// reference acquisition/release (libandroid.so), acquire-fence semaphore import
// (Phase 2G), and delegates Vulkan resource creation/teardown to
// VulkanHardwareBufferImage.
//
// Android-only: all implementation is inside #if defined(__ANDROID__) ... #endif.
// Non-Android translation unit compiles to stubs only.
//
// AHardwareBuffer_acquire, AHardwareBuffer_release, AHardwareBuffer_describe
// are loaded via dlopen/dlsym at runtime (no strong symbol references).
//
// vkGetAndroidHardwareBufferPropertiesANDROID,
// vkCreateSamplerYcbcrConversion, vkDestroySamplerYcbcrConversion, and
// vkImportSemaphoreFdKHR are loaded via vkGetDeviceProcAddr.
//
// Forbidden (Phase 2G boundary):
//   JNI, AHardwareBuffer_allocate, lock/unlock, fromHardwareBuffer,
//   descriptor sets, immutable sampler layouts, shaders, pipelines,
//   render passes, queue submit, presentation.

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
// Phase 2E/2G: encapsulates Vulkan resources in VulkanHardwareBufferImage.
// Phase 2G: acquireFenceFd is no longer stored here; after successful import
// the fd is consumed by vkImportSemaphoreFdKHR (Vulkan owns it) and the
// resulting VkSemaphore lives in image.acquireSemaphore.
// ---------------------------------------------------------------------------

struct ImportRecord {
    AHardwareBuffer*          ahbPtr = nullptr; // acquired ref (AHardwareBuffer*)
    VulkanHardwareBufferImage image;
    // Phase 2P1: latest release-fence fd exported after vkQueueSubmit.
    // -1 means no fence is stored. Import record owns this fd.
    int latestReleaseFenceFd = -1;
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

    // Phase 2G: VK_KHR_external_semaphore_fd entry point for sync-fd import.
    PFN_vkImportSemaphoreFdKHR fnImportSemaphoreFd = nullptr;

    // Handle table and monotonic counter.
    std::unordered_map<HardwareBufferHandle, ImportRecord> records;
    std::atomic<uint64_t> nextHandle{1};

    bool initialized = false;

    // Destroy a single record.  Does NOT remove it from the records map.
    //
    // Teardown order:
    //   Phase 2P1: close latestReleaseFenceFd if valid (before GPU teardown)
    //   image.destroy() [acquireSemaphore -> sampler -> imageView ->
    //                    ycbcrConversion -> image -> memory] (Phase 2G/2D)
    //   -> AHardwareBuffer_release
    void destroyRecord(ImportRecord& rec) {
        // Phase 2P1: close any stored release-fence fd before Vulkan teardown.
        if (rec.latestReleaseFenceFd >= 0) {
            ::close(rec.latestReleaseFenceFd);
            rec.latestReleaseFenceFd = -1;
        }
        rec.image.destroy(device, fnDestroyYcbcr);
        if (rec.ahbPtr && fnRelease) {
            fnRelease(rec.ahbPtr);
            rec.ahbPtr = nullptr;
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

    // Phase 2G: resolve vkImportSemaphoreFdKHR for acquire-fence semaphore import.
    // A null pointer here means VK_KHR_external_semaphore_fd was not exposed by
    // the driver despite being in the required extension list.  initialize() still
    // succeeds (the helper is otherwise functional); importBuffer() will return
    // kVulkanFunctionUnavailable for any import that carries a valid fd.
    s.fnImportSemaphoreFd =
        reinterpret_cast<PFN_vkImportSemaphoreFdKHR>(
            vkGetDeviceProcAddr(s.device, "vkImportSemaphoreFdKHR"));
    if (!s.fnImportSemaphoreFd) {
        VGLOG_AHB("vkGetDeviceProcAddr(vkImportSemaphoreFdKHR) returned null; "
                  "acquire-fence semaphore import unavailable");
    }

    s.initialized = true;
    VGLOG_AHB("VulkanHardwareBufferImports initialized (Phase 2G)");
    return true;
}

// ---------------------------------------------------------------------------
// shutdown()
// ---------------------------------------------------------------------------

void VulkanHardwareBufferImports::shutdown() {
    if (!impl_) return;
    Impl& s = *impl_;

    // Destroy all import records (acquireSemaphore -> Vulkan resources -> AHB ref).
    for (auto& kv : s.records) {
        s.destroyRecord(kv.second);
    }
    s.records.clear();

    if (s.libAndroid) {
        dlclose(s.libAndroid);
        s.libAndroid = nullptr;
    }

    s.fnAcquire           = nullptr;
    s.fnRelease           = nullptr;
    s.fnDescribe          = nullptr;
    s.fnGetAHBProps       = nullptr;
    s.fnCreateYcbcr       = nullptr;
    s.fnDestroyYcbcr      = nullptr;
    s.fnImportSemaphoreFd = nullptr;
    s.device              = VK_NULL_HANDLE;
    s.physDev             = VK_NULL_HANDLE;
    s.initialized         = false;
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

    // Helper: release AHB ref if acquired, close fence fd if still owned by us
    // (not yet transferred to Vulkan), zero outputs, and return result.
    // acquireFenceFd is captured by reference so that successful semaphore import
    // (which sets it to -1) prevents double-close here.
    auto fail = [&](HardwareBufferImportResult r,
                    AHardwareBuffer* ahbRef) -> HardwareBufferImportResult {
        if (ahbRef && s.fnRelease)   s.fnRelease(ahbRef);
        if (acquireFenceFd >= 0)     ::close(acquireFenceFd);
        acquireFenceFd = -1;
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

    // -------------------------------------------------------------------------
    // Phase 2G: Import acquire-fence fd as a Vulkan binary semaphore.
    //
    // If acquireFenceFd == -1 there is no pending acquire wait; skip import.
    // If acquireFenceFd >= 0 and fnImportSemaphoreFd is unavailable, the fd is
    // closed and kVulkanFunctionUnavailable is returned (full failure path).
    // On VK_SUCCESS vkImportSemaphoreFdKHR takes ownership of the fd; set
    // acquireFenceFd to -1 so the fail lambda cannot double-close.
    // On Vulkan failure the semaphore is destroyed, fd is closed, and
    // kVulkanFailure is returned.
    // -------------------------------------------------------------------------
    if (acquireFenceFd >= 0) {
        if (!s.fnImportSemaphoreFd) {
            VGLOG_AHB("importBuffer: vkImportSemaphoreFdKHR unavailable; "
                      "closing fence fd=%d", acquireFenceFd);
            // Vulkan image is fully created but we cannot import the fence.
            // Destroy the image before failing.
            vkImage.destroy(s.device, s.fnDestroyYcbcr);
            return fail(HardwareBufferImportResult::kVulkanFunctionUnavailable, ahbRef);
        }

        // Create a binary semaphore to receive the imported sync-fd.
        VkSemaphoreCreateInfo semCI{};
        semCI.sType = VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO;
        semCI.pNext = nullptr;
        semCI.flags = 0;

        VkSemaphore acqSem = VK_NULL_HANDLE;
        VkResult vr = vkCreateSemaphore(s.device, &semCI, nullptr, &acqSem);
        if (vr != VK_SUCCESS) {
            VGLOG_AHB("importBuffer: vkCreateSemaphore failed: %d (fd=%d)",
                      static_cast<int>(vr), acquireFenceFd);
            vkImage.destroy(s.device, s.fnDestroyYcbcr);
            return fail(HardwareBufferImportResult::kVulkanFailure, ahbRef);
        }

        // Import the sync-fd into the semaphore.
        // VK_SEMAPHORE_IMPORT_TEMPORARY_BIT: the semaphore's permanent payload
        // is unaffected; the temporary payload is used for this one wait.
        VkImportSemaphoreFdInfoKHR importInfo{};
        importInfo.sType      = VK_STRUCTURE_TYPE_IMPORT_SEMAPHORE_FD_INFO_KHR;
        importInfo.pNext      = nullptr;
        importInfo.semaphore  = acqSem;
        importInfo.flags      = VK_SEMAPHORE_IMPORT_TEMPORARY_BIT;
        importInfo.handleType = VK_EXTERNAL_SEMAPHORE_HANDLE_TYPE_SYNC_FD_BIT;
        importInfo.fd         = acquireFenceFd;

        vr = s.fnImportSemaphoreFd(s.device, &importInfo);
        if (vr == VK_SUCCESS) {
            // Vulkan now owns the fd; prevent any further close().
            acquireFenceFd = -1;
            vkImage.acquireSemaphore = acqSem;
            // Phase 2O1: semaphore is pending until Phase 2O2 calls
            // markAcquireSemaphoreSubmitted after a successful vkQueueSubmit.
            vkImage.acquireSemaphorePending = true;
            VGLOG_AHB("importBuffer: acquire-fence fd imported as VkSemaphore");
        } else {
            VGLOG_AHB("importBuffer: vkImportSemaphoreFdKHR failed: %d (fd=%d)",
                      static_cast<int>(vr), acquireFenceFd);
            vkDestroySemaphore(s.device, acqSem, nullptr);
            // fd still owned by us; fail() will close it.
            vkImage.destroy(s.device, s.fnDestroyYcbcr);
            return fail(HardwareBufferImportResult::kVulkanFailure, ahbRef);
        }
    }
    // acquireFenceFd == -1 at this point (either it was already -1, or Vulkan owns it).

    // --- Register in handle table ---
    HardwareBufferHandle handle = s.nextHandle.fetch_add(1);

    const bool isExternal = vkImage.isExternalFormat();
    const bool hasYcbcr = vkImage.hasYcbcrConversion();
    const bool hasAcquireSem = (vkImage.getAcquireSemaphore() != VK_NULL_HANDLE);

    ImportRecord rec{};
    rec.ahbPtr = ahbRef;
    rec.image  = std::move(vkImage);

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
              " ahb=%p externalFmt=%s ycbcr=%s layers=%u acqSem=%s",
              static_cast<uint64_t>(handle),
              static_cast<void*>(ahbRef),
              isExternal ? "yes" : "no",
              hasYcbcr ? "yes" : "no",
              desc.layers,
              hasAcquireSem ? "yes" : "no");

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

    // Phase 2P1: Transfer or close the stored release-fence fd before
    // destroyRecord (which closes any leftover as a safety net).
    ImportRecord& rec = it->second;
    const int storedFd = rec.latestReleaseFenceFd;
    rec.latestReleaseFenceFd = -1; // field cleared before destroyRecord
    if (storedFd >= 0) {
        if (outReleaseFenceFd) {
            *outReleaseFenceFd = storedFd; // ownership transferred to caller
        } else {
            ::close(storedFd);
        }
    }

    s.destroyRecord(rec);
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

// ---------------------------------------------------------------------------
// Phase 2O1: Acquire-semaphore pending-state accessors - Android.
// ---------------------------------------------------------------------------

const VulkanHardwareBufferImage* VulkanHardwareBufferImports::getImage(
        HardwareBufferHandle handle) const {
    const Impl& s = *impl_;
    auto it = s.records.find(handle);
    if (it == s.records.end()) return nullptr;
    return &it->second.image;
}

uint64_t VulkanHardwareBufferImports::getPendingAcquireSemaphoreHandle(
        HardwareBufferHandle handle) const {
    const Impl& s = *impl_;
    auto it = s.records.find(handle);
    if (it == s.records.end()) return 0u;
    const VulkanHardwareBufferImage& img = it->second.image;
    if (!img.acquireSemaphorePending) return 0u;
    // acquireSemaphore is a VkSemaphore (non-dispatchable handle).
    // Use the same memcpy idiom as vkHandleToU64 to avoid truncation on 32-bit.
    uint64_t v = 0;
    // NOLINTNEXTLINE(bugprone-undefined-memory-manipulation)
    memcpy(&v, &img.acquireSemaphore, sizeof(img.acquireSemaphore));
    return v;
}

bool VulkanHardwareBufferImports::markAcquireSemaphoreSubmitted(
        HardwareBufferHandle handle) {
    Impl& s = *impl_;
    auto it = s.records.find(handle);
    if (it == s.records.end()) return false;
    VulkanHardwareBufferImage& img = it->second.image;
    if (!img.acquireSemaphorePending) return false;
    // Do NOT null out the semaphore; destroy() still owns the handle.
    img.acquireSemaphorePending = false;
    return true;
}

uint32_t VulkanHardwareBufferImports::getImageLayout(
        HardwareBufferHandle handle) const {
    const Impl& s = *impl_;
    auto it = s.records.find(handle);
    if (it == s.records.end()) return static_cast<uint32_t>(VK_IMAGE_LAYOUT_UNDEFINED);
    return static_cast<uint32_t>(it->second.image.currentLayout);
}

bool VulkanHardwareBufferImports::setImageLayout(
        HardwareBufferHandle handle, uint32_t newLayout) {
    Impl& s = *impl_;
    auto it = s.records.find(handle);
    if (it == s.records.end()) return false;
    it->second.image.currentLayout = static_cast<VkImageLayout>(newLayout);
    return true;
}

// ---------------------------------------------------------------------------
// Phase 2P1: setLatestReleaseFenceFd() - Android
// ---------------------------------------------------------------------------

bool VulkanHardwareBufferImports::setLatestReleaseFenceFd(
        HardwareBufferHandle handle, int fd) {
    Impl& s = *impl_;
    auto it = s.records.find(handle);
    if (it == s.records.end()) {
        // Invalid handle: close incoming valid FD to prevent leak.
        if (fd >= 0) ::close(fd);
        return false;
    }
    ImportRecord& rec = it->second;
    // Close prior valid stored FD before overwriting.
    if (rec.latestReleaseFenceFd >= 0) {
        ::close(rec.latestReleaseFenceFd);
    }
    rec.latestReleaseFenceFd = fd; // store including -1
    return true;
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

// ---------------------------------------------------------------------------
// Phase 2O1: Acquire-semaphore pending-state accessors - host stubs.
// ---------------------------------------------------------------------------

const VulkanHardwareBufferImage* VulkanHardwareBufferImports::getImage(
        HardwareBufferHandle /*handle*/) const {
    return nullptr;
}

uint64_t VulkanHardwareBufferImports::getPendingAcquireSemaphoreHandle(
        HardwareBufferHandle /*handle*/) const {
    return 0u;
}

bool VulkanHardwareBufferImports::markAcquireSemaphoreSubmitted(
        HardwareBufferHandle /*handle*/) {
    return false;
}

uint32_t VulkanHardwareBufferImports::getImageLayout(
        HardwareBufferHandle /*handle*/) const {
    return 0u;
}

bool VulkanHardwareBufferImports::setImageLayout(
        HardwareBufferHandle /*handle*/, uint32_t /*newLayout*/) {
    return false;
}

// Phase 2P1: Host stub — closes incoming valid fd, returns false.
bool VulkanHardwareBufferImports::setLatestReleaseFenceFd(
        HardwareBufferHandle /*handle*/, int fd) {
#if !defined(_WIN32)
    if (fd >= 0) ::close(fd);
#else
    (void)fd;
#endif
    return false;
}

} // namespace render
} // namespace vanguard

#endif // __ANDROID__
