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
};

AndroidDuetVulkanPreviewSession::AndroidDuetVulkanPreviewSession() : impl_(std::make_unique<Impl>()) {}

AndroidDuetVulkanPreviewSession::~AndroidDuetVulkanPreviewSession() {
    std::lock_guard<std::mutex> lock(impl_->mutex);
    if (impl_->backend) {
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

bool AndroidDuetVulkanPreviewSession::RenderFrame(
    void* decoderBuffer,
    void* cameraBuffer,
    bool greenScreenEnabled,
    const AndroidDuetVulkanPreviewLayoutRect& sourceRect,
    const AndroidDuetVulkanPreviewLayoutRect& cameraRect) {
    std::lock_guard<std::mutex> lock(impl_->mutex);
    if (!impl_->backend || !impl_->hasSurface || !decoderBuffer || !cameraBuffer) {
        return false;
    }
    // Layout geometry is validated before anything is imported so an invalid
    // rect never costs an import/release round trip (the backend fails closed
    // on it anyway).
    if (!greenScreenEnabled &&
        (sourceRect.width <= 0 || sourceRect.height <= 0 ||
         cameraRect.width <= 0 || cameraRect.height <= 0)) {
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

    render::RenderFrameResult renderResult = render::RenderFrameResult::kVulkanFailure;
    if (greenScreenEnabled) {
        renderResult = impl_->backend->renderDuetGreenScreenFrame(
            decoderHandle, cameraHandle, impl_->maskHandle);
    } else {
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
        renderResult = impl_->backend->renderDuetLayoutFrame(
            decoderHandle, cameraHandle,
            sourceDestination, cameraDestination,
            decoderDescriptor.width, decoderDescriptor.height,
            cameraDescriptor.width, cameraDescriptor.height);
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

} // namespace android
} // namespace vanguard
