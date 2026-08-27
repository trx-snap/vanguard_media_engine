// gles_hardware_buffer_imports.cpp
// Phase 1 Unit Y: AHardwareBuffer -> EGLImage -> GL_TEXTURE_2D import table.
// Phase 1 Unit AE: importBuffer() synchronously waits on and closes the
// caller-supplied acquire fence before importing.
//
// RGBA_8888/RGBX_8888 GPU-sampled buffers import as GL_TEXTURE_2D.
// AHardwareBuffer_acquire/release/describe are loaded via dlopen/dlsym from
// libandroid.so (no strong symbol references). eglGetNativeClientBufferANDROID,
// eglCreateImageKHR, eglDestroyImageKHR, and glEGLImageTargetTexture2DOES are
// loaded via eglGetProcAddress, since extension entry points are not
// guaranteed to be strong-linked symbols even though EGL/GLESv3 are linked.
//
// Unit AR: Y8Cb8Cr8_420/IMPLEMENTATION_DEFINED GPU-sampled buffers are also
// accepted and import as GL_TEXTURE_EXTERNAL_OES, since those formats are
// only defined for external-image sampling on Android GLES. This is import-
// foundation work only: no color-correct YUV->RGB conversion, no Camera2
// product wiring, and no multi-node DAG composition are claimed.
//
// Unit AE: if the caller passes a valid acquireFenceFd (>= 0), it is waited
// on with a bounded poll() (1000ms) before AHardwareBuffer acquire/describe/
// EGLImage creation; POLLIN within the timeout is treated as signaled, and
// timeout/error/POLLERR/POLLNVAL fail the import closed. The fd is always
// closed exactly once after the wait attempt and never stored in an
// ImportRecord.
//
// Unit AK: releaseBuffer() attempts a fail-soft native release fence when
// the caller passes a non-null outReleaseFenceFd. eglCreateSyncKHR/
// eglDestroySyncKHR/eglDupNativeFenceFDANDROID are resolved via
// eglGetProcAddress, and EGL_ANDROID_native_fence_sync capability is
// determined by token-safe matching of eglQueryString(display,
// EGL_EXTENSIONS). A release fence is only attempted when capability/
// symbols are present and an EGL context is actually current on this
// instance's display (eglMakeCurrent is never called here). Any guard or
// EGL/GL failure falls back silently to fd -1; release still proceeds and
// succeeds. No YUV/external texture, no multi-node composition, and no
// product UI wiring.
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
#include <poll.h>
#include <unistd.h>

#include <atomic>
#include <string>
#include <unordered_map>

// Unit AK: fallbacks for EGL_ANDROID_native_fence_sync tokens in case the
// NDK's EGL/eglext.h in use predates this extension block. Values mirror
// the Khronos-registered constants (also mirrored by the Unit AI/AN/AO
// smoke JNI bridges).
#ifndef EGL_SYNC_NATIVE_FENCE_ANDROID
#define EGL_SYNC_NATIVE_FENCE_ANDROID 0x3144
#endif
#ifndef EGL_SYNC_NATIVE_FENCE_FD_ANDROID
#define EGL_SYNC_NATIVE_FENCE_FD_ANDROID 0x3145
#endif
#ifndef EGL_NO_NATIVE_FENCE_FD_ANDROID
#define EGL_NO_NATIVE_FENCE_FD_ANDROID -1
#endif

// Unit AR: fallbacks in case the NDK headers in use predate these tokens.
// Values mirror the Khronos-registered / AOSP-published constants.
#ifndef GL_TEXTURE_EXTERNAL_OES
#define GL_TEXTURE_EXTERNAL_OES 0x8D65
#endif
#ifndef AHARDWAREBUFFER_FORMAT_Y8Cb8Cr8_420
#define AHARDWAREBUFFER_FORMAT_Y8Cb8Cr8_420 0x23
#endif
#ifndef AHARDWAREBUFFER_FORMAT_IMPLEMENTATION_DEFINED
#define AHARDWAREBUFFER_FORMAT_IMPLEMENTATION_DEFINED 0x22
#endif

