// Unit U/V/W: GlesBackend implementation.
//
// On Android (__ANDROID__):
//   - EGL/GLES headers included here only, never in the public header.
//   - initialize() creates an offscreen EGL display + 1x1 pbuffer surface +
//     GLES context (ES3 preferred, falling back to ES2), makes it current,
//     queries GL_VENDOR/GL_RENDERER/GL_VERSION, and performs a diagnostic
//     glClear + eglSwapBuffers.
//   - Unit V: attachSurface()/detachSurface() create/destroy a window
//     EGLSurface from a borrowed ANativeWindow* and make it current, leaving
//     the offscreen pbuffer current whenever no window surface is attached.
//     resizeSurface() cannot recreate the window surface (the backend does
//     not store the native window) and always fails while attached.
//   - Unit W: diagnosticPresentWindowClear() makes the attached window
//     surface current, performs a diagnostic glClear + eglSwapBuffers, and
//     restores no other surface (the window surface remains current).
//   - Unit X: diagnosticPresentWindowShaderQuad() makes the attached window
//     surface current, compiles/links a minimal ES2 shader program, draws a
//     full-window solid-color quad with it, and swaps, cleaning up the
//     temporary shader/program/buffer objects on every path.
//   - Unit Z: renderFrame(handle) makes the attached window surface current,
//     resolves handle to its imported GL_TEXTURE_2D via
//     GlesHardwareBufferImports::textureForHandle(), draws it as a
//     full-window textured quad via the private GlesTextureFrameRenderer
//     helper, and swaps. The imported texture is never deleted or otherwise
//     mutated by this path.
//   - Unit AA: renderFrame(handle, transform) shares the same precondition
//     checks, make-current, resolve, and swap path as renderFrame(handle),
//     passing `transform` through to GlesTextureFrameRenderer so the drawn
//     quad's UVs support rotationDegrees 0/90/180/270 plus
//     mirrorHorizontal via the shared UV-mapping helper. Non-cardinal
//     rotations normalize to identity through that shared helper. No pixel
//     readback/content proof, no fence sync, no product wiring.
//     renderFrame(handle) delegates to this overload with the identity
//     VideoFrameTransform{}.
//   - Unit AR: renderFrame()/diagnosticRenderFrameForReadback() also resolve
//     handle to its imported texture target via
//     GlesHardwareBufferImports::textureTargetForHandle() and pass it to
//     GlesTextureFrameRenderer, so GL_TEXTURE_EXTERNAL_OES (YUV/
//     implementation-defined) imports draw correctly alongside GL_TEXTURE_2D
//     ones. No color-correct YUV->RGB conversion, Camera2 product wiring, or
//     multi-node DAG composition is claimed.
//   - Unit AB: diagnosticReadPixels() makes the attached window surface
//     current and reads back a rectangle of RGBA/UNSIGNED_BYTE pixels via
//     glReadPixels(). The attached-surface requirement and rectangle-
//     within-bounds check are Android-only since they depend on
//     hasSurface(); argument/dimension/capacity validation (non-null
//     outPixels, non-zero width/height, sufficient outPixelCapacityBytes)
//     happens before any Android-only code so it runs identically on both
//     platforms.
//   - Unit AC: diagnosticRenderFrameForReadback() shares the same
//     precondition checks, make-current, texture resolve, and draw path as
//     renderFrame(handle, transform), but intentionally does not call
//     eglSwapBuffers, so a physical harness can pair it with
//     diagnosticReadPixels() against the still-unswapped window surface to
//     verify rendered texture content before presentation.
//   - Unit AS: diagnosticCompositeFramesForReadback() and
//     diagnosticPresentCompositeFrames() resolve handleA/handleB to their
//     imported textures/targets via the same ahbImports lookup as
//     renderFrame(), then delegate to the private GlesTwoTextureCompositor
//     helper to draw them composited into a single full-window quad via
//     gl_FragColor = mix(colorA, colorB, weightB), each texture's UVs
//     independently mapped through transformA/transformB. The readback
//     variant omits eglSwapBuffers (pair with diagnosticReadPixels()); the
//     present variant swaps. Unit AS is a two-texture GL_TEXTURE_2D
//     composition foundation; Unit AT extends the compositor to also accept
//     GL_TEXTURE_EXTERNAL_OES independently for each source, covering all
//     four target permutations. The compositor still fails closed on any
//     other target value. No timeline DAG integration, no transitions/PiP,
//     no product UI.
//
// On non-Android host builds:
//   - No EGL/GLES headers included.
//   - initialize() preserves the prior scaffold behavior (returns true) with
//     diagnostic fields reporting unavailable/stub state.
//   - attachSurface()/resizeSurface() remain unavailable; hasSurface() is
//     always false.
//   - Unit W: diagnosticPresentWindowClear() on an initialized backend
//     always fails with lastError="window_present_unavailable_on_host".
//   - Unit X: diagnosticPresentWindowShaderQuad() on an initialized backend
//     always fails with lastError="window_shader_unavailable_on_host".
//   - Unit Z: renderFrame(handle) on an initialized backend always fails
//     with lastError="gles_render_frame_unavailable_on_host".
//   - Unit AB: diagnosticReadPixels() on an initialized backend, once
//     argument/dimension/capacity validation passes, always fails with
//     lastError="diagnostic_read_pixels_unavailable_on_host".
//   - Unit AC: diagnosticRenderFrameForReadback() on an initialized backend
//     always fails with
//     lastError="diagnostic_render_frame_readback_unavailable_on_host".
//   - Unit AS: diagnosticCompositeFramesForReadback() and
//     diagnosticPresentCompositeFrames() on an initialized backend always
//     fail with lastError="diagnostic_composite_frames_readback_unavailable_on_host"
//     / "diagnostic_present_composite_frames_unavailable_on_host"
//     respectively.

