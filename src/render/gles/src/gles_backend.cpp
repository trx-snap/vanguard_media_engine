// Unit U: GlesBackend implementation.
//
// On Android (__ANDROID__):
//   - EGL/GLES headers included here only, never in the public header.
//   - initialize() creates an offscreen EGL display + 1x1 pbuffer surface +
//     GLES context (ES3 preferred, falling back to ES2), makes it current,
//     queries GL_VENDOR/GL_RENDERER/GL_VERSION, and performs a diagnostic
//     glClear + eglSwapBuffers.
//   - Window/swapchain surface support (attachSurface/resizeSurface) remains
//     unavailable; this unit only establishes the offscreen EGL lifecycle.
//
// On non-Android host builds:
//   - No EGL/GLES headers included.
//   - initialize() preserves the prior scaffold behavior (returns true) with
//     diagnostic fields reporting unavailable/stub state.

#include "vanguard/render/gles_backend.h"

#if defined(__ANDROID__)
#include <EGL/egl.h>
#include <GLES2/gl2.h>
#endif

#if !defined(_WIN32)
#include <unistd.h>   // close()
#endif

#include <string>

namespace vanguard {
namespace render {

// ---------------------------------------------------------------------------
// Impl definition
// ---------------------------------------------------------------------------

struct GlesBackend::Impl {
#if defined(__ANDROID__)
    EGLDisplay display = EGL_NO_DISPLAY;
    EGLConfig  config  = nullptr;
    EGLContext context = EGL_NO_CONTEXT;
    EGLSurface surface = EGL_NO_SURFACE;
#endif

