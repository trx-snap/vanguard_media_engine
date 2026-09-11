#include "vanguard/android/android_duet_vulkan_preview_session.h"
#include "vanguard/render/vulkan_backend.h"

#include <android/native_window.h>
#include <mutex>

namespace vanguard {
namespace android {

struct AndroidDuetVulkanPreviewSession::Impl {
    std::mutex mutex;
    std::unique_ptr<render::VulkanBackend> backend;
    bool hasSurface{false};
};

AndroidDuetVulkanPreviewSession::AndroidDuetVulkanPreviewSession() : impl_(std::make_unique<Impl>()) {}

AndroidDuetVulkanPreviewSession::~AndroidDuetVulkanPreviewSession() {
    std::lock_guard<std::mutex> lock(impl_->mutex);
    if (impl_->backend) {
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

} // namespace android
} // namespace vanguard