#include "vanguard/render/gles_backend.h"
#include "gles_hardware_buffer_imports.h"
#include "gles_texture_frame_renderer.h"
#include "gles_two_texture_compositor.h"

#if defined(__ANDROID__)
#include <EGL/egl.h>
#include <GLES2/gl2.h>
#endif

#include <cmath>
#include <limits>
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
    EGLSurface offscreenSurface = EGL_NO_SURFACE;
    EGLSurface windowSurface = EGL_NO_SURFACE;
#endif

    bool initialized = false;
    int  clientVersion = 0;
    bool diagnosticClearOk = false;
    bool diagnosticSwapOk = false;
    std::string vendor;
    std::string renderer;
    std::string version;
    std::string lastError;
    uint32_t surfaceWidth = 0;
    uint32_t surfaceHeight = 0;

    // Unit Y: AHardwareBuffer -> EGLImage -> GL_TEXTURE_2D import table.
    // Owned regardless of platform; the helper itself preserves the prior
    // stub behavior on non-Android host builds.
    std::unique_ptr<GlesHardwareBufferImports> ahbImports =
        std::make_unique<GlesHardwareBufferImports>();

    // Unit Z: identity textured-quad draw helper for renderFrame(). Owned
    // regardless of platform; preserves safe unavailable-stub behavior on
    // non-Android host builds.
    std::unique_ptr<GlesTextureFrameRenderer> textureFrameRenderer =
        std::make_unique<GlesTextureFrameRenderer>();

    // Unit AS: two-texture GL_TEXTURE_2D composition draw helper for
    // diagnosticCompositeFramesForReadback()/diagnosticPresentCompositeFrames().
    // Owned regardless of platform; preserves safe unavailable-stub behavior
    // on non-Android host builds.
    std::unique_ptr<GlesTwoTextureCompositor> twoTextureCompositor =
        std::make_unique<GlesTwoTextureCompositor>();
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
        EGL_SURFACE_TYPE,    EGL_PBUFFER_BIT | EGL_WINDOW_BIT,
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
    EGLSurface offscreenSurface = eglCreatePbufferSurface(impl_->display, impl_->config, pbufferAttribs);
    if (offscreenSurface == EGL_NO_SURFACE) {
        impl_->lastError = "eglCreatePbufferSurface failed";
        eglDestroyContext(impl_->display, impl_->context);
        impl_->context = EGL_NO_CONTEXT;
        impl_->config = nullptr;
        eglTerminate(impl_->display);
        impl_->display = EGL_NO_DISPLAY;
        impl_->clientVersion = 0;
        return false;
    }
    impl_->offscreenSurface = offscreenSurface;

    if (eglMakeCurrent(impl_->display, impl_->offscreenSurface, impl_->offscreenSurface, impl_->context) != EGL_TRUE) {
        impl_->lastError = "eglMakeCurrent failed";
        eglDestroySurface(impl_->display, impl_->offscreenSurface);
        impl_->offscreenSurface = EGL_NO_SURFACE;
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

    impl_->diagnosticSwapOk = (eglSwapBuffers(impl_->display, impl_->offscreenSurface) == EGL_TRUE);
    if (!impl_->diagnosticSwapOk) {
        std::string error = "diagnostic eglSwapBuffers failed";
        shutdown();
        impl_->lastError = error;
        return false;
    }

    // Unit Y: resolve AHardwareBuffer/EGL-extension import symbols now that
    // the offscreen EGL display/context is up. Failure to resolve symbols
    // does not fail backend initialize(); importHardwareBuffer() will return
    // kUnavailable instead.
    impl_->ahbImports->initialize(reinterpret_cast<void*>(impl_->display));

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

    // Unit Y: destroy all active AHardwareBuffer import records (GL texture,
    // EGLImage, AHB ref, stored acquireFenceFd) while the EGL context is
    // still current, before tearing down the EGL context/display below.
    impl_->ahbImports->shutdown();

#if defined(__ANDROID__)
    if (impl_->display != EGL_NO_DISPLAY) {
        eglMakeCurrent(impl_->display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
        if (impl_->windowSurface != EGL_NO_SURFACE) {
            eglDestroySurface(impl_->display, impl_->windowSurface);
        }
        if (impl_->offscreenSurface != EGL_NO_SURFACE) {
            eglDestroySurface(impl_->display, impl_->offscreenSurface);
        }
        if (impl_->context != EGL_NO_CONTEXT) {
            eglDestroyContext(impl_->display, impl_->context);
        }
        eglTerminate(impl_->display);
    }
    impl_->display = EGL_NO_DISPLAY;
    impl_->context = EGL_NO_CONTEXT;
    impl_->windowSurface = EGL_NO_SURFACE;
    impl_->offscreenSurface = EGL_NO_SURFACE;
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
    impl_->surfaceWidth = 0;
    impl_->surfaceHeight = 0;
}

RenderBackendType GlesBackend::type() const {
    return RenderBackendType::kGles;
}

// ---------------------------------------------------------------------------
// Unit U/V: offscreen + window-surface EGL/GLES diagnostic accessors.
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

uint32_t GlesBackend::surfaceWidth() const {
    return impl_->surfaceWidth;
}

uint32_t GlesBackend::surfaceHeight() const {
    return impl_->surfaceHeight;
}

const char* GlesBackend::activeSurfaceKind() const {
    if (hasSurface()) {
        return "window";
    }
    if (impl_->initialized) {
        return "offscreen";
    }
    return "none";
}

// ---------------------------------------------------------------------------
// Unit V: window EGLSurface attach/detach lifecycle.
//
// nativeWindow is a borrowed ANativeWindow* cast to void*; it is never
// acquired, released, retained, or stored beyond this call (see
// RenderBackend::attachSurface).
// ---------------------------------------------------------------------------

bool GlesBackend::attachSurface(void* nativeWindow, uint32_t width, uint32_t height) {
    impl_->lastError.clear();

    if (!impl_->initialized) {
        impl_->lastError = "backend_not_initialized";
        return false;
    }
    if (nativeWindow == nullptr) {
        impl_->lastError = "null_native_window";
        return false;
    }
    if (width == 0 || height == 0) {
        impl_->lastError = "invalid_surface_dimensions";
        return false;
    }
    if (hasSurface()) {
        impl_->lastError = "surface_already_attached";
        return false;
    }

#if defined(__ANDROID__)
    const EGLint windowAttribs[] = { EGL_NONE };
    EGLSurface windowSurface = eglCreateWindowSurface(
        impl_->display,
        impl_->config,
        reinterpret_cast<EGLNativeWindowType>(nativeWindow),
        windowAttribs);
    if (windowSurface == EGL_NO_SURFACE) {
        impl_->lastError = "eglCreateWindowSurface failed";
        return false;
    }

    if (eglMakeCurrent(impl_->display, windowSurface, windowSurface, impl_->context) != EGL_TRUE) {
        impl_->lastError = "eglMakeCurrent failed for window surface";
        eglDestroySurface(impl_->display, windowSurface);
        // Best-effort restore of the offscreen pbuffer as current; hasSurface()
        // remains false either way.
        eglMakeCurrent(impl_->display, impl_->offscreenSurface, impl_->offscreenSurface, impl_->context);
        return false;
    }

    impl_->windowSurface = windowSurface;
    impl_->surfaceWidth = width;
    impl_->surfaceHeight = height;
    impl_->lastError.clear();
    return true;
#else
    (void)width;
    (void)height;
    impl_->lastError = "window_surface_unavailable_on_host";
    return false;
#endif
}

bool GlesBackend::resizeSurface(uint32_t width, uint32_t height) {
    impl_->lastError.clear();

    if (!impl_->initialized) {
        impl_->lastError = "backend_not_initialized";
        return false;
    }
    if (width == 0 || height == 0) {
        impl_->lastError = "invalid_surface_dimensions";
        return false;
    }
    if (!hasSurface()) {
        impl_->lastError = "no_surface_attached";
        return false;
    }

    // The backend does not store the borrowed ANativeWindow*, so the window
    // EGLSurface cannot be recreated in place; callers must detachSurface()
    // and attachSurface() again with the new dimensions.
    impl_->lastError = "resize_requires_reattach";
    return false;
}

void GlesBackend::detachSurface() {
#if defined(__ANDROID__)
    if (impl_->windowSurface == EGL_NO_SURFACE) {
        return;
    }

    impl_->lastError.clear();

    if (impl_->display != EGL_NO_DISPLAY && impl_->offscreenSurface != EGL_NO_SURFACE) {
        if (eglMakeCurrent(impl_->display, impl_->offscreenSurface, impl_->offscreenSurface, impl_->context) != EGL_TRUE) {
            impl_->lastError = "eglMakeCurrent failed while restoring offscreen surface during detach";
        }
    }

    eglDestroySurface(impl_->display, impl_->windowSurface);
    impl_->windowSurface = EGL_NO_SURFACE;
    impl_->surfaceWidth = 0;
    impl_->surfaceHeight = 0;
#endif
}

bool GlesBackend::hasSurface() const {
#if defined(__ANDROID__)
    return impl_->windowSurface != EGL_NO_SURFACE;
#else
    return false;
#endif
}

// ---------------------------------------------------------------------------
// Unit W: window-surface clear/swap presentation diagnostic.
// ---------------------------------------------------------------------------

namespace {
bool isValidClearComponent(float value) {
    return std::isfinite(value) && value >= 0.0f && value <= 1.0f;
}
} // namespace

bool GlesBackend::diagnosticPresentWindowClear(float red, float green, float blue, float alpha) {
    impl_->lastError.clear();

    if (!impl_->initialized) {
        impl_->lastError = "backend_not_initialized";
        return false;
    }

#if defined(__ANDROID__)
    if (!hasSurface()) {
        impl_->lastError = "no_surface_attached";
        return false;
    }
    if (!isValidClearComponent(red) || !isValidClearComponent(green) ||
        !isValidClearComponent(blue) || !isValidClearComponent(alpha)) {
        impl_->lastError = "invalid_clear_color";
        return false;
    }

    if (eglMakeCurrent(impl_->display, impl_->windowSurface, impl_->windowSurface, impl_->context) != EGL_TRUE) {
        impl_->lastError = "eglMakeCurrent failed for window clear";
        return false;
    }

    glViewport(0, 0, static_cast<GLsizei>(impl_->surfaceWidth), static_cast<GLsizei>(impl_->surfaceHeight));
    glClearColor(red, green, blue, alpha);
    glClear(GL_COLOR_BUFFER_BIT);
    if (glGetError() != GL_NO_ERROR) {
        impl_->lastError = "diagnostic window glClear failed";
        return false;
    }

    if (eglSwapBuffers(impl_->display, impl_->windowSurface) != EGL_TRUE) {
        impl_->lastError = "diagnostic window eglSwapBuffers failed";
        return false;
    }

    impl_->lastError.clear();
    return true;
#else
    impl_->lastError = "window_present_unavailable_on_host";
    return false;
#endif
}

// ---------------------------------------------------------------------------
// Unit X: window-surface shader-quad draw/swap presentation diagnostic.
// ---------------------------------------------------------------------------

#if defined(__ANDROID__)
namespace {

const char* kUnitXVertexShaderSrc =
    "attribute vec2 aPosition;\n"
    "void main() {\n"
    "    gl_Position = vec4(aPosition, 0.0, 1.0);\n"
    "}\n";

const char* kUnitXFragmentShaderSrc =
    "precision mediump float;\n"
    "uniform vec4 uColor;\n"
    "void main() {\n"
    "    gl_FragColor = uColor;\n"
    "}\n";

// Compiles a shader of the given type; returns 0 on failure (deleting the
// shader object before returning).
GLuint compileUnitXShader(GLenum type, const char* source) {
    GLuint shader = glCreateShader(type);
    if (shader == 0) {
        return 0;
    }
    glShaderSource(shader, 1, &source, nullptr);
    glCompileShader(shader);
    GLint compiled = GL_FALSE;
    glGetShaderiv(shader, GL_COMPILE_STATUS, &compiled);
    if (compiled != GL_TRUE) {
        glDeleteShader(shader);
        return 0;
    }
    return shader;
}

} // namespace
#endif

bool GlesBackend::diagnosticPresentWindowShaderQuad(float red, float green, float blue, float alpha) {
    impl_->lastError.clear();

    if (!impl_->initialized) {
        impl_->lastError = "backend_not_initialized";
        return false;
    }

#if defined(__ANDROID__)
    if (!hasSurface()) {
        impl_->lastError = "no_surface_attached";
        return false;
    }
    if (!isValidClearComponent(red) || !isValidClearComponent(green) ||
        !isValidClearComponent(blue) || !isValidClearComponent(alpha)) {
        impl_->lastError = "invalid_clear_color";
        return false;
    }

    if (eglMakeCurrent(impl_->display, impl_->windowSurface, impl_->windowSurface, impl_->context) != EGL_TRUE) {
        impl_->lastError = "eglMakeCurrent failed for window shader quad";
        return false;
    }

    GLuint vertexShader = compileUnitXShader(GL_VERTEX_SHADER, kUnitXVertexShaderSrc);
    GLuint fragmentShader = 0;
    GLuint program = 0;
    GLuint vertexBuffer = 0;
    bool ok = true;

    if (vertexShader == 0) {
        ok = false;
    } else {
        fragmentShader = compileUnitXShader(GL_FRAGMENT_SHADER, kUnitXFragmentShaderSrc);
        if (fragmentShader == 0) {
            ok = false;
        }
    }
    if (!ok) {
        impl_->lastError = "diagnostic_shader_compile_failed";
    }

    if (ok) {
        program = glCreateProgram();
        if (program == 0) {
            ok = false;
            impl_->lastError = "diagnostic_program_link_failed";
        } else {
            glAttachShader(program, vertexShader);
            glAttachShader(program, fragmentShader);
            glLinkProgram(program);
            GLint linked = GL_FALSE;
            glGetProgramiv(program, GL_LINK_STATUS, &linked);
            if (linked != GL_TRUE) {
                ok = false;
                impl_->lastError = "diagnostic_program_link_failed";
            }
        }
    }

    if (ok) {
        static const GLfloat kQuadVertices[] = {
            -1.0f, -1.0f,
             1.0f, -1.0f,
            -1.0f,  1.0f,
             1.0f,  1.0f,
        };

        glGenBuffers(1, &vertexBuffer);
        if (vertexBuffer == 0) {
            ok = false;
            impl_->lastError = "diagnostic_window_shader_draw_failed";
        } else {
            glBindBuffer(GL_ARRAY_BUFFER, vertexBuffer);
            glBufferData(GL_ARRAY_BUFFER, sizeof(kQuadVertices), kQuadVertices, GL_STATIC_DRAW);
            if (glGetError() != GL_NO_ERROR) {
                ok = false;
                impl_->lastError = "diagnostic_window_shader_draw_failed";
            }
        }
    }

    if (ok) {
        glViewport(0, 0, static_cast<GLsizei>(impl_->surfaceWidth), static_cast<GLsizei>(impl_->surfaceHeight));
        glUseProgram(program);

        GLint positionLoc = glGetAttribLocation(program, "aPosition");
        GLint colorLoc = glGetUniformLocation(program, "uColor");
        if (positionLoc < 0 || colorLoc < 0) {
            ok = false;
            impl_->lastError = "diagnostic_window_shader_draw_failed";
        } else {
            glEnableVertexAttribArray(static_cast<GLuint>(positionLoc));
            glVertexAttribPointer(static_cast<GLuint>(positionLoc), 2, GL_FLOAT, GL_FALSE, 0, nullptr);
            glUniform4f(colorLoc, red, green, blue, alpha);

            glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);

            glDisableVertexAttribArray(static_cast<GLuint>(positionLoc));

            if (glGetError() != GL_NO_ERROR) {
                ok = false;
                impl_->lastError = "diagnostic_window_shader_draw_failed";
            }
        }

        glBindBuffer(GL_ARRAY_BUFFER, 0);
        glUseProgram(0);
    }

    if (ok) {
        if (eglSwapBuffers(impl_->display, impl_->windowSurface) != EGL_TRUE) {
            ok = false;
            impl_->lastError = "diagnostic_window_shader_swap_failed";
        }
    }

    if (vertexBuffer != 0) {
        glDeleteBuffers(1, &vertexBuffer);
    }
    if (program != 0) {
        glDeleteProgram(program);
    }
    if (fragmentShader != 0) {
        glDeleteShader(fragmentShader);
    }
    if (vertexShader != 0) {
        glDeleteShader(vertexShader);
    }

    if (!ok) {
        return false;
    }

    impl_->lastError.clear();
    return true;
#else
    impl_->lastError = "window_shader_unavailable_on_host";
    return false;
#endif
}