namespace vanguard {
namespace render {

// ---------------------------------------------------------------------------
// Unit AE: bounded synchronous acquire-fence wait.
// ---------------------------------------------------------------------------

namespace {

// Bounded wait applied to a caller-supplied acquire fence fd before an
// AHardwareBuffer is acquired/described/imported into an EGLImage. Fail-
// closed: only a POLLIN-signaled fd within the timeout counts as success.
constexpr int kAcquireFenceWaitTimeoutMs = 1000;

enum class FenceWaitOutcome { kSignaled, kTimeout, kFailed };

FenceWaitOutcome waitOnAcquireFence(int fd) {
    struct pollfd pfd{};
    pfd.fd = fd;
    pfd.events = POLLIN;
    const int pollResult = ::poll(&pfd, 1, kAcquireFenceWaitTimeoutMs);
    if (pollResult == 0) {
        return FenceWaitOutcome::kTimeout;
    }
    if (pollResult < 0) {
        return FenceWaitOutcome::kFailed;
    }
    if (pfd.revents & (POLLERR | POLLNVAL)) {
        return FenceWaitOutcome::kFailed;
    }
    if (pfd.revents & POLLIN) {
        return FenceWaitOutcome::kSignaled;
    }
    return FenceWaitOutcome::kFailed;
}

} // namespace

// ---------------------------------------------------------------------------
// Unit AK: token-safe EGL extension string matching.
// ---------------------------------------------------------------------------

namespace {

// Returns true iff `token` appears in the space-delimited `extensions`
// string as a whole token (bounded by string start/end or spaces on both
// sides), never as a bare substring match.
bool hasEglExtensionToken(const std::string& extensions, const char* token) {
    if (extensions.empty() || !token || !*token) {
        return false;
    }
    const std::string needle(token);
    size_t pos = 0;
    while ((pos = extensions.find(needle, pos)) != std::string::npos) {
        const bool matchStart = (pos == 0 || extensions[pos - 1] == ' ');
        const size_t endPos = pos + needle.length();
        const bool matchEnd = (endPos == extensions.length() || extensions[endPos] == ' ');
        if (matchStart && matchEnd) {
            return true;
        }
        pos += needle.length();
    }
    return false;
}

} // namespace

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

    // Unit AK: release-fence symbols/capability. Resolved best-effort in
    // initialize(); a missing symbol or extension token simply keeps
    // releaseFenceCapable false and releaseBuffer() fails soft to fd -1.
    PFNEGLCREATESYNCKHRPROC             fnCreateSyncKHR           = nullptr;
    PFNEGLDESTROYSYNCKHRPROC            fnDestroySyncKHR          = nullptr;
    PFNEGLDUPNATIVEFENCEFDANDROIDPROC   fnDupNativeFenceFDANDROID = nullptr;
    bool releaseFenceCapable = false;

    bool symbolsResolved = false;
    std::string lastError;

    struct ImportRecord {
        AHardwareBuffer* ahbPtr = nullptr;   // acquired ref
        EGLImageKHR      image = EGL_NO_IMAGE_KHR;
        GLuint           texture = 0;
        GLenum           textureTarget = GL_TEXTURE_2D; // Unit AR: GL_TEXTURE_2D
                                               // for RGBA/RGBX, GL_TEXTURE_EXTERNAL_OES
                                               // for Y8Cb8Cr8_420/IMPLEMENTATION_DEFINED.
        int              acquireFenceFd = -1; // Unit AE: always -1 -- the
                                               // acquire fence is waited on
                                               // and closed before import
                                               // completes, never stored.
    };

    std::unordered_map<HardwareBufferHandle, ImportRecord> records;
    std::atomic<uint64_t> nextHandle{1};

    // Destroys a single record's resources. Does NOT remove it from any
    // container. Order: GL texture -> EGLImage -> AHardwareBuffer ref ->
    // stored acquireFenceFd (Unit AE: always -1 by the time a record is
    // constructed, since the acquire fence is waited on and closed inside
    // importBuffer(); this close is retained defensively).
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

