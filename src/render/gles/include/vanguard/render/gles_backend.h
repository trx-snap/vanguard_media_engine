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
// mirrorHorizontal via shared UV mapping, plus (Unit AB) a diagnostic
// glReadPixels() seam over the attached window surface for later physical
// pixel-content verification, plus (Unit AC) a diagnostic no-swap
// renderFrame seam (diagnosticRenderFrameForReadback()) that shares the
// renderFrame(handle, transform) draw path but intentionally omits
// eglSwapBuffers so a physical harness can pair it with
// diagnosticReadPixels() to verify rendered texture content before
// presentation, plus (Unit AE) importHardwareBuffer() synchronously waiting
// on and closing the caller-supplied acquire fence (bounded poll(),
// fail-closed on timeout/error) before import. No product pixel-readback
// API, no YUV/external texture, no release fence, no EGL native-fence GPU
// chaining, no multi-node composition, no product UI wiring. EGL/GLES/
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
    //
    // Unit AE: if acquireFenceFd >= 0, it is waited on synchronously
    // (bounded poll(), 1000ms) before the buffer is imported, then always
    // closed exactly once; never stored. Wait timeout or failure fails the
    // import closed. No release fence is produced.
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
    // proof, no YUV/external texture, no product wiring. (The acquire fence
    // for `handle` was already waited on and closed during
    // importHardwareBuffer(); see Unit AE. This call performs no fence sync
    // of its own.) Unavailable on non-Android host builds.
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

    // Unit AB: makes the already-attached window EGLSurface current and reads
    // back the requested [x, y, width, height) rectangle of RGBA/UNSIGNED_BYTE
    // pixels from it into outPixels, so a later physical harness can verify
    // actual rendered pixels after clear/shader/renderFrame operations.
    //
    // Preconditions: an initialized backend, a window surface already
    // attached (see attachSurface()/hasSurface()), a non-null outPixels,
    // non-zero width and height, the requested rectangle fully within the
    // attached surface's bounds (see surfaceWidth()/surfaceHeight()), and
    // outPixelCapacityBytes >= width * height * 4 without integer overflow.
    // Returns false (with lastError set) on any precondition failure or GLES
    // readback failure; otherwise fills outPixels and returns true.
    //
    // Non-claims: this is diagnostic/proof infrastructure only, not a product
    // API; it does not support YUV or external (OES) textures, does not
    // perform fence sync, and does not compose multiple render nodes.
    // Unavailable on non-Android host builds.
    bool diagnosticReadPixels(uint32_t x,
                              uint32_t y,
                              uint32_t width,
                              uint32_t height,
                              uint8_t* outPixels,
                              uint64_t outPixelCapacityBytes);

    // Unit AC: draws the imported GL_TEXTURE_2D identified by handle as a
    // full-window textured quad on the attached window EGLSurface using the
    // same source texture lookup and transformed textured-quad draw path as
    // renderFrame(handle, transform), but intentionally does not call
    // eglSwapBuffers, so a physical harness can call diagnosticReadPixels()
    // against the still-unswapped window surface to verify rendered texture
    // content.
    //
    // Preconditions: an initialized backend, a window surface already
    // attached (see attachSurface()/hasSurface()), and `handle` identifying
    // an active imported GL_TEXTURE_2D (see importHardwareBuffer()). Returns
    // false (with lastError set) on any precondition failure or if the draw
    // path fails; otherwise returns true with the frame drawn but not
    // presented.
    //
    // Non-claims: this is diagnostic/proof infrastructure only, not a
    // product no-swap rendering API; callers should use it only paired with
    // diagnosticReadPixels() in physical proof harnesses. It does not
    // support YUV or external (OES) textures, does not perform fence sync,
    // and does not compose multiple render nodes. Unavailable on non-
    // Android host builds.
    bool diagnosticRenderFrameForReadback(HardwareBufferHandle handle,
                                          const VideoFrameTransform& transform);

private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};

} // namespace render
} // namespace vanguard