// ---------------------------------------------------------------------------
// Phase 2C / Unit Y: AHardwareBuffer import/release - delegates to
// GlesHardwareBufferImports, which preserves the prior unavailable-stub
// behavior on non-Android host builds. Unit AK: releaseHardwareBuffer()
// delegation is unchanged here; the fail-soft native release-fence attempt
// (capability/symbol/current-context guarded) lives entirely inside
// GlesHardwareBufferImports::releaseBuffer().
// ---------------------------------------------------------------------------

HardwareBufferImportResult GlesBackend::importHardwareBuffer(
    void* hardwareBuffer,
    int acquireFenceFd,
    HardwareBufferHandle* outHandle,
    HardwareBufferDescriptor* outDescriptor)
{
    HardwareBufferImportResult result = impl_->ahbImports->importBuffer(
        hardwareBuffer, acquireFenceFd, outHandle, outDescriptor);
    impl_->lastError = impl_->ahbImports->lastError();
    return result;
}

HardwareBufferImportResult GlesBackend::releaseHardwareBuffer(
    HardwareBufferHandle handle,
    int* outReleaseFenceFd)
{
    HardwareBufferImportResult result =
        impl_->ahbImports->releaseBuffer(handle, outReleaseFenceFd);
    impl_->lastError = impl_->ahbImports->lastError();
    return result;
}

