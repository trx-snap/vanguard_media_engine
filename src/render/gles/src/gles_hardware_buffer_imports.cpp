// gles_hardware_buffer_imports.cpp
// Phase 1 Unit Y: AHardwareBuffer -> EGLImage -> GL_TEXTURE_2D import table.
//
// RGBA_8888/RGBX_8888 GPU-sampled buffers only. AHardwareBuffer_acquire/
// release/describe are loaded via dlopen/dlsym from libandroid.so (no strong
// symbol references). eglGetNativeClientBufferANDROID, eglCreateImageKHR,
// eglDestroyImageKHR, and glEGLImageTargetTexture2DOES are loaded via
// eglGetProcAddress, since extension entry points are not guaranteed to be
// strong-linked symbols even though EGL/GLESv3 are linked.
//
// Android-only: real implementation is inside #if defined(__ANDROID__).
// Non-Android translation unit compiles to stubs only, preserving the prior
// GlesBackend stub behavior (import closes fd, zeros outputs, returns
// kUnavailable; release returns kUnavailable; has returns false).

#include "gles_hardware_buffer_imports.h"

#if defined(__ANDROID__)

#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES2/gl2.h>
#include <GLES2/gl2ext.h>
#include <android/hardware_buffer.h>

#include <dlfcn.h>
#include <unistd.h>

#include <atomic>
#include <string>
#include <unordered_map>

namespace vanguard {
namespace render {

// ---------------------------------------------------------------------------
// AHardwareBuffer function pointer typedefs (loaded from libandroid.so).
// ---------------------------------------------------------------------------

using VG_PFN_AHBAcquire  = void (*)(AHardwareBuffer*);
using VG_PFN_AHBRelease  = void (*)(AHardwareBuffer*);
using VG_PFN_AHBDescribe = void (*)(const AHardwareBuffer*, AHardwareBuffer_Desc*);

// ---------------------------------------------------------------------------
// Per-import record
// ---------------------------------------------------------------------------

struct GlesHardwareBufferImports::Impl {
    EGLDisplay display = EGL_NO_DISPLAY;

    void* libAndroid = nullptr;
    VG_PFN_AHBAcquire  fnAcquire  = nullptr;
    VG_PFN_AHBRelease  fnRelease  = nullptr;
    VG_PFN_AHBDescribe fnDescribe = nullptr;

    PFNEGLGETNATIVECLIENTBUFFERANDROIDPROC fnGetNativeClientBuffer = nullptr;
    PFNEGLCREATEIMAGEKHRPROC               fnCreateImage           = nullptr;
    PFNEGLDESTROYIMAGEKHRPROC              fnDestroyImage          = nullptr;
    PFNGLEGLIMAGETARGETTEXTURE2DOESPROC    fnImageTargetTexture2D  = nullptr;

    bool symbolsResolved = false;
    std::string lastError;

    struct ImportRecord {
        AHardwareBuffer* ahbPtr = nullptr;   // acquired ref
        EGLImageKHR      image = EGL_NO_IMAGE_KHR;
        GLuint           texture = 0;
        int              acquireFenceFd = -1; // owned, never waited on
    };

    std::unordered_map<HardwareBufferHandle, ImportRecord> records;
    std::atomic<uint64_t> nextHandle{1};