    bool initialized = false;
    int  clientVersion = 0;
    bool diagnosticClearOk = false;
    bool diagnosticSwapOk = false;
    std::string vendor;
    std::string renderer;
    std::string version;
    std::string lastError;
};

// ---------------------------------------------------------------------------
// Constructor / destructor
// ---------------------------------------------------------------------------

GlesBackend::GlesBackend() : impl_(std::make_unique<Impl>()) {}

GlesBackend::~GlesBackend() {
    shutdown();
}

// ---------------------------------------------------------------------------
// Lifecycle
// ---------------------------------------------------------------------------

bool GlesBackend::initialize() {
#if defined(__ANDROID__)
    if (impl_->initialized) {
        return true;
    }

    impl_->lastError.clear();

    EGLDisplay display = eglGetDisplay(EGL_DEFAULT_DISPLAY);
    if (display == EGL_NO_DISPLAY) {
        impl_->lastError = "eglGetDisplay failed";
        return false;
    }

    EGLint major = 0;
    EGLint minor = 0;
    if (eglInitialize(display, &major, &minor) != EGL_TRUE) {
        impl_->lastError = "eglInitialize failed";
        return false;
    }
    impl_->display = display;

    if (eglBindAPI(EGL_OPENGL_ES_API) != EGL_TRUE) {
        impl_->lastError = "eglBindAPI failed";
        eglTerminate(impl_->display);
        impl_->display = EGL_NO_DISPLAY;
        return false;
    }

    const EGLint configAttribs[] = {
        EGL_SURFACE_TYPE,    EGL_PBUFFER_BIT,
        EGL_RENDERABLE_TYPE, EGL_OPENGL_ES2_BIT,
        EGL_RED_SIZE,   8,
        EGL_GREEN_SIZE, 8,
        EGL_BLUE_SIZE,  8,
        EGL_ALPHA_SIZE, 8,
        EGL_NONE
    };
    EGLConfig config = nullptr;
    EGLint numConfigs = 0;
    if (eglChooseConfig(impl_->display, configAttribs, &config, 1, &numConfigs) != EGL_TRUE ||
        numConfigs < 1) {
        impl_->lastError = "eglChooseConfig failed to find a pbuffer RGBA config";
        eglTerminate(impl_->display);
        impl_->display = EGL_NO_DISPLAY;
        return false;
    }
    impl_->config = config;

    const EGLint contextAttribsEs3[] = { EGL_CONTEXT_CLIENT_VERSION, 3, EGL_NONE };
    EGLContext context = eglCreateContext(impl_->display, impl_->config, EGL_NO_CONTEXT, contextAttribsEs3);
    int clientVersion = 3;
    if (context == EGL_NO_CONTEXT) {
        const EGLint contextAttribsEs2[] = { EGL_CONTEXT_CLIENT_VERSION, 2, EGL_NONE };
        context = eglCreateContext(impl_->display, impl_->config, EGL_NO_CONTEXT, contextAttribsEs2);
        clientVersion = 2;
    }
    if (context == EGL_NO_CONTEXT) {
        impl_->lastError = "eglCreateContext failed for both ES3 and ES2";
        impl_->config = nullptr;
        eglTerminate(impl_->display);
        impl_->display = EGL_NO_DISPLAY;
        return false;
    }
    impl_->context = context;
    impl_->clientVersion = clientVersion;

    const EGLint pbufferAttribs[] = { EGL_WIDTH, 1, EGL_HEIGHT, 1, EGL_NONE };
    EGLSurface surface = eglCreatePbufferSurface(impl_->display, impl_->config, pbufferAttribs);
    if (surface == EGL_NO_SURFACE) {
        impl_->lastError = "eglCreatePbufferSurface failed";
        eglDestroyContext(impl_->display, impl_->context);
        impl_->context = EGL_NO_CONTEXT;
        impl_->config = nullptr;
        eglTerminate(impl_->display);
        impl_->display = EGL_NO_DISPLAY;
        impl_->clientVersion = 0;
        return false;
    }
    impl_->surface = surface;

    if (eglMakeCurrent(impl_->display, impl_->surface, impl_->surface, impl_->context) != EGL_TRUE) {
        impl_->lastError = "eglMakeCurrent failed";
        eglDestroySurface(impl_->display, impl_->surface);
        impl_->surface = EGL_NO_SURFACE;
        eglDestroyContext(impl_->display, impl_->context);
        impl_->context = EGL_NO_CONTEXT;
        impl_->config = nullptr;
        eglTerminate(impl_->display);
        impl_->display = EGL_NO_DISPLAY;
        impl_->clientVersion = 0;
        return false;
    }

    const GLubyte* vendor   = glGetString(GL_VENDOR);
    const GLubyte* renderer = glGetString(GL_RENDERER);
    const GLubyte* version  = glGetString(GL_VERSION);
    impl_->vendor   = vendor   ? reinterpret_cast<const char*>(vendor)   : "";
    impl_->renderer = renderer ? reinterpret_cast<const char*>(renderer) : "";
    impl_->version  = version  ? reinterpret_cast<const char*>(version)  : "";

    if (impl_->vendor.empty() || impl_->renderer.empty() || impl_->version.empty()) {
        std::string error = "diagnostic GL_VENDOR/GL_RENDERER/GL_VERSION strings unavailable";
        shutdown();
        impl_->lastError = error;
        return false;
    }

    glClearColor(0.0f, 0.0f, 0.0f, 1.0f);
    glClear(GL_COLOR_BUFFER_BIT);
    impl_->diagnosticClearOk = (glGetError() == GL_NO_ERROR);
    if (!impl_->diagnosticClearOk) {
        std::string error = "diagnostic glClear failed (glGetError did not report GL_NO_ERROR)";
        shutdown();
        impl_->lastError = error;
        return false;
    }

    impl_->diagnosticSwapOk = (eglSwapBuffers(impl_->display, impl_->surface) == EGL_TRUE);
    if (!impl_->diagnosticSwapOk) {
        std::string error = "diagnostic eglSwapBuffers failed";
        shutdown();
        impl_->lastError = error;
        return false;
    }

    impl_->initialized = true;
    return true;
#else
    impl_->lastError.clear();
    impl_->initialized = true; // Scaffold preserved on non-Android host builds.
    return true;
#endif
}

void GlesBackend::shutdown() {
    if (!impl_) {
        return;
    }

#if defined(__ANDROID__)
    if (impl_->display != EGL_NO_DISPLAY) {
        eglMakeCurrent(impl_->display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
        if (impl_->surface != EGL_NO_SURFACE) {
            eglDestroySurface(impl_->display, impl_->surface);
        }
        if (impl_->context != EGL_NO_CONTEXT) {
            eglDestroyContext(impl_->display, impl_->context);
        }
        eglTerminate(impl_->display);
    }
    impl_->display = EGL_NO_DISPLAY;
    impl_->context = EGL_NO_CONTEXT;
    impl_->surface = EGL_NO_SURFACE;
    impl_->config  = nullptr;
#endif

    impl_->initialized = false;
    impl_->clientVersion = 0;
    impl_->diagnosticClearOk = false;
    impl_->diagnosticSwapOk = false;
    impl_->vendor.clear();
    impl_->renderer.clear();
    impl_->version.clear();
    impl_->lastError.clear();
}

RenderBackendType GlesBackend::type() const {
    return RenderBackendType::kGles;
}

// ---------------------------------------------------------------------------
// Unit U: offscreen EGL/GLES diagnostic accessors.
// ---------------------------------------------------------------------------

bool GlesBackend::isInitialized() const {
    return impl_->initialized;
}

int GlesBackend::clientVersion() const {
    return impl_->clientVersion;
}

bool GlesBackend::diagnosticClearSucceeded() const {
    return impl_->diagnosticClearOk;
}

bool GlesBackend::diagnosticSwapSucceeded() const {
    return impl_->diagnosticSwapOk;
}

const char* GlesBackend::diagnosticVendor() const {
    return impl_->vendor.c_str();
}

const char* GlesBackend::diagnosticRenderer() const {
    return impl_->renderer.c_str();
}

const char* GlesBackend::diagnosticVersion() const {
    return impl_->version.c_str();
}

const char* GlesBackend::lastError() const {
    return impl_->lastError.c_str();
}

// ---------------------------------------------------------------------------
// Surface lifecycle: window/swapchain presentation remains unavailable.
// Offscreen EGL init above does not imply external surface support.
// ---------------------------------------------------------------------------

bool GlesBackend::attachSurface(void*, uint32_t, uint32_t) {
    return false;
}

bool GlesBackend::resizeSurface(uint32_t, uint32_t) {
    return false;
}

void GlesBackend::detachSurface() {}

bool GlesBackend::hasSurface() const {
    return false;
}

// ---------------------------------------------------------------------------
// Phase 2C: AHardwareBuffer import stubs - GLES backend does not support this.
// ---------------------------------------------------------------------------

HardwareBufferImportResult GlesBackend::importHardwareBuffer(
    void* /*hardwareBuffer*/,
    int acquireFenceFd,
    HardwareBufferHandle* outHandle,
    HardwareBufferDescriptor* outDescriptor)
{
    // Ownership of acquireFenceFd transfers at call entry; close it if valid.
#if !defined(_WIN32)
    if (acquireFenceFd >= 0) {
        ::close(acquireFenceFd);
    }
#else
    (void)acquireFenceFd;
#endif
    if (outHandle) {
        *outHandle = kInvalidHardwareBufferHandle;
    }
    if (outDescriptor) {
        *outDescriptor = HardwareBufferDescriptor{};
    }
    return HardwareBufferImportResult::kUnavailable;
}

HardwareBufferImportResult GlesBackend::releaseHardwareBuffer(
    HardwareBufferHandle /*handle*/,
    int* outReleaseFenceFd)
{
    if (outReleaseFenceFd) {
        *outReleaseFenceFd = -1;
    }
    return HardwareBufferImportResult::kUnavailable;
}

bool GlesBackend::hasHardwareBuffer(HardwareBufferHandle /*handle*/) const {
    return false;
}

// ---------------------------------------------------------------------------
// Phase 2O1: renderFrame stub - GLES backend.
// ---------------------------------------------------------------------------

RenderFrameResult GlesBackend::renderFrame(HardwareBufferHandle /*handle*/) {
    return RenderFrameResult::kUnavailable;
}

// ---------------------------------------------------------------------------
// Phase 4B2C: renderFrame with transform stub - GLES backend.
// ---------------------------------------------------------------------------

RenderFrameResult GlesBackend::renderFrame(HardwareBufferHandle /*handle*/,
                                           const VideoFrameTransform& /*transform*/) {
    return RenderFrameResult::kUnavailable;
}

} // namespace render
} // namespace vanguard