bool GlesBackend::hasHardwareBuffer(HardwareBufferHandle handle) const {
    return impl_->ahbImports->hasBuffer(handle);
}

// Unit AR: diagnostic seam exposing the resolved GL texture target for an
// imported handle without leaking GL headers into the public header. On
// non-Android host builds, GlesHardwareBufferImports::textureTargetForHandle()
// stubs to 0, which this delegates through unchanged.
uint32_t GlesBackend::diagnosticTextureTargetForHardwareBuffer(HardwareBufferHandle handle) const {
    return impl_->ahbImports->textureTargetForHandle(handle);
}

// ---------------------------------------------------------------------------
// Phase 1 Unit Z: identity renderFrame - delegates to the Unit AA transform
// overload with the identity VideoFrameTransform{}.
// ---------------------------------------------------------------------------

RenderFrameResult GlesBackend::renderFrame(HardwareBufferHandle handle) {
    return renderFrame(handle, VideoFrameTransform{});
}

// ---------------------------------------------------------------------------
// Phase 4B2C / Unit AA: renderFrame with transform - draws the imported
// texture (GL_TEXTURE_2D, or GL_TEXTURE_EXTERNAL_OES per Unit AR) as a
// full-window textured quad on the attached window surface with UVs mapped
// for rotationDegrees 0/90/180/270 plus mirrorHorizontal (via the shared
// UV-mapping helper; non-cardinal rotations normalize to identity) and
// swaps. No pixel readback/content proof, no fence sync, no product wiring.
// Unit AR's GL_TEXTURE_EXTERNAL_OES support is import-foundation only: no
// color-correct YUV->RGB conversion, Camera2 product wiring, or multi-node
// DAG composition is claimed.
// ---------------------------------------------------------------------------

