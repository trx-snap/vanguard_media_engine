#pragma once

#include <memory>
#include <cstdint>

struct ANativeWindow;

namespace vanguard {
namespace android {

class AndroidDuetVulkanPreviewSession {
public:
    AndroidDuetVulkanPreviewSession();
    ~AndroidDuetVulkanPreviewSession();

    // Non-copyable, non-movable
    AndroidDuetVulkanPreviewSession(const AndroidDuetVulkanPreviewSession&) = delete;
    AndroidDuetVulkanPreviewSession& operator=(const AndroidDuetVulkanPreviewSession&) = delete;

    bool Initialize();
    bool AttachSurface(ANativeWindow* window, uint32_t width, uint32_t height);
    void DetachSurface();

private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};

} // namespace android
} // namespace vanguard
