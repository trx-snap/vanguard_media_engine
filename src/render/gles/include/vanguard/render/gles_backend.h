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
// fail-closed on timeout/error) before import, plus (Unit AK)
// releaseHardwareBuffer() attempting a fail-soft native release fence on
// Android when the caller passes a non-null outReleaseFenceFd (see the
// releaseHardwareBuffer() declaration below for exact conditions and
// fallback behavior), plus (Unit AR) importHardwareBuffer() also accepting
// Y8Cb8Cr8_420/IMPLEMENTATION_DEFINED GPU-sampled buffers, imported as
// GL_TEXTURE_EXTERNAL_OES (RGBA_8888/RGBX_8888 remain GL_TEXTURE_2D as
// above), with renderFrame()/diagnosticRenderFrameForReadback() resolving
// and drawing whichever texture target the handle was imported as. No
// color-correct YUV->RGB conversion, no Camera2 product wiring, no
// multi-node DAG composition. No product pixel-readback API, no product UI
// wiring, plus (Unit AS) diagnosticCompositeFramesForReadback() and
// diagnosticPresentCompositeFrames(), which draw two imported texture
// handles composited into a single full-window quad via
// mix(colorA, colorB, weightB) using the private GlesTwoTextureCompositor
// helper. Unit AS is a two-texture GL_TEXTURE_2D composition foundation;
// Unit AT extends the compositor to independently accept
// GL_TEXTURE_EXTERNAL_OES for either handle, covering all four target
// permutations, while any other/mismatched-unsupported target still fails
// closed. No timeline DAG integration, no transitions/PiP, no product UI.
// EGL/GLES/
// Android headers must never appear in this public header; all such state
// lives exclusively in gles_backend.cpp and the private
// GlesHardwareBufferImports / GlesTextureFrameRenderer / GlesTwoTextureCompositor
// helpers behind the Impl pimpl.
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
    // RGBA_8888/RGBX_8888 GPU-sampled buffers, imported as GL_TEXTURE_2D,
    // plus (Unit AR) Y8Cb8Cr8_420/IMPLEMENTATION_DEFINED GPU-sampled
    // buffers, imported as GL_TEXTURE_EXTERNAL_OES (see
    // GlesHardwareBufferImports); all other formats/usages are rejected. No
    // color-correct YUV->RGB conversion is performed. Remains unavailable on
    // non-Android host builds.
    //
    // Unit AE: if acquireFenceFd >= 0, it is waited on synchronously
    // (bounded poll(), 1000ms) before the buffer is imported, then always
    // closed exactly once; never stored. Wait timeout or failure fails the
    // import closed. This call does not itself produce a release fence; see
    // releaseHardwareBuffer below for release-fence behavior.
    HardwareBufferImportResult importHardwareBuffer(
        void* hardwareBuffer,
        int acquireFenceFd,
        HardwareBufferHandle* outHandle,
        HardwareBufferDescriptor* outDescriptor) override;

    // Unit AK: outReleaseFenceFd is set to -1 at entry. If nullptr, no fence
    // is ever created. If non-null, on Android this may return an owned
    // sync fd (fd >= 0, caller must close it; this backend never closes it)
    // when EGL_ANDROID_native_fence_sync capability, resolved sync symbols,
    // and an actually-current EGL context on this backend's display are all
    // present at call time; otherwise it fails soft, leaving the output at
    // -1 without failing the call. Unavailable on non-Android host builds
    // (output stays -1).
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
    // diagnosticReadPixels() in physical proof harnesses. It resolves and
    // draws whichever texture target `handle` was imported as (GL_TEXTURE_2D
    // or, per Unit AR, GL_TEXTURE_EXTERNAL_OES), but performs no color-
    // correct YUV->RGB conversion, no fence sync, and no composition of
    // multiple render nodes. Unavailable on non-Android host builds.
    bool diagnosticRenderFrameForReadback(HardwareBufferHandle handle,
                                          const VideoFrameTransform& transform);

    // Unit AR: returns the raw GL texture target (0x0DE1 GL_TEXTURE_2D or
    // 0x8D65 GL_TEXTURE_EXTERNAL_OES) that `handle` was imported as, or 0 if
    // `handle` does not identify an active imported buffer, on non-Android
    // host builds, or if otherwise unavailable. Diagnostic/proof-only seam
    // for physical harnesses to assert the resolved texture target without
    // including private helper headers; performs no ownership transfer and
    // exposes no GL headers in this public header.
    uint32_t diagnosticTextureTargetForHardwareBuffer(HardwareBufferHandle handle) const;

    // Unit AS: resolves handleA/handleB to their imported textures/targets
    // via the same ahbImports lookup as renderFrame(), draws them composited
    // into a single full-window quad on the attached window EGLSurface via
    // the private GlesTwoTextureCompositor helper
    // (gl_FragColor = mix(colorA, colorB, weightB), each texture's UVs
    // independently mapped through transformA/transformB), but intentionally
    // does not call eglSwapBuffers, so a physical harness can pair it with
    // diagnosticReadPixels() against the still-unswapped window surface to
    // verify composited pixel content before presentation.
    //
    // Preconditions: an initialized backend, a window surface already
    // attached (see attachSurface()/hasSurface()), and handleA/handleB each
    // identifying an active imported buffer (see importHardwareBuffer()).
    // Returns false with lastError="invalid_buffer_handle" if either handle
    // does not resolve to an active imported texture/target. Unit AS scope
    // supported only GL_TEXTURE_2D + GL_TEXTURE_2D; Unit AT extends the
    // compositor to independently accept GL_TEXTURE_EXTERNAL_OES for either
    // resolved target as well, covering all four target permutations (2D+2D,
    // OES+2D, 2D+OES, OES+OES). If either resolved target is neither
    // GL_TEXTURE_2D nor GL_TEXTURE_EXTERNAL_OES, this still fails with the
    // compositor's "gles_two_texture_compositor_unsupported_texture_target"
    // error and performs no GL draw. weightB is clamped into [0.0, 1.0] if
    // finite; non-finite weightB fails with the compositor's invalid-weight
    // error.
    //
    // Non-claims: this is diagnostic/proof infrastructure only, not a
    // product compositing API; callers should use it only paired with
    // diagnosticReadPixels() in physical proof harnesses. No color-correct
    // YUV conversion policy, no timeline DAG integration, no
    // transitions/PiP, no product UI. Unavailable on non-Android host
    // builds.
    bool diagnosticCompositeFramesForReadback(HardwareBufferHandle handleA,
                                              HardwareBufferHandle handleB,
                                              float weightB,
                                              const VideoFrameTransform& transformA,
                                              const VideoFrameTransform& transformB);

    // Unit AS: shares the same preconditions, handle resolution, and
    // composited draw path as diagnosticCompositeFramesForReadback(), but
    // additionally calls eglSwapBuffers to present the composited frame on
    // the attached window EGLSurface. Same failure states and non-claims as
    // diagnosticCompositeFramesForReadback(); see its comment above.
    // Unavailable on non-Android host builds.
    bool diagnosticPresentCompositeFrames(HardwareBufferHandle handleA,
                                          HardwareBufferHandle handleB,
                                          float weightB,
                                          const VideoFrameTransform& transformA,
                                          const VideoFrameTransform& transformB);

private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};

} // namespace render
} // namespace vanguard