    // Destroys a single record's resources. Does NOT remove it from any
    // container. Order: GL texture -> EGLImage -> AHardwareBuffer ref ->
    // stored acquireFenceFd.
    void destroyRecord(ImportRecord& rec) {
        if (rec.texture != 0) {
            glDeleteTextures(1, &rec.texture);
            rec.texture = 0;
        }
        if (rec.image != EGL_NO_IMAGE_KHR && display != EGL_NO_DISPLAY && fnDestroyImage) {
            fnDestroyImage(display, rec.image);
            rec.image = EGL_NO_IMAGE_KHR;
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

GlesHardwareBufferImports::GlesHardwareBufferImports()
    : impl_(std::make_unique<Impl>()) {}

GlesHardwareBufferImports::~GlesHardwareBufferImports() {
    shutdown();
}

// ---------------------------------------------------------------------------
// initialize()
// ---------------------------------------------------------------------------

void GlesHardwareBufferImports::initialize(void* eglDisplayHandle) {
    Impl& s = *impl_;
    s.display = static_cast<EGLDisplay>(eglDisplayHandle);

    s.libAndroid = dlopen("libandroid.so", RTLD_NOW | RTLD_LOCAL);
    if (s.libAndroid) {
        s.fnAcquire = reinterpret_cast<VG_PFN_AHBAcquire>(
            dlsym(s.libAndroid, "AHardwareBuffer_acquire"));
        s.fnRelease = reinterpret_cast<VG_PFN_AHBRelease>(
            dlsym(s.libAndroid, "AHardwareBuffer_release"));
        s.fnDescribe = reinterpret_cast<VG_PFN_AHBDescribe>(
            dlsym(s.libAndroid, "AHardwareBuffer_describe"));
    }

    s.fnGetNativeClientBuffer = reinterpret_cast<PFNEGLGETNATIVECLIENTBUFFERANDROIDPROC>(
        eglGetProcAddress("eglGetNativeClientBufferANDROID"));
    s.fnCreateImage = reinterpret_cast<PFNEGLCREATEIMAGEKHRPROC>(
        eglGetProcAddress("eglCreateImageKHR"));
    s.fnDestroyImage = reinterpret_cast<PFNEGLDESTROYIMAGEKHRPROC>(
        eglGetProcAddress("eglDestroyImageKHR"));
    s.fnImageTargetTexture2D = reinterpret_cast<PFNGLEGLIMAGETARGETTEXTURE2DOESPROC>(
        eglGetProcAddress("glEGLImageTargetTexture2DOES"));

    s.symbolsResolved = s.fnAcquire && s.fnRelease && s.fnDescribe &&
                         s.fnGetNativeClientBuffer && s.fnCreateImage &&
                         s.fnDestroyImage && s.fnImageTargetTexture2D;
}

// ---------------------------------------------------------------------------
// shutdown()
// ---------------------------------------------------------------------------

void GlesHardwareBufferImports::shutdown() {
    if (!impl_) return;
    Impl& s = *impl_;

    for (auto& kv : s.records) {
        s.destroyRecord(kv.second);
    }
    s.records.clear();

    if (s.libAndroid) {
        dlclose(s.libAndroid);
        s.libAndroid = nullptr;
    }

    s.fnAcquire = nullptr;
    s.fnRelease = nullptr;
    s.fnDescribe = nullptr;
    s.fnGetNativeClientBuffer = nullptr;
    s.fnCreateImage = nullptr;
    s.fnDestroyImage = nullptr;
    s.fnImageTargetTexture2D = nullptr;
    s.symbolsResolved = false;
    s.display = EGL_NO_DISPLAY;
    s.lastError.clear();
}

// ---------------------------------------------------------------------------
// importBuffer()
// ---------------------------------------------------------------------------

HardwareBufferImportResult GlesHardwareBufferImports::importBuffer(
    void* hardwareBuffer,
    int acquireFenceFd,
    HardwareBufferHandle* outHandle,
    HardwareBufferDescriptor* outDescriptor)
{
    Impl& s = *impl_;
    s.lastError.clear();

    // Helper: release AHB ref if acquired, close fence fd (still owned by us
    // at every failure path in this function), zero outputs, record the
    // error message, and return the result.
    auto fail = [&](HardwareBufferImportResult r, const char* message,
                    AHardwareBuffer* ahbRef) -> HardwareBufferImportResult {
        if (ahbRef && s.fnRelease) s.fnRelease(ahbRef);
        if (acquireFenceFd >= 0) ::close(acquireFenceFd);
        acquireFenceFd = -1;
        if (outHandle)     *outHandle     = kInvalidHardwareBufferHandle;
        if (outDescriptor) *outDescriptor = HardwareBufferDescriptor{};
        s.lastError = message;
        return r;
    };

    // --- Argument validation ---
    if (!hardwareBuffer || !outHandle || !outDescriptor) {
        return fail(HardwareBufferImportResult::kInvalidArgument,
                    "ahb_import_invalid_argument", nullptr);
    }

    if (s.display == EGL_NO_DISPLAY) {
        return fail(HardwareBufferImportResult::kBackendNotInitialized,
                    "ahb_import_backend_not_initialized", nullptr);
    }

    if (!s.symbolsResolved) {
        return fail(HardwareBufferImportResult::kUnavailable,
                    "ahb_import_symbols_unavailable", nullptr);
    }

    auto* ahbRaw = static_cast<AHardwareBuffer*>(hardwareBuffer);

    // --- Duplicate import check (same AHardwareBuffer* already active) ---
    for (const auto& kv : s.records) {
        if (kv.second.ahbPtr == ahbRaw) {
            return fail(HardwareBufferImportResult::kDuplicateImport,
                        "ahb_import_duplicate", nullptr);
        }
    }

    // --- Acquire AHardwareBuffer ref ---
    s.fnAcquire(ahbRaw);
    AHardwareBuffer* ahbRef = ahbRaw;

    // --- Describe the buffer ---
    AHardwareBuffer_Desc desc{};
    s.fnDescribe(ahbRef, &desc);

    if (desc.width == 0 || desc.height == 0 || desc.layers == 0) {
        return fail(HardwareBufferImportResult::kInvalidArgument,
                    "ahb_import_invalid_dimensions", ahbRef);
    }

    // RGBA-only Unit Y: reject every format except R8G8B8A8/R8G8B8X8 UNORM.
    const bool formatOk =
        desc.format == AHARDWAREBUFFER_FORMAT_R8G8B8A8_UNORM ||
        desc.format == AHARDWAREBUFFER_FORMAT_R8G8B8X8_UNORM;
    if (!formatOk) {
        return fail(HardwareBufferImportResult::kIncompatibleBuffer,
                    "ahb_import_unsupported_format", ahbRef);
    }

    if (!(desc.usage & AHARDWAREBUFFER_USAGE_GPU_SAMPLED_IMAGE)) {
        return fail(HardwareBufferImportResult::kIncompatibleBuffer,
                    "ahb_import_missing_gpu_sampled_usage", ahbRef);
    }

    // --- Create EGLImage from the native client buffer ---
    EGLClientBuffer clientBuffer = s.fnGetNativeClientBuffer(ahbRef);
    if (!clientBuffer) {
        return fail(HardwareBufferImportResult::kUnavailable,
                    "ahb_import_get_native_client_buffer_failed", ahbRef);
    }

    const EGLint imageAttribs[] = { EGL_NONE };
    EGLImageKHR image = s.fnCreateImage(
        s.display, EGL_NO_CONTEXT, EGL_NATIVE_BUFFER_ANDROID, clientBuffer, imageAttribs);
    if (image == EGL_NO_IMAGE_KHR) {
        return fail(HardwareBufferImportResult::kUnavailable,
                    "ahb_import_create_image_failed", ahbRef);
    }

    // --- Create and bind GL_TEXTURE_2D, attach the EGLImage ---
    GLuint texture = 0;
    glGenTextures(1, &texture);
    if (texture == 0) {
        s.fnDestroyImage(s.display, image);
        return fail(HardwareBufferImportResult::kUnavailable,
                    "ahb_import_gen_texture_failed", ahbRef);
    }

    glBindTexture(GL_TEXTURE_2D, texture);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    s.fnImageTargetTexture2D(GL_TEXTURE_2D, static_cast<GLeglImageOES>(image));
    const bool attachOk = (glGetError() == GL_NO_ERROR);
    glBindTexture(GL_TEXTURE_2D, 0);

    if (!attachOk) {
        glDeleteTextures(1, &texture);
        s.fnDestroyImage(s.display, image);
        return fail(HardwareBufferImportResult::kUnavailable,
                    "ahb_import_attach_image_failed", ahbRef);
    }

    // --- Register in handle table ---
    const HardwareBufferHandle handle = s.nextHandle.fetch_add(1);

    Impl::ImportRecord rec{};
    rec.ahbPtr = ahbRef;
    rec.image = image;
    rec.texture = texture;
    rec.acquireFenceFd = acquireFenceFd; // ownership now held by the record
    acquireFenceFd = -1;

    s.records.emplace(handle, rec);

    // --- Populate outputs ---
    *outHandle = handle;
    outDescriptor->width  = desc.width;
    outDescriptor->height = desc.height;
    outDescriptor->layers = desc.layers;
    outDescriptor->format = desc.format;
    outDescriptor->stride = desc.stride;
    outDescriptor->usage  = desc.usage;

    s.lastError.clear();
    return HardwareBufferImportResult::kSuccess;
}

// ---------------------------------------------------------------------------
// releaseBuffer()
// ---------------------------------------------------------------------------

HardwareBufferImportResult GlesHardwareBufferImports::releaseBuffer(
    HardwareBufferHandle handle,
    int* outReleaseFenceFd)
{
    Impl& s = *impl_;
    s.lastError.clear();

    if (outReleaseFenceFd) {
        *outReleaseFenceFd = -1;
    }

    auto it = s.records.find(handle);
    if (it == s.records.end()) {
        s.lastError = "ahb_release_unknown_handle";
        return HardwareBufferImportResult::kUnknownHandle;
    }

    s.destroyRecord(it->second);
    s.records.erase(it);

    return HardwareBufferImportResult::kSuccess;
}

// ---------------------------------------------------------------------------
// hasBuffer()
// ---------------------------------------------------------------------------

bool GlesHardwareBufferImports::hasBuffer(HardwareBufferHandle handle) const {
    const Impl& s = *impl_;
    return s.records.find(handle) != s.records.end();
}

// ---------------------------------------------------------------------------
// lastError()
// ---------------------------------------------------------------------------

const char* GlesHardwareBufferImports::lastError() const {
    return impl_->lastError.c_str();
}

} // namespace render
} // namespace vanguard

#else // !__ANDROID__

// Non-Android translation unit: stub definitions only, preserving the prior
// GlesBackend stub behavior. No Android, EGL, or GLES headers.

#if !defined(_WIN32)
#include <unistd.h>
#endif

#include <string>

namespace vanguard {
namespace render {

struct GlesHardwareBufferImports::Impl {
    std::string lastError;
};

GlesHardwareBufferImports::GlesHardwareBufferImports()
    : impl_(std::make_unique<Impl>()) {}

GlesHardwareBufferImports::~GlesHardwareBufferImports() {}

void GlesHardwareBufferImports::initialize(void* /*eglDisplayHandle*/) {}

void GlesHardwareBufferImports::shutdown() {}

HardwareBufferImportResult GlesHardwareBufferImports::importBuffer(
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

HardwareBufferImportResult GlesHardwareBufferImports::releaseBuffer(
    HardwareBufferHandle /*handle*/,
    int* outReleaseFenceFd)
{
    if (outReleaseFenceFd) *outReleaseFenceFd = -1;
    return HardwareBufferImportResult::kUnavailable;
}

bool GlesHardwareBufferImports::hasBuffer(HardwareBufferHandle /*handle*/) const {
    return false;
}

const char* GlesHardwareBufferImports::lastError() const {
    return impl_->lastError.c_str();
}

} // namespace render
} // namespace vanguard

#endif // __ANDROID__
