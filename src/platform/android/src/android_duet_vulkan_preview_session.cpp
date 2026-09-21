#include "vanguard/android/android_duet_vulkan_preview_session.h"
#include "vanguard/render/vulkan_backend.h"

#include <android/native_window.h>
#include <mutex>
#include <unistd.h>

namespace vanguard {
namespace android {

namespace {
constexpr uint32_t kDefaultMaskWidth = 1;
constexpr uint32_t kDefaultMaskHeight = 1;

void CloseFenceFdIfValid(int fd) {
    if (fd >= 0) {
        ::close(fd);
    }
}
} // namespace

struct AndroidDuetVulkanPreviewSession::Impl {
    std::mutex mutex;
    std::unique_ptr<render::VulkanBackend> backend;
    bool hasSurface{false};
    render::VulkanOverlayTextureHandle maskHandle{render::kInvalidOverlayTextureHandle};

    // ANDROID-DUET-VULKAN-GPU-MASK: GPU-resident mask imported from an
    // AHardwareBuffer via UpdateGpuMask(), held across frames independently
    // of maskHandle above (the CPU-uploaded mask). Width/height are the
    // import's own descriptor dimensions, needed by RenderFrame's mask
    // selection since VulkanHardwareBufferImage does not store them.
    render::HardwareBufferHandle gpuMaskHandle{render::kInvalidHardwareBufferHandle};
    uint32_t gpuMaskWidth{0};
    uint32_t gpuMaskHeight{0};
};

AndroidDuetVulkanPreviewSession::AndroidDuetVulkanPreviewSession() : impl_(std::make_unique<Impl>()) {}

AndroidDuetVulkanPreviewSession::~AndroidDuetVulkanPreviewSession() {
    std::lock_guard<std::mutex> lock(impl_->mutex);
    if (impl_->backend) {
        // GPU mask survives DetachSurface() (like the CPU mask below) since
        // both are backend/import-table-scoped, not surface-scoped; only
        // full session teardown releases it.
        if (impl_->gpuMaskHandle != render::kInvalidHardwareBufferHandle) {
            int releaseFenceFd = -1;
            impl_->backend->releaseHardwareBuffer(impl_->gpuMaskHandle, &releaseFenceFd);
            CloseFenceFdIfValid(releaseFenceFd);
            impl_->gpuMaskHandle = render::kInvalidHardwareBufferHandle;
        }
        if (impl_->maskHandle != render::kInvalidOverlayTextureHandle) {
            impl_->backend->releaseOverlayTexture(impl_->maskHandle);
            impl_->maskHandle = render::kInvalidOverlayTextureHandle;
        }
        if (impl_->hasSurface) {
            impl_->backend->detachSurface();
            impl_->hasSurface = false;
        }
        impl_->backend->shutdown();
        impl_->backend.reset();
    }
}

bool AndroidDuetVulkanPreviewSession::Initialize() {
    std::lock_guard<std::mutex> lock(impl_->mutex);
    impl_->backend = std::make_unique<render::VulkanBackend>();
    if (!impl_->backend->initialize()) {
        impl_->backend.reset();
        return false;
    }

    const uint8_t kZeroMask[kDefaultMaskWidth * kDefaultMaskHeight] = {0};
    render::VulkanOverlayTextureHandle maskHandle = render::kInvalidOverlayTextureHandle;
    if (!impl_->backend->createOverlayTextureR8(
            kZeroMask, sizeof(kZeroMask), kDefaultMaskWidth, kDefaultMaskHeight,
            /*rowStrideBytes=*/0, &maskHandle)) {
        impl_->backend->shutdown();
        impl_->backend.reset();
        return false;
    }
    impl_->maskHandle = maskHandle;
    return true;
}

bool AndroidDuetVulkanPreviewSession::AttachSurface(ANativeWindow* window, uint32_t width, uint32_t height) {
    std::lock_guard<std::mutex> lock(impl_->mutex);
    if (!impl_->backend) return false;
    if (impl_->hasSurface) {
        impl_->backend->detachSurface();
        impl_->hasSurface = false;
    }
    bool ok = impl_->backend->attachSurface(window, width, height);
    if (ok) {
        impl_->hasSurface = true;
    }
    return ok;
}

void AndroidDuetVulkanPreviewSession::DetachSurface() {
    std::lock_guard<std::mutex> lock(impl_->mutex);
    if (impl_->backend && impl_->hasSurface) {
        impl_->backend->detachSurface();
        impl_->hasSurface = false;
    }
}

bool AndroidDuetVulkanPreviewSession::UpdateMask(const uint8_t* r8, size_t r8ByteCount, uint32_t width, uint32_t height) {
    std::lock_guard<std::mutex> lock(impl_->mutex);
    if (!impl_->backend || !r8 || r8ByteCount == 0 || width == 0 || height == 0) {
        return false;
    }

    render::VulkanOverlayTextureInfo existingInfo{};
    const bool hasExisting = impl_->maskHandle != render::kInvalidOverlayTextureHandle &&
        impl_->backend->getOverlayTextureInfo(impl_->maskHandle, &existingInfo);

    if (hasExisting && existingInfo.width == width && existingInfo.height == height) {
        // Same-size update in place; on failure the existing mask is left
        // untouched by updateOverlayTextureR8's own fail-closed contract.
        return impl_->backend->updateOverlayTextureR8(
            impl_->maskHandle, r8, r8ByteCount, width, height, /*rowStrideBytes=*/0);
    }

    render::VulkanOverlayTextureHandle newHandle = render::kInvalidOverlayTextureHandle;
    if (!impl_->backend->createOverlayTextureR8(
            r8, r8ByteCount, width, height, /*rowStrideBytes=*/0, &newHandle)) {
        // Keep the old mask (if any) valid; nothing was created or destroyed.
        return false;
    }

    if (impl_->maskHandle != render::kInvalidOverlayTextureHandle) {
        impl_->backend->releaseOverlayTexture(impl_->maskHandle);
    }
    impl_->maskHandle = newHandle;
    return true;
}

bool AndroidDuetVulkanPreviewSession::UpdateGpuMask(
    void* gpuMaskBuffer, uint32_t width, uint32_t height, int acquireFenceFd) {
    std::lock_guard<std::mutex> lock(impl_->mutex);
    if (!impl_->backend || !gpuMaskBuffer || width == 0 || height == 0) {
        CloseFenceFdIfValid(acquireFenceFd);
        return false;
    }

    render::HardwareBufferHandle newHandle = render::kInvalidHardwareBufferHandle;
    render::HardwareBufferDescriptor descriptor{};
    const auto importResult = impl_->backend->importHardwareBuffer(
        gpuMaskBuffer, acquireFenceFd, &newHandle, &descriptor);
    if (importResult != render::HardwareBufferImportResult::kSuccess ||
        descriptor.width == 0 || descriptor.height == 0) {
        // Keep the previously valid GPU mask (if any) untouched.
        return false;
    }

    if (impl_->gpuMaskHandle != render::kInvalidHardwareBufferHandle) {
        int releaseFenceFd = -1;
        impl_->backend->releaseHardwareBuffer(impl_->gpuMaskHandle, &releaseFenceFd);
        CloseFenceFdIfValid(releaseFenceFd);
    }
    impl_->gpuMaskHandle = newHandle;
    impl_->gpuMaskWidth = descriptor.width;
    impl_->gpuMaskHeight = descriptor.height;
    return true;
}

bool AndroidDuetVulkanPreviewSession::RenderFrame(
    void* decoderBuffer,
    void* cameraBuffer,
    bool greenScreenEnabled,
    const AndroidDuetVulkanPreviewLayoutRect& sourceRect,
    const AndroidDuetVulkanPreviewLayoutRect& cameraRect,
    uint32_t sourceRotationDegrees,
    uint32_t cameraRotationDegrees,
    bool cameraMirrorHorizontal,
    int32_t debugMode,
    uint32_t sourceContentWidth,
    uint32_t sourceContentHeight,
    uint32_t cameraContentWidth,
    uint32_t cameraContentHeight,
    float foregroundRotationDegrees,
    float foregroundAnchorX,
    float foregroundAnchorY) {
    std::lock_guard<std::mutex> lock(impl_->mutex);
    if (!impl_->backend || !impl_->hasSurface || !decoderBuffer || !cameraBuffer) {
        return false;
    }
    // Layout geometry is validated before anything is imported so an invalid
    // rect never costs an import/release round trip (the backend fails closed
    // on it anyway). Both modes place the layers by rect now
    // (ANDROID-DUET-VULKAN-GREENSCREEN-VISUAL), so both validate.
    if (sourceRect.width <= 0 || sourceRect.height <= 0 ||
        cameraRect.width <= 0 || cameraRect.height <= 0) {
        return false;
    }

    render::HardwareBufferHandle decoderHandle = render::kInvalidHardwareBufferHandle;
    render::HardwareBufferDescriptor decoderDescriptor{};
    const auto decoderImportResult = impl_->backend->importHardwareBuffer(
        decoderBuffer, -1, &decoderHandle, &decoderDescriptor);
    if (decoderImportResult != render::HardwareBufferImportResult::kSuccess) {
        return false;
    }

    render::HardwareBufferHandle cameraHandle = render::kInvalidHardwareBufferHandle;
    render::HardwareBufferDescriptor cameraDescriptor{};
    const auto cameraImportResult = impl_->backend->importHardwareBuffer(
        cameraBuffer, -1, &cameraHandle, &cameraDescriptor);
    if (cameraImportResult != render::HardwareBufferImportResult::kSuccess) {
        int releaseFenceFd = -1;
        impl_->backend->releaseHardwareBuffer(decoderHandle, &releaseFenceFd);
        CloseFenceFdIfValid(releaseFenceFd);
        return false;
    }

    render::RenderDestinationRect sourceDestination{};
    sourceDestination.x = sourceRect.x;
    sourceDestination.y = sourceRect.y;
    sourceDestination.width = sourceRect.width;
    sourceDestination.height = sourceRect.height;
    render::RenderDestinationRect cameraDestination{};
    cameraDestination.x = cameraRect.x;
    cameraDestination.y = cameraRect.y;
    cameraDestination.width = cameraRect.width;
    cameraDestination.height = cameraRect.height;

    // ANDROID-DUET-VULKAN-CAMERA-CONTENT-DIMENSIONS: prefer the caller's
    // logical content dimensions (the originating Image's width/height) for
    // the aspect-fill crop over each import's own AHardwareBuffer descriptor
    // dimensions, since the descriptor can be padded to a consumer/allocator
    // size (e.g. a portrait ImageReader request rounded up to a square
    // allocation) that does not reflect the real content aspect ratio. The
    // descriptor remains the fallback whenever the caller did not supply a
    // positive width/height pair.
    const uint32_t effectiveSourceWidth =
        (sourceContentWidth > 0 && sourceContentHeight > 0) ? sourceContentWidth : decoderDescriptor.width;
    const uint32_t effectiveSourceHeight =
        (sourceContentWidth > 0 && sourceContentHeight > 0) ? sourceContentHeight : decoderDescriptor.height;
    const uint32_t effectiveCameraWidth =
        (cameraContentWidth > 0 && cameraContentHeight > 0) ? cameraContentWidth : cameraDescriptor.width;
    const uint32_t effectiveCameraHeight =
        (cameraContentWidth > 0 && cameraContentHeight > 0) ? cameraContentHeight : cameraDescriptor.height;

    render::RenderFrameResult renderResult = render::RenderFrameResult::kVulkanFailure;
    if (greenScreenEnabled) {
        // Same rects / buffer dimensions as the layout path; the GPU mask
        // import is only referenced for this frame and stays held by
        // impl_->gpuMaskHandle (never released by RenderFrame). The source
        // layer is never mirrored; only the camera layer honors
        // cameraMirrorHorizontal (front camera).
        renderResult = impl_->backend->renderDuetGreenScreenFrame(
            decoderHandle, cameraHandle,
            sourceDestination, cameraDestination,
            effectiveSourceWidth, effectiveSourceHeight,
            effectiveCameraWidth, effectiveCameraHeight,
            impl_->maskHandle,
            impl_->gpuMaskHandle, impl_->gpuMaskWidth, impl_->gpuMaskHeight,
            sourceRotationDegrees, /*sourceMirrorHorizontal=*/false,
            cameraRotationDegrees, cameraMirrorHorizontal, debugMode,
            foregroundRotationDegrees, foregroundAnchorX, foregroundAnchorY);
    } else {
        renderResult = impl_->backend->renderDuetLayoutFrame(
            decoderHandle, cameraHandle,
            sourceDestination, cameraDestination,
            effectiveSourceWidth, effectiveSourceHeight,
            effectiveCameraWidth, effectiveCameraHeight,
            sourceRotationDegrees, /*sourceMirrorHorizontal=*/false,
            cameraRotationDegrees, cameraMirrorHorizontal);
    }

    int decoderReleaseFenceFd = -1;
    impl_->backend->releaseHardwareBuffer(decoderHandle, &decoderReleaseFenceFd);
    CloseFenceFdIfValid(decoderReleaseFenceFd);

    int cameraReleaseFenceFd = -1;
    impl_->backend->releaseHardwareBuffer(cameraHandle, &cameraReleaseFenceFd);
    CloseFenceFdIfValid(cameraReleaseFenceFd);

    return renderResult == render::RenderFrameResult::kSuccess ||
           renderResult == render::RenderFrameResult::kSuboptimal;
}

bool AndroidDuetVulkanPreviewSession::RenderStaticBackgroundFrame(
    void* cameraBuffer,
    const AndroidDuetVulkanPreviewLayoutRect& cameraRect,
    uint32_t cameraRotationDegrees,
    bool cameraMirrorHorizontal,
    int32_t debugMode,
    int32_t backgroundMode,
    uint32_t cameraContentWidth,
    uint32_t cameraContentHeight,
    float foregroundRotationDegrees,
    float foregroundAnchorX,
    float foregroundAnchorY) {
    std::lock_guard<std::mutex> lock(impl_->mutex);
    if (!impl_->backend || !impl_->hasSurface || !cameraBuffer) {
        return false;
    }
    // Geometry and mode are validated before anything is imported so an
    // invalid rect / unknown mode never costs an import/release round trip.
    if (cameraRect.width <= 0 || cameraRect.height <= 0) {
        return false;
    }
    render::DuetGreenScreenStaticBackgroundMode mode;
    switch (backgroundMode) {
        case static_cast<int32_t>(render::DuetGreenScreenStaticBackgroundMode::kSolidTeal):
            mode = render::DuetGreenScreenStaticBackgroundMode::kSolidTeal;
            break;
        default:
            return false;
    }

    // ANDROID-DUET-VULKAN-GREENSCREEN-STATIC-BACKGROUND: only the camera is
    // imported; there is no decoder import on this path.
    render::HardwareBufferHandle cameraHandle = render::kInvalidHardwareBufferHandle;
    render::HardwareBufferDescriptor cameraDescriptor{};
    const auto cameraImportResult = impl_->backend->importHardwareBuffer(
        cameraBuffer, -1, &cameraHandle, &cameraDescriptor);
    if (cameraImportResult != render::HardwareBufferImportResult::kSuccess) {
        return false;
    }

    render::RenderDestinationRect cameraDestination{};
    cameraDestination.x = cameraRect.x;
    cameraDestination.y = cameraRect.y;
    cameraDestination.width = cameraRect.width;
    cameraDestination.height = cameraRect.height;

    // Same ANDROID-DUET-VULKAN-CAMERA-CONTENT-DIMENSIONS rule as RenderFrame:
    // the caller's logical content size wins over the (possibly padded)
    // import descriptor whenever both components are > 0.
    const uint32_t effectiveCameraWidth =
        (cameraContentWidth > 0 && cameraContentHeight > 0) ? cameraContentWidth : cameraDescriptor.width;
    const uint32_t effectiveCameraHeight =
        (cameraContentWidth > 0 && cameraContentHeight > 0) ? cameraContentHeight : cameraDescriptor.height;

    // Same mask handles as RenderFrame's green-screen path: the backend
    // prefers the held GPU mask import when valid and falls back to the CPU
    // mask; the GPU mask stays held by impl_->gpuMaskHandle (never released
    // here).
    const render::RenderFrameResult renderResult =
        impl_->backend->renderDuetGreenScreenStaticBackgroundFrame(
            cameraHandle, cameraDestination,
            effectiveCameraWidth, effectiveCameraHeight,
            impl_->maskHandle,
            impl_->gpuMaskHandle, impl_->gpuMaskWidth, impl_->gpuMaskHeight,
            cameraRotationDegrees, cameraMirrorHorizontal, debugMode, mode,
            foregroundRotationDegrees, foregroundAnchorX, foregroundAnchorY);

    int cameraReleaseFenceFd = -1;
    impl_->backend->releaseHardwareBuffer(cameraHandle, &cameraReleaseFenceFd);
    CloseFenceFdIfValid(cameraReleaseFenceFd);

    return renderResult == render::RenderFrameResult::kSuccess ||
           renderResult == render::RenderFrameResult::kSuboptimal;
}

} // namespace android
} // namespace vanguard