RenderFrameResult GlesBackend::renderFrame(HardwareBufferHandle handle,
                                           const VideoFrameTransform& transform) {
    impl_->lastError.clear();

    if (!impl_->initialized) {
        impl_->lastError = "backend_not_initialized";
        return RenderFrameResult::kBackendNotInitialized;
    }

#if defined(__ANDROID__)
    if (!hasSurface()) {
        impl_->lastError = "no_surface_attached";
        return RenderFrameResult::kNoSurface;
    }

    const uint32_t texture = impl_->ahbImports->textureForHandle(handle);
    const uint32_t textureTarget = impl_->ahbImports->textureTargetForHandle(handle);
    if (texture == 0 || textureTarget == 0) {
        impl_->lastError = "invalid_buffer_handle";
        return RenderFrameResult::kInvalidBufferHandle;
    }

    if (eglMakeCurrent(impl_->display, impl_->windowSurface, impl_->windowSurface, impl_->context) != EGL_TRUE) {
        impl_->lastError = "gles_render_frame_make_current_failed";
        return RenderFrameResult::kUnavailable;
    }

    std::string drawError;
    const bool drawOk = impl_->textureFrameRenderer->drawTexturedQuad(
        texture, textureTarget, impl_->surfaceWidth, impl_->surfaceHeight, transform, &drawError);
    if (!drawOk) {
        impl_->lastError = !drawError.empty() ? drawError : "gles_render_frame_draw_failed";
        return RenderFrameResult::kUnavailable;
    }

    if (eglSwapBuffers(impl_->display, impl_->windowSurface) != EGL_TRUE) {
        impl_->lastError = "gles_render_frame_swap_failed";
        return RenderFrameResult::kUnavailable;
    }

    impl_->lastError.clear();
    return RenderFrameResult::kSuccess;
#else
    (void)handle;
    (void)transform;
    impl_->lastError = "gles_render_frame_unavailable_on_host";
    return RenderFrameResult::kUnavailable;
#endif
}

