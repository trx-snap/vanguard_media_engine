// gles_hardware_buffer_imports.h
// Phase 1 Unit Y: Private helper - GlesHardwareBufferImports.
//
// Owns the AHardwareBuffer -> EGLImage -> GL_TEXTURE_2D import table for
// RGBA_8888/RGBX_8888 GPU-sampled buffers on the GLES backend. All Android/
// EGL/GLES headers and extension declarations are confined to the .cpp
// translation unit; this header includes only <memory> and the public
// shared opaque hardware-buffer types.
//
// Private source: instantiated only by GlesBackend::Impl (gles_backend.cpp)
// and not exposed through the public gles_backend.h.
//
// Unit Y scope: RGBA_8888/RGBX_8888 GPU_SAMPLED_IMAGE buffers only. No
// renderFrame(), shader sampling, or YUV/external-texture formats.
//
// Unit Z adds textureForHandle(), a read-only accessor to the GL texture
// name already owned by an active import record, so GlesBackend::renderFrame
// can sample it. It does not change import/release/duplicate/shutdown
// ownership or behavior.
//
// Unit AE: importBuffer() waits on and closes the caller-supplied acquire
// fence (bounded poll(), fail-closed on timeout/error) before importing; no
// release fence is produced. No EGL native-fence GPU chaining, YUV/external
// texture, multi-node composition, or product UI wiring.

#pragma once
#include "vanguard/render/hardware_buffer_import.h"
#include <memory>

namespace vanguard {
namespace render {

class GlesHardwareBufferImports {
public:
    GlesHardwareBufferImports();
    ~GlesHardwareBufferImports();

    GlesHardwareBufferImports(const GlesHardwareBufferImports&) = delete;
    GlesHardwareBufferImports& operator=(const GlesHardwareBufferImports&) = delete;

    // Must be called once after GlesBackend's offscreen EGL init succeeds.
    // eglDisplayHandle is the EGLDisplay cast to void*. Resolves optional
    // libandroid.so / eglGetProcAddress extension symbols; failure to
    // resolve any of them does not fail this call -- importBuffer() returns
    // kUnavailable instead. No-op on non-Android host builds.
    void initialize(void* eglDisplayHandle);

    // Idempotent teardown: destroys all active import records (GL texture,
    // EGLImage, AHardwareBuffer ref, stored acquireFenceFd) and clears
    // resolved symbols/display. Must be called while the owning EGL context
    // is still current, before the caller destroys the EGL context/display.
    void shutdown();

    // hardwareBuffer  - non-null AHardwareBuffer* cast to void*.
    // acquireFenceFd  - ownership transfers at call entry on all return
    //                   paths. If < 0, ignored. If >= 0, waited on
    //                   synchronously (bounded poll(), 1000ms) before the
    //                   AHardwareBuffer is acquired/described/imported, then
    //                   always closed exactly once; never stored. Wait
    //                   timeout or failure fails the import closed.
    // outHandle       - non-null; set to kInvalidHardwareBufferHandle on
    //                   failure.
    // outDescriptor   - non-null; zeroed on failure.
    HardwareBufferImportResult importBuffer(
        void* hardwareBuffer,
        int acquireFenceFd,
        HardwareBufferHandle* outHandle,
        HardwareBufferDescriptor* outDescriptor);

    // outReleaseFenceFd - optional; always set to -1 (Unit Y never produces
    // a release fence).
    HardwareBufferImportResult releaseBuffer(
        HardwareBufferHandle handle,
        int* outReleaseFenceFd);

    bool hasBuffer(HardwareBufferHandle handle) const;

    // Phase 1 Unit Z: returns the GL_TEXTURE_2D name stored for an active
    // import, or 0 if handle is unknown, no texture was created for it, or
    // on non-Android host builds. Not part of the public GlesBackend API;
    // consumed only by GlesBackend::renderFrame(). Never exposes EGL/GLES
    // types through this header.
    uint32_t textureForHandle(HardwareBufferHandle handle) const;

    // Human-readable description of the last importBuffer()/releaseBuffer()
    // failure, or "" if the last call succeeded.
    const char* lastError() const;

private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};

} // namespace render
} // namespace vanguard