    // Unit AK: attempts to create an owned release-fence fd for the buffer
    // currently being released. Returns fd >= 0 (caller-owned; this backend
    // never closes it) on success, or -1 on any capability/symbol/current-
    // context guard failure or EGL/GL failure along the way. Never sets
    // lastError -- failure here is an expected, silent fail-soft fallback;
    // releaseBuffer() still proceeds and returns kSuccess.
    int createReleaseFenceFd() {
        if (!releaseFenceCapable || !fnCreateSyncKHR || !fnDestroySyncKHR ||
            !fnDupNativeFenceFDANDROID || display == EGL_NO_DISPLAY) {
            return -1;
        }

        // Only chain a release fence off a context that is actually current
        // right now, and only off the EGLDisplay this instance was
        // initialized with; never call eglMakeCurrent here.
        if (eglGetCurrentContext() == EGL_NO_CONTEXT) {
            return -1;
        }
        if (eglGetCurrentDisplay() != display) {
            return -1;
        }

        const EGLint syncAttribs[] = {
            EGL_SYNC_NATIVE_FENCE_FD_ANDROID, EGL_NO_NATIVE_FENCE_FD_ANDROID,
            EGL_NONE
        };
        EGLSyncKHR sync = fnCreateSyncKHR(display, EGL_SYNC_NATIVE_FENCE_ANDROID, syncAttribs);
        if (sync == EGL_NO_SYNC_KHR) {
            return -1;
        }

        while (glGetError() != GL_NO_ERROR) {}
        glFlush();
        if (glGetError() != GL_NO_ERROR) {
            fnDestroySyncKHR(display, sync);
            return -1;
        }

        const EGLint dupFd = fnDupNativeFenceFDANDROID(display, sync);
        fnDestroySyncKHR(display, sync);

        if (dupFd < 0) {
            return -1;
        }
        return static_cast<int>(dupFd);
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

    // Unit AK: resolve release-fence symbols and query token-safe
    // EGL_ANDROID_native_fence_sync capability. Missing symbols/extension
    // does not fail initialize(); releaseBuffer() falls back to fd -1.
    s.fnCreateSyncKHR = reinterpret_cast<PFNEGLCREATESYNCKHRPROC>(
        eglGetProcAddress("eglCreateSyncKHR"));
    s.fnDestroySyncKHR = reinterpret_cast<PFNEGLDESTROYSYNCKHRPROC>(
        eglGetProcAddress("eglDestroySyncKHR"));
    s.fnDupNativeFenceFDANDROID = reinterpret_cast<PFNEGLDUPNATIVEFENCEFDANDROIDPROC>(
        eglGetProcAddress("eglDupNativeFenceFDANDROID"));

    std::string eglExtensions;
    if (s.display != EGL_NO_DISPLAY) {
        const char* extStr = eglQueryString(s.display, EGL_EXTENSIONS);
        if (extStr) {
            eglExtensions = extStr;
        }
    }
    s.releaseFenceCapable =
        hasEglExtensionToken(eglExtensions, "EGL_ANDROID_native_fence_sync") &&
        s.fnCreateSyncKHR && s.fnDestroySyncKHR && s.fnDupNativeFenceFDANDROID;
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
    s.fnCreateSyncKHR = nullptr;
    s.fnDestroySyncKHR = nullptr;
    s.fnDupNativeFenceFDANDROID = nullptr;
    s.releaseFenceCapable = false;
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

    // --- Unit AE: bounded synchronous wait on the acquire fence, if any,
    // before AHardwareBuffer acquire/describe/EGLImage creation. The fd is
    // closed exactly once here regardless of outcome and never stored. ---
    if (acquireFenceFd >= 0) {
        const int fenceFd = acquireFenceFd;
        acquireFenceFd = -1;
        const FenceWaitOutcome outcome = waitOnAcquireFence(fenceFd);
        ::close(fenceFd);

        if (outcome == FenceWaitOutcome::kTimeout) {
            return fail(HardwareBufferImportResult::kUnavailable,
                        "ahb_import_acquire_fence_wait_timeout", nullptr);
        }
        if (outcome != FenceWaitOutcome::kSignaled) {
            return fail(HardwareBufferImportResult::kUnavailable,
                        "ahb_import_acquire_fence_wait_failed", nullptr);
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

    // Unit Y: RGBA_8888/RGBX_8888 import as GL_TEXTURE_2D. Unit AR adds
    // Y8Cb8Cr8_420/IMPLEMENTATION_DEFINED, imported as GL_TEXTURE_EXTERNAL_OES.
    // Every other format still fails closed as before.
    const bool isTexture2DFormat =
        desc.format == AHARDWAREBUFFER_FORMAT_R8G8B8A8_UNORM ||
        desc.format == AHARDWAREBUFFER_FORMAT_R8G8B8X8_UNORM;
    const bool isExternalOesFormat =
        desc.format == AHARDWAREBUFFER_FORMAT_Y8Cb8Cr8_420 ||
        desc.format == AHARDWAREBUFFER_FORMAT_IMPLEMENTATION_DEFINED;
    if (!isTexture2DFormat && !isExternalOesFormat) {
        return fail(HardwareBufferImportResult::kIncompatibleBuffer,
                    "ahb_import_unsupported_format", ahbRef);
    }
    const GLenum textureTarget = isExternalOesFormat ? GL_TEXTURE_EXTERNAL_OES : GL_TEXTURE_2D;

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

    // --- Create and bind the selected target, attach the EGLImage ---
    // Unit AR: GL_TEXTURE_EXTERNAL_OES only supports GL_LINEAR filtering and
    // GL_CLAMP_TO_EDGE wrapping, and never mipmaps; GL_TEXTURE_2D keeps the
    // Unit Y parameters unchanged.
    GLuint texture = 0;
    glGenTextures(1, &texture);
    if (texture == 0) {
        s.fnDestroyImage(s.display, image);
        return fail(HardwareBufferImportResult::kUnavailable,
                    "ahb_import_gen_texture_failed", ahbRef);
    }

    glBindTexture(textureTarget, texture);
    glTexParameteri(textureTarget, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameteri(textureTarget, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    glTexParameteri(textureTarget, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(textureTarget, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    s.fnImageTargetTexture2D(textureTarget, static_cast<GLeglImageOES>(image));
    const bool attachOk = (glGetError() == GL_NO_ERROR);
    glBindTexture(textureTarget, 0);

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
    rec.textureTarget = textureTarget;
    // Unit AE: acquireFenceFd is already -1 here -- either the caller passed
    // no fence, or it was waited on and closed above. Never store a waited
    // fd in the record.
    rec.acquireFenceFd = acquireFenceFd;

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

    // Unit AK: attempt a release fence only when the caller wants one. Any
    // capability/symbol/current-context guard failure or EGL/GL failure
    // falls back silently to fd -1; release still proceeds and succeeds.
    if (outReleaseFenceFd) {
        const int releaseFenceFd = s.createReleaseFenceFd();
        if (releaseFenceFd >= 0) {
            *outReleaseFenceFd = releaseFenceFd;
        }
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
// textureForHandle() -- Unit Z
// ---------------------------------------------------------------------------

uint32_t GlesHardwareBufferImports::textureForHandle(HardwareBufferHandle handle) const {
    const Impl& s = *impl_;
    auto it = s.records.find(handle);
    if (it == s.records.end()) {
        return 0;
    }
    return static_cast<uint32_t>(it->second.texture);
}

// ---------------------------------------------------------------------------
// textureTargetForHandle() -- Unit AR
// ---------------------------------------------------------------------------

uint32_t GlesHardwareBufferImports::textureTargetForHandle(HardwareBufferHandle handle) const {
    const Impl& s = *impl_;
    auto it = s.records.find(handle);
    if (it == s.records.end()) {
        return 0;
    }
    return static_cast<uint32_t>(it->second.textureTarget);
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

uint32_t GlesHardwareBufferImports::textureForHandle(HardwareBufferHandle /*handle*/) const {
    return 0;
}

uint32_t GlesHardwareBufferImports::textureTargetForHandle(HardwareBufferHandle /*handle*/) const {
    return 0;
}

const char* GlesHardwareBufferImports::lastError() const {
    return impl_->lastError.c_str();
}

} // namespace render
} // namespace vanguard

#endif // __ANDROID__