// ---------------------------------------------------------------------------
// Unit AB: window-surface diagnostic pixel readback.
// ---------------------------------------------------------------------------

bool GlesBackend::diagnosticReadPixels(uint32_t x,
                                       uint32_t y,
                                       uint32_t width,
                                       uint32_t height,
                                       uint8_t* outPixels,
                                       uint64_t outPixelCapacityBytes) {
    impl_->lastError.clear();

    if (!impl_->initialized) {
        impl_->lastError = "backend_not_initialized";
        return false;
    }
    if (outPixels == nullptr) {
        impl_->lastError = "diagnostic_read_pixels_invalid_argument";
        return false;
    }
    if (width == 0 || height == 0) {
        impl_->lastError = "diagnostic_read_pixels_invalid_dimensions";
        return false;
    }

    const uint64_t pixelCount = static_cast<uint64_t>(width) * static_cast<uint64_t>(height);
    if (pixelCount > std::numeric_limits<uint64_t>::max() / 4) {
        impl_->lastError = "diagnostic_read_pixels_capacity_too_small";
        return false;
    }
    const uint64_t requiredBytes = pixelCount * 4;
    if (outPixelCapacityBytes < requiredBytes) {
        impl_->lastError = "diagnostic_read_pixels_capacity_too_small";
        return false;
    }

#if defined(__ANDROID__)
    if (!hasSurface()) {
        impl_->lastError = "no_surface_attached";
        return false;
    }
    if (static_cast<uint64_t>(x) + static_cast<uint64_t>(width) > static_cast<uint64_t>(impl_->surfaceWidth) ||
        static_cast<uint64_t>(y) + static_cast<uint64_t>(height) > static_cast<uint64_t>(impl_->surfaceHeight)) {
        impl_->lastError = "diagnostic_read_pixels_out_of_bounds";
        return false;
    }

    if (eglMakeCurrent(impl_->display, impl_->windowSurface, impl_->windowSurface, impl_->context) != EGL_TRUE) {
        impl_->lastError = "diagnostic_read_pixels_make_current_failed";
        return false;
    }

    glPixelStorei(GL_PACK_ALIGNMENT, 1);
    glReadPixels(static_cast<GLint>(x), static_cast<GLint>(y),
                 static_cast<GLsizei>(width), static_cast<GLsizei>(height),
                 GL_RGBA, GL_UNSIGNED_BYTE, outPixels);
    if (glGetError() != GL_NO_ERROR) {
        impl_->lastError = "diagnostic_read_pixels_failed";
        return false;
    }

    impl_->lastError.clear();
    return true;
#else
    (void)x;
    (void)y;
    (void)width;
    (void)height;
    (void)outPixels;
    (void)outPixelCapacityBytes;
    impl_->lastError = "diagnostic_read_pixels_unavailable_on_host";
    return false;
#endif
}

