#pragma once
#include "vanguard/render/render_backend.h"
#include <cstdint>
#include <memory>

namespace vanguard {
namespace render {

// Phase Unit U/V/W/X/Y/Z/AA: GlesBackend owns an offscreen EGL/GLES
// lifecycle on Android, plus (Unit V) attach/detach of a window EGLSurface
// built from a borrowed ANativeWindow*, plus (Unit W) a diagnostic
// clear/swap presentation on an already-attached window surface, plus
// (Unit X) a diagnostic minimal ES2 shader-quad draw/swap on an
// already-attached window surface, plus (Unit Y) AHardwareBuffer
// import/release for RGBA_8888/RGBX_8888 GPU-sampled buffers (EGLImage +
// GL_TEXTURE_2D only), plus (Unit Z) an identity renderFrame(handle) that
// draws the imported GL_TEXTURE_2D as a full-window textured quad on the
// attached window surface and swaps, plus (Unit AA) renderFrame(handle,
// transform) support for rotationDegrees 0/90/180/270 plus
// mirrorHorizontal via shared UV mapping. No pixel readback/content proof,
// no YUV/external texture, no fence sync, no product wiring. EGL/GLES/
// Android headers must never appear in this public header; all such state
// lives exclusively in gles_backend.cpp and the private
// GlesHardwareBufferImports / GlesTextureFrameRenderer helpers behind the
// Impl pimpl.
class GlesBackend : public RenderBackend {
public:
    GlesBackend();
    ~GlesBackend() override;

    // Non-copyable, non-movable (owns EGL/GLES state).
    GlesBackend(const GlesBackend&) = delete;
    GlesBackend& operator=(const GlesBackend&) = delete;

    bool initialize() override;
    void shutdown() override;
    RenderBackendType type() const override;

    // Surface lifecycle: attach/detach a window EGLSurface built from a
    // borrowed ANativeWindow* (nativeWindow is never acquired, released, or
    // stored beyond the attachSurface() call itself; see RenderBackend).
    bool attachSurface(void* nativeWindow,
                       uint32_t width,
                       uint32_t height) override;
    bool resizeSurface(uint32_t width, uint32_t height) override;
    void detachSurface() override;
    bool hasSurface() const override;

    // Phase 2C / Unit Y: AHardwareBuffer import. On Android, supports
    // RGBA_8888/RGBX_8888 GPU-sampled buffers only (see
    // GlesHardwareBufferImports); all other formats/usages are rejected.
    // Remains unavailable on non-Android host builds.
    HardwareBufferImportResult importHardwareBuffer(
        void* hardwareBuffer,
        int acquireFenceFd,
        HardwareBufferHandle* outHandle,
        HardwareBufferDescriptor* outDescriptor) override;

    HardwareBufferImportResult releaseHardwareBuffer(
        HardwareBufferHandle handle,
        int* outReleaseFenceFd) override;

    bool hasHardwareBuffer(HardwareBufferHandle handle) const override;

    // Phase 1 Unit Z: draws the imported GL_TEXTURE_2D identified by handle
    // as a full-window textured quad on the attached window EGLSurface and
    // swaps it. Requires an initialized backend with a window surface
    // attached and a handle from a successful importHardwareBuffer(); see
    // RenderFrameResult for explicit failure states. Unavailable on
    // non-Android host builds.
    RenderFrameResult renderFrame(HardwareBufferHandle handle) override;

    // Phase 4B2C / Unit AA: draws the imported GL_TEXTURE_2D identified by
    // handle as a full-window textured quad with UVs mapped through
    // `transform` (rotationDegrees 0/90/180/270 plus mirrorHorizontal;
    // non-cardinal rotations normalize to identity) on the attached window
    // EGLSurface and swaps. Same preconditions and failure states as
    // renderFrame(handle); see RenderFrameResult. No pixel readback/content
    // proof, no YUV/external texture, no fence sync, no product wiring.
    // Unavailable on non-Android host builds.
    RenderFrameResult renderFrame(HardwareBufferHandle handle,
                                  const VideoFrameTransform& transform) override;

    // ---------------------------------------------------------------------------
    // Unit U/V: offscreen + window-surface EGL/GLES diagnostic accessors.
    // Not part of RenderBackend; consumed by the next verification harness.
    // ---------------------------------------------------------------------------

    // True once offscreen EGL init (display + context + pbuffer surface) succeeded.
    bool isInitialized() const;

    // GLES context client version actually created (3 or 2), or 0 if none.
    int clientVersion() const;

    // Result of the diagnostic glClear() performed during initialize().
    bool diagnosticClearSucceeded() const;

    // Result of the diagnostic eglSwapBuffers() performed during initialize().
    bool diagnosticSwapSucceeded() const;

    // GL_VENDOR / GL_RENDERER / GL_VERSION strings queried during initialize(),
    // or "" if unavailable.
    const char* diagnosticVendor() const;
    const char* diagnosticRenderer() const;
    const char* diagnosticVersion() const;

    // Human-readable description of the last initialize()/shutdown()/
    // attachSurface()/resizeSurface()/detachSurface() failure, or "" if none.
    const char* lastError() const;

    // Unit V: dimensions passed to the most recent successful attachSurface(),
    // or 0 if no window surface is currently attached.
    uint32_t surfaceWidth() const;
    uint32_t surfaceHeight() const;

    // Unit V: "window" while a window surface is attached, "offscreen" when
    // initialized with only the offscreen pbuffer current, or "none" when
    // not initialized.
    const char* activeSurfaceKind() const;

    // Unit W: makes the already-attached window EGLSurface current, clears it
    // to the given color, and swaps it, proving presentation on an attached
    // window surface without importing or rendering any frame. Does not
    // attach, detach, or destroy any surface. Returns false (with lastError
    // set) when not initialized, when no window surface is attached, or when
    // the color components are not finite values in [0.0, 1.0].
    bool diagnosticPresentWindowClear(float red, float green, float blue, float alpha);

    // Unit X: makes the already-attached window EGLSurface current, compiles
    // and links a minimal ES2 shader program, draws a full-window solid-color
    // quad with it, and swaps. Proves shader draw/swap on an attached window
    // surface without importing or rendering any frame. Does not attach,
    // detach, or destroy any surface. Returns false (with lastError set) when
    // not initialized, when no window surface is attached, or when the color
    // components are not finite values in [0.0, 1.0].
    bool diagnosticPresentWindowShaderQuad(float red, float green, float blue, float alpha);

private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};

} // namespace render
} // namespace vanguard
