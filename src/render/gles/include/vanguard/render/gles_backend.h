#pragma once
#include "vanguard/render/render_backend.h"
#include <cstdint>
#include <memory>

namespace vanguard {
namespace render {

// Phase Unit U: GlesBackend owns an offscreen EGL/GLES lifecycle on Android.
// EGL/GLES headers must never appear in this public header; all such state
// lives exclusively in gles_backend.cpp behind the Impl pimpl.
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

    // Surface lifecycle stubs (GLES surface management deferred).
    bool attachSurface(void* nativeWindow,
                       uint32_t width,
                       uint32_t height) override;
    bool resizeSurface(uint32_t width, uint32_t height) override;
    void detachSurface() override;
    bool hasSurface() const override;

    // Phase 2C: AHardwareBuffer import - not supported on GLES backend.
    HardwareBufferImportResult importHardwareBuffer(
        void* hardwareBuffer,
        int acquireFenceFd,
        HardwareBufferHandle* outHandle,
        HardwareBufferDescriptor* outDescriptor) override;

    HardwareBufferImportResult releaseHardwareBuffer(
        HardwareBufferHandle handle,
        int* outReleaseFenceFd) override;

    bool hasHardwareBuffer(HardwareBufferHandle handle) const override;

    // Phase 2O1: Frame rendering seam stub - GLES backend does not support this.
    RenderFrameResult renderFrame(HardwareBufferHandle handle) override;

    // Phase 4B2C: transform overload stub - GLES backend does not support this.
    RenderFrameResult renderFrame(HardwareBufferHandle handle,
                                  const VideoFrameTransform& transform) override;

    // ---------------------------------------------------------------------------
    // Unit U: offscreen EGL/GLES diagnostic accessors.
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

    // Human-readable description of the last initialize()/shutdown() failure,
    // or "" if none.
    const char* lastError() const;

private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};

} // namespace render
} // namespace vanguard