// ---------------------------------------------------------------------------
// Unit AC: diagnostic no-swap renderFrame seam for pixel-content readback.
// Shares the same source texture lookup and transformed textured-quad draw
// path as renderFrame(handle, transform), but intentionally omits
// eglSwapBuffers so a physical harness can call diagnosticReadPixels()
// against the still-unswapped window surface.
// ---------------------------------------------------------------------------

bool GlesBackend::diagnosticRenderFrameForReadback(HardwareBufferHandle handle,
                                                   const VideoFrameTransform& transform) {
    impl_->lastError.clear();

    if (!impl_->initialized) {
        impl_->lastError = "backend_not_initialized";
        return false;
    }

#if defined(__ANDROID__)
    if (!hasSurface()) {
        impl_->lastError = "no_surface_attached";
        return false;
    }

    const uint32_t texture = impl_->ahbImports->textureForHandle(handle);
    const uint32_t textureTarget = impl_->ahbImports->textureTargetForHandle(handle);
    if (texture == 0 || textureTarget == 0) {
        impl_->lastError = "invalid_buffer_handle";
        return false;
    }

    if (eglMakeCurrent(impl_->display, impl_->windowSurface, impl_->windowSurface, impl_->context) != EGL_TRUE) {
        impl_->lastError = "diagnostic_render_frame_readback_make_current_failed";
        return false;
    }

    std::string drawError;
    const bool drawOk = impl_->textureFrameRenderer->drawTexturedQuad(
        texture, textureTarget, impl_->surfaceWidth, impl_->surfaceHeight, transform, &drawError);
    if (!drawOk) {
        impl_->lastError = !drawError.empty() ? drawError : "diagnostic_render_frame_readback_draw_failed";
        return false;
    }

    impl_->lastError.clear();
    return true;
#else
    (void)handle;
    (void)transform;
    impl_->lastError = "diagnostic_render_frame_readback_unavailable_on_host";
    return false;
#endif
}

// ---------------------------------------------------------------------------
// Unit AS: diagnostic two-texture composition seams. Both resolve
// handleA/handleB to their imported textures/targets via the same
// ahbImports lookup as renderFrame(), then delegate to the private
// GlesTwoTextureCompositor helper, which fails closed
// ("gles_two_texture_compositor_unsupported_texture_target") on any
// unsupported target -- no timeline DAG integration, no transitions/PiP, no
// product UI.
// Unit AT: GlesTwoTextureCompositor now accepts GL_TEXTURE_EXTERNAL_OES
// independently for each of textureTargetA/textureTargetB (already forwarded
// as-is below), so mixed external/OES + GL_TEXTURE_2D composition is
// supported here too. No color-correct YUV conversion policy is added.
// ---------------------------------------------------------------------------

bool GlesBackend::diagnosticCompositeFramesForReadback(HardwareBufferHandle handleA,
                                                        HardwareBufferHandle handleB,
                                                        float weightB,
                                                        const VideoFrameTransform& transformA,
                                                        const VideoFrameTransform& transformB) {
    impl_->lastError.clear();

    if (!impl_->initialized) {
        impl_->lastError = "backend_not_initialized";
        return false;
    }

#if defined(__ANDROID__)
    if (!hasSurface()) {
        impl_->lastError = "no_surface_attached";
        return false;
    }

    const uint32_t textureA = impl_->ahbImports->textureForHandle(handleA);
    const uint32_t textureTargetA = impl_->ahbImports->textureTargetForHandle(handleA);
    const uint32_t textureB = impl_->ahbImports->textureForHandle(handleB);
    const uint32_t textureTargetB = impl_->ahbImports->textureTargetForHandle(handleB);
    if (textureA == 0 || textureTargetA == 0 || textureB == 0 || textureTargetB == 0) {
        impl_->lastError = "invalid_buffer_handle";
        return false;
    }

    if (eglMakeCurrent(impl_->display, impl_->windowSurface, impl_->windowSurface, impl_->context) != EGL_TRUE) {
        impl_->lastError = "diagnostic_composite_frames_readback_make_current_failed";
        return false;
    }

    std::string drawError;
    const bool drawOk = impl_->twoTextureCompositor->drawCompositedQuad(
        textureA, textureTargetA, textureB, textureTargetB,
        impl_->surfaceWidth, impl_->surfaceHeight, weightB,
        transformA, transformB, &drawError);
    if (!drawOk) {
        impl_->lastError = !drawError.empty() ? drawError : "diagnostic_composite_frames_readback_draw_failed";
        return false;
    }

    impl_->lastError.clear();
    return true;
#else
    (void)handleA;
    (void)handleB;
    (void)weightB;
    (void)transformA;
    (void)transformB;
    impl_->lastError = "diagnostic_composite_frames_readback_unavailable_on_host";
    return false;
#endif
}

bool GlesBackend::diagnosticPresentCompositeFrames(HardwareBufferHandle handleA,
                                                    HardwareBufferHandle handleB,
                                                    float weightB,
                                                    const VideoFrameTransform& transformA,
                                                    const VideoFrameTransform& transformB) {
    impl_->lastError.clear();

    if (!impl_->initialized) {
        impl_->lastError = "backend_not_initialized";
        return false;
    }

#if defined(__ANDROID__)
    if (!hasSurface()) {
        impl_->lastError = "no_surface_attached";
        return false;
    }

    const uint32_t textureA = impl_->ahbImports->textureForHandle(handleA);
    const uint32_t textureTargetA = impl_->ahbImports->textureTargetForHandle(handleA);
    const uint32_t textureB = impl_->ahbImports->textureForHandle(handleB);
    const uint32_t textureTargetB = impl_->ahbImports->textureTargetForHandle(handleB);
    if (textureA == 0 || textureTargetA == 0 || textureB == 0 || textureTargetB == 0) {
        impl_->lastError = "invalid_buffer_handle";
        return false;
    }

    if (eglMakeCurrent(impl_->display, impl_->windowSurface, impl_->windowSurface, impl_->context) != EGL_TRUE) {
        impl_->lastError = "diagnostic_present_composite_frames_make_current_failed";
        return false;
    }

    std::string drawError;
    const bool drawOk = impl_->twoTextureCompositor->drawCompositedQuad(
        textureA, textureTargetA, textureB, textureTargetB,
        impl_->surfaceWidth, impl_->surfaceHeight, weightB,
        transformA, transformB, &drawError);
    if (!drawOk) {
        impl_->lastError = !drawError.empty() ? drawError : "diagnostic_present_composite_frames_draw_failed";
        return false;
    }

    if (eglSwapBuffers(impl_->display, impl_->windowSurface) != EGL_TRUE) {
        impl_->lastError = "diagnostic_present_composite_frames_swap_failed";
        return false;
    }

    impl_->lastError.clear();
    return true;
#else
    (void)handleA;
    (void)handleB;
    (void)weightB;
    (void)transformA;
    (void)transformB;
    impl_->lastError = "diagnostic_present_composite_frames_unavailable_on_host";
    return false;
#endif
}

} // namespace render
} // namespace vanguard
