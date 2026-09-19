// android_dualcam_compositor_jni.cpp
// Slice 1: Native Dual-Camera Compositor Core — JNI entry points.
//
// Exposes four JNI functions:
//   nativeCreateDualCamSession    — Vulkan swapchain OR GLES EGL session + command pool.
//   nativeDualCamCompositeFrame   — Per-frame AHB→Vulkan import + swapchain render, OR GLES draw.
//   nativeComputeMultiCamLayout   — Thin JSON wrapper over ComputeMultiCamLayout().
//   nativeDestroyDualCamSession   — Idempotent teardown (vkDeviceWaitIdle or eglDestroyContext).
//
// Logging tag: "VanguardDualCamJNI"
//
// Architectural constraints (Slice 1):
//   - No Camera2 / CameraDevice / CaptureSession interaction.
//   - No TextureRegistry / Flutter surfaces — outputSurface is caller-supplied.
//   - No photo capture readback (separate one-shot path, Slice 4).

#if defined(__ANDROID__)

#ifndef VK_USE_PLATFORM_ANDROID_KHR
#define VK_USE_PLATFORM_ANDROID_KHR
#endif

#include <jni.h>
#include <android/log.h>
#include <android/native_window_jni.h>
#include <android/hardware_buffer_jni.h>

#include <vulkan/vulkan.h>
#include <EGL/egl.h>
#include <GLES3/gl3.h>

#include <string>
#include <cstring>
#include <memory>
#include <atomic>
#include <dlfcn.h>
#include <cstdlib>

// Engine helpers — all in the private Vulkan source dir (render/vulkan/src).
#include "vulkan_surface_swapchain.h"
#include "vulkan_hardware_buffer_imports.h"

// Layout math — public compositors include dir.
#include "vanguard/compositors/multi_cam_compositor_node.h"

// Backend probe — platform/android/include.
#include "vanguard/platform/android_backend_probe.h"

#define VGLOG_TAG "VanguardDualCamJNI"
#define VGLOG_I(...) __android_log_print(ANDROID_LOG_INFO,  VGLOG_TAG, __VA_ARGS__)
#define VGLOG_W(...) __android_log_print(ANDROID_LOG_WARN,  VGLOG_TAG, __VA_ARGS__)
#define VGLOG_E(...) __android_log_print(ANDROID_LOG_ERROR, VGLOG_TAG, __VA_ARGS__)
#define VGLOG_D(...) __android_log_print(ANDROID_LOG_DEBUG, VGLOG_TAG, __VA_ARGS__)

namespace {

// ---------------------------------------------------------------------------
// AHardwareBuffer_fromHardwareBuffer runtime resolution (pattern established
// in existing JNI TUs).
// ---------------------------------------------------------------------------
using FnAHardwareBuffer_fromHardwareBuffer = AHardwareBuffer* (*)(JNIEnv*, jobject);

FnAHardwareBuffer_fromHardwareBuffer ResolveAHBFromHardwareBuffer() {
    void* lib = dlopen("libandroid.so", RTLD_NOW | RTLD_LOCAL);
    if (!lib) return nullptr;
    auto fn = reinterpret_cast<FnAHardwareBuffer_fromHardwareBuffer>(
        dlsym(lib, "AHardwareBuffer_fromHardwareBuffer"));
    dlclose(lib);
    return fn;
}

// ---------------------------------------------------------------------------
// JSON layout parsing helpers (fail-closed: reject any unknown string).
// ---------------------------------------------------------------------------
struct ParsedLayoutParams {
    bool ok = false;
    std::string rejectionReason;
    vanguard::compositors::MultiCamLayoutMode  mode;
    vanguard::compositors::MultiCamPiPAnchor   anchor;
    vanguard::compositors::MultiCamSplitDirection direction;
    double splitRatio         = 0.5;
    double pipWidthFraction   = 0.3;
    double pipCenterX         = 0.5; // normalized [0,1]; used only when anchor == kFreeFloating
    double pipCenterY         = 0.5; // normalized [0,1]; used only when anchor == kFreeFloating
};

// Minimal JSON value extraction — looks for "key":"value" or "key":number.
static std::string ExtractJsonString(const std::string& json, const std::string& key) {
    std::string search = "\"" + key + "\":\"";
    auto pos = json.find(search);
    if (pos == std::string::npos) return "";
    pos += search.size();
    auto end = json.find('"', pos);
    if (end == std::string::npos) return "";
    return json.substr(pos, end - pos);
}

static double ExtractJsonDouble(const std::string& json, const std::string& key, double fallback) {
    std::string search = "\"" + key + "\":";
    auto pos = json.find(search);
    if (pos == std::string::npos) return fallback;
    pos += search.size();
    try { return std::stod(json.substr(pos)); } catch (...) { return fallback; }
}

static ParsedLayoutParams ParseLayoutJson(const std::string& json) {
    ParsedLayoutParams out;
    using namespace vanguard::compositors;

    const std::string modeStr      = ExtractJsonString(json, "layoutMode");
    const std::string anchorStr    = ExtractJsonString(json, "pipAnchor");
    const std::string dirStr       = ExtractJsonString(json, "splitDirection");

    if (modeStr == "pip")         out.mode = MultiCamLayoutMode::kPictureInPicture;
    else if (modeStr == "splitScreen") out.mode = MultiCamLayoutMode::kSplitScreen;
    else { out.rejectionReason = "unknown_layout_mode:" + modeStr; return out; }

    if      (anchorStr == "freeFloating")  out.anchor = MultiCamPiPAnchor::kFreeFloating;
    else if (anchorStr == "topLeft")       out.anchor = MultiCamPiPAnchor::kTopLeft;
    else if (anchorStr == "topRight")      out.anchor = MultiCamPiPAnchor::kTopRight;
    else if (anchorStr == "bottomLeft")    out.anchor = MultiCamPiPAnchor::kBottomLeft;
    else if (anchorStr == "bottomRight")   out.anchor = MultiCamPiPAnchor::kBottomRight;
    else { out.rejectionReason = "unknown_pip_anchor:" + anchorStr; return out; }

    if      (dirStr == "topBottom")  out.direction = MultiCamSplitDirection::kTopBottom;
    else if (dirStr == "leftRight")  out.direction = MultiCamSplitDirection::kLeftRight;
    else { out.rejectionReason = "unknown_split_direction:" + dirStr; return out; }

    out.splitRatio       = ExtractJsonDouble(json, "splitRatio", 0.5);
    out.pipWidthFraction = ExtractJsonDouble(json, "pipWidthFraction", 0.3);
    out.pipCenterX       = ExtractJsonDouble(json, "pipCenterX", 0.5);
    out.pipCenterY       = ExtractJsonDouble(json, "pipCenterY", 0.5);
    out.ok = true;
    return out;
}

// ---------------------------------------------------------------------------
// Vulkan device selection helpers (minimal — graphics queue + AHB extension).
// ---------------------------------------------------------------------------
static const char* kAhbExtension = "VK_ANDROID_external_memory_android_hardware_buffer";

static bool DeviceSupportsExtension(VkPhysicalDevice dev, const char* name) {
    uint32_t count = 0;
    vkEnumerateDeviceExtensionProperties(dev, nullptr, &count, nullptr);
    if (count == 0) return false;
    std::vector<VkExtensionProperties> exts(count);
    vkEnumerateDeviceExtensionProperties(dev, nullptr, &count, exts.data());
    for (const auto& e : exts) {
        if (std::strcmp(e.extensionName, name) == 0) return true;
    }
    return false;
}

static bool DeviceSupportsYcbcr(VkInstance instance, VkPhysicalDevice dev) {
    auto fn = reinterpret_cast<PFN_vkGetPhysicalDeviceFeatures2>(
        vkGetInstanceProcAddr(instance, "vkGetPhysicalDeviceFeatures2"));
    if (!fn) fn = reinterpret_cast<PFN_vkGetPhysicalDeviceFeatures2>(
        vkGetInstanceProcAddr(instance, "vkGetPhysicalDeviceFeatures2KHR"));
    if (!fn) return false;
    VkPhysicalDeviceSamplerYcbcrConversionFeatures ycbcr{};
    ycbcr.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_SAMPLER_YCBCR_CONVERSION_FEATURES;
    VkPhysicalDeviceFeatures2 f2{};
    f2.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2;
    f2.pNext = &ycbcr;
    fn(dev, &f2);
    return ycbcr.samplerYcbcrConversion == VK_TRUE;
}

// ---------------------------------------------------------------------------
// Session structs
// ---------------------------------------------------------------------------

struct VulkanDualCamSession {
    VkInstance       instance       = VK_NULL_HANDLE;
    VkPhysicalDevice physDev        = VK_NULL_HANDLE;
    uint32_t         queueFamily    = UINT32_MAX;
    VkDevice         device         = VK_NULL_HANDLE;
    VkQueue          queue          = VK_NULL_HANDLE;
    VkCommandPool    commandPool    = VK_NULL_HANDLE;

    // Output swapchain attached to the ANativeWindow from outputSurface.
    vanguard::render::VulkanSurfaceSwapchain swapchain;

    // AHB import table for per-frame imports.
    vanguard::render::VulkanHardwareBufferImports imports;

    // Swapchain synchronization primitives (one per swapchain image).
    std::vector<VkSemaphore> imageAvailableSemaphores;
    std::vector<VkSemaphore> renderFinishedSemaphores;
    std::vector<VkFence>     inFlightFences;

    // Command buffers (one per swapchain image).
    std::vector<VkCommandBuffer> commandBuffers;

    // Rotating frame slot counter — per-session, not global.
    std::atomic<uint32_t> frameSlot{0};

    // Borrowed native window (ANativeWindow from the output Surface).
    ANativeWindow* nativeWindow = nullptr;

    bool isValid() const { return device != VK_NULL_HANDLE; }

    void Teardown() {
        if (device == VK_NULL_HANDLE) return;
        vkDeviceWaitIdle(device);

        // Destroy sync objects.
        for (auto& s : imageAvailableSemaphores) vkDestroySemaphore(device, s, nullptr);
        for (auto& s : renderFinishedSemaphores) vkDestroySemaphore(device, s, nullptr);
        for (auto& f : inFlightFences)           vkDestroyFence(device, f, nullptr);
        imageAvailableSemaphores.clear();
        renderFinishedSemaphores.clear();
        inFlightFences.clear();

        // Free command buffers.
        if (!commandBuffers.empty() && commandPool != VK_NULL_HANDLE) {
            vkFreeCommandBuffers(device, commandPool,
                static_cast<uint32_t>(commandBuffers.size()), commandBuffers.data());
            commandBuffers.clear();
        }

        // Imports shutdown (drains retired queue before device destroy).
        imports.shutdown();

        // Swapchain detach (vkDeviceWaitIdle already called).
        swapchain.detach();

        if (commandPool != VK_NULL_HANDLE) {
            vkDestroyCommandPool(device, commandPool, nullptr);
            commandPool = VK_NULL_HANDLE;
        }
        vkDestroyDevice(device, nullptr);
        device = VK_NULL_HANDLE; queue = VK_NULL_HANDLE;
        if (instance != VK_NULL_HANDLE) {
            vkDestroyInstance(instance, nullptr);
            instance = VK_NULL_HANDLE;
        }
        physDev = VK_NULL_HANDLE; queueFamily = UINT32_MAX;

        // Release borrowed native window.
        if (nativeWindow) { ANativeWindow_release(nativeWindow); nativeWindow = nullptr; }
    }
};

struct GlesDualCamSession {
    EGLDisplay display = EGL_NO_DISPLAY;
    EGLContext context = EGL_NO_CONTEXT;
    EGLSurface surface = EGL_NO_SURFACE;
    ANativeWindow* nativeWindow = nullptr;

    bool isValid() const { return context != EGL_NO_CONTEXT; }

    void Teardown() {
        if (display == EGL_NO_DISPLAY) return;
        eglMakeCurrent(display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
        if (surface != EGL_NO_SURFACE) { eglDestroySurface(display, surface); surface = EGL_NO_SURFACE; }
        if (context != EGL_NO_CONTEXT) { eglDestroyContext(display, context); context = EGL_NO_CONTEXT; }
        eglTerminate(display);
        display = EGL_NO_DISPLAY;
        if (nativeWindow) { ANativeWindow_release(nativeWindow); nativeWindow = nullptr; }
    }
};

// Discriminated union session — opaque jlong handle points to this.
struct DualCamSession {
    bool useVulkan = false;
    std::unique_ptr<VulkanDualCamSession> vk;
    std::unique_ptr<GlesDualCamSession>   gles;
    uint32_t canvasWidth  = 0;
    uint32_t canvasHeight = 0;

    void Teardown() {
        if (vk)   { vk->Teardown();   vk.reset(); }
        if (gles) { gles->Teardown(); gles.reset(); }
    }
};

// ---------------------------------------------------------------------------
// Vulkan session creation
// ---------------------------------------------------------------------------
static bool CreateVulkanSession(VulkanDualCamSession& s, ANativeWindow* window,
                                uint32_t width, uint32_t height,
                                std::string& outErr) {
    // 1. Instance.
    VkApplicationInfo appInfo{};
    appInfo.sType              = VK_STRUCTURE_TYPE_APPLICATION_INFO;
    appInfo.pApplicationName   = "VanguardDualCamCompositor";
    appInfo.applicationVersion = VK_MAKE_VERSION(0, 1, 0);
    appInfo.pEngineName        = "VanguardRenderEngine";
    appInfo.engineVersion      = VK_MAKE_VERSION(0, 1, 0);
    appInfo.apiVersion         = VK_API_VERSION_1_1;

    const char* instanceExts[] = {
        "VK_KHR_surface",
        "VK_KHR_android_surface",
    };
    VkInstanceCreateInfo instanceCI{};
    instanceCI.sType                   = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO;
    instanceCI.pApplicationInfo        = &appInfo;
    instanceCI.enabledExtensionCount   = 2;
    instanceCI.ppEnabledExtensionNames = instanceExts;

    VkResult vr = vkCreateInstance(&instanceCI, nullptr, &s.instance);
    if (vr != VK_SUCCESS) {
        s.instance = VK_NULL_HANDLE;
        outErr = "vkCreateInstance failed:" + std::to_string(static_cast<int>(vr));
        return false;
    }

    // 2. Physical device (AHB-capable, graphics queue).
    uint32_t devCount = 0;
    vkEnumeratePhysicalDevices(s.instance, &devCount, nullptr);
    if (devCount == 0) {
        outErr = "no_physical_devices";
        s.Teardown(); return false;
    }
    std::vector<VkPhysicalDevice> devs(devCount);
    vkEnumeratePhysicalDevices(s.instance, &devCount, devs.data());

    for (VkPhysicalDevice dev : devs) {
        VkPhysicalDeviceProperties props{};
        vkGetPhysicalDeviceProperties(dev, &props);
        if (props.deviceType == VK_PHYSICAL_DEVICE_TYPE_CPU) continue;
        if (VK_VERSION_MAJOR(props.apiVersion) < 1 ||
            (VK_VERSION_MAJOR(props.apiVersion) == 1 && VK_VERSION_MINOR(props.apiVersion) < 1)) continue;
        if (!DeviceSupportsExtension(dev, kAhbExtension)) continue;
        if (!DeviceSupportsYcbcr(s.instance, dev)) continue;

        uint32_t famCount = 0;
        vkGetPhysicalDeviceQueueFamilyProperties(dev, &famCount, nullptr);
        std::vector<VkQueueFamilyProperties> fams(famCount);
        vkGetPhysicalDeviceQueueFamilyProperties(dev, &famCount, fams.data());
        uint32_t gfxFamily = UINT32_MAX;
        for (uint32_t i = 0; i < famCount; ++i) {
            if (fams[i].queueCount > 0 && (fams[i].queueFlags & VK_QUEUE_GRAPHICS_BIT)) {
                gfxFamily = i; break;
            }
        }
        if (gfxFamily == UINT32_MAX) continue;

        s.physDev     = dev;
        s.queueFamily = gfxFamily;
        VGLOG_I("Selected GPU: %s", props.deviceName);
        break;
    }

    if (s.physDev == VK_NULL_HANDLE) {
        outErr = "no_suitable_ahb_capable_gpu";
        s.Teardown(); return false;
    }

    // 3. Logical device + queue.
    const float priority = 1.0f;
    VkDeviceQueueCreateInfo queueCI{};
    queueCI.sType            = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO;
    queueCI.queueFamilyIndex = s.queueFamily;
    queueCI.queueCount       = 1;
    queueCI.pQueuePriorities = &priority;

    VkPhysicalDeviceSamplerYcbcrConversionFeatures ycbcrFeat{};
    ycbcrFeat.sType                  = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_SAMPLER_YCBCR_CONVERSION_FEATURES;
    ycbcrFeat.samplerYcbcrConversion = VK_TRUE;

    // Swapchain device extension also needed.
    const char* devExts[] = { kAhbExtension, "VK_KHR_swapchain" };
    VkDeviceCreateInfo devCI{};
    devCI.sType                   = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO;
    devCI.pNext                   = &ycbcrFeat;
    devCI.queueCreateInfoCount    = 1;
    devCI.pQueueCreateInfos       = &queueCI;
    devCI.enabledExtensionCount   = 2;
    devCI.ppEnabledExtensionNames = devExts;

    vr = vkCreateDevice(s.physDev, &devCI, nullptr, &s.device);
    if (vr != VK_SUCCESS) {
        s.device = VK_NULL_HANDLE;
        outErr = "vkCreateDevice failed:" + std::to_string(static_cast<int>(vr));
        s.Teardown(); return false;
    }
    vkGetDeviceQueue(s.device, s.queueFamily, 0, &s.queue);

    // 4. Command pool (resettable buffers for per-frame recording).
    VkCommandPoolCreateInfo poolCI{};
    poolCI.sType            = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO;
    poolCI.flags            = VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT;
    poolCI.queueFamilyIndex = s.queueFamily;
    vr = vkCreateCommandPool(s.device, &poolCI, nullptr, &s.commandPool);
    if (vr != VK_SUCCESS) {
        s.commandPool = VK_NULL_HANDLE;
        outErr = "vkCreateCommandPool failed:" + std::to_string(static_cast<int>(vr));
        s.Teardown(); return false;
    }

    // 5. AHB import table.
    if (!s.imports.initialize(s.device, s.physDev)) {
        outErr = "VulkanHardwareBufferImports::initialize failed";
        s.Teardown(); return false;
    }

    // 6. Swapchain attached to ANativeWindow.
    s.nativeWindow = window;
    ANativeWindow_acquire(window);
    if (!s.swapchain.attach(
            static_cast<void*>(s.instance),
            static_cast<void*>(s.physDev),
            static_cast<void*>(s.device),
            s.queueFamily,
            static_cast<void*>(window),
            width, height)) {
        outErr = "VulkanSurfaceSwapchain::attach failed";
        s.Teardown(); return false;
    }

    // 7. Per-swapchain-image synchronization objects + command buffers.
    const uint32_t imgCount = s.swapchain.getImageCount();
    if (imgCount == 0) {
        outErr = "swapchain image count is 0";
        s.Teardown(); return false;
    }
    s.imageAvailableSemaphores.resize(imgCount, VK_NULL_HANDLE);
    s.renderFinishedSemaphores.resize(imgCount, VK_NULL_HANDLE);
    s.inFlightFences.resize(imgCount, VK_NULL_HANDLE);
    s.commandBuffers.resize(imgCount, VK_NULL_HANDLE);

    VkSemaphoreCreateInfo semCI{ VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO };
    VkFenceCreateInfo fenceCI{ VK_STRUCTURE_TYPE_FENCE_CREATE_INFO };
    fenceCI.flags = VK_FENCE_CREATE_SIGNALED_BIT; // start signaled so first frame doesn't block

    for (uint32_t i = 0; i < imgCount; ++i) {
        if (vkCreateSemaphore(s.device, &semCI, nullptr, &s.imageAvailableSemaphores[i]) != VK_SUCCESS ||
            vkCreateSemaphore(s.device, &semCI, nullptr, &s.renderFinishedSemaphores[i]) != VK_SUCCESS ||
            vkCreateFence(s.device, &fenceCI, nullptr, &s.inFlightFences[i]) != VK_SUCCESS) {
            outErr = "sync_object_creation_failed";
            s.Teardown(); return false;
        }
    }

    VkCommandBufferAllocateInfo cbAlloc{};
    cbAlloc.sType              = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO;
    cbAlloc.commandPool        = s.commandPool;
    cbAlloc.level              = VK_COMMAND_BUFFER_LEVEL_PRIMARY;
    cbAlloc.commandBufferCount = imgCount;
    vr = vkAllocateCommandBuffers(s.device, &cbAlloc, s.commandBuffers.data());
    if (vr != VK_SUCCESS) {
        outErr = "vkAllocateCommandBuffers failed:" + std::to_string(static_cast<int>(vr));
        s.Teardown(); return false;
    }

    VGLOG_I("Vulkan session created swapchainImages=%u width=%u height=%u", imgCount, width, height);
    return true;
}

// ---------------------------------------------------------------------------
// GLES session creation
// ---------------------------------------------------------------------------
static bool CreateGlesSession(GlesDualCamSession& g, ANativeWindow* window,
                              std::string& outErr) {
    g.display = eglGetDisplay(EGL_DEFAULT_DISPLAY);
    if (g.display == EGL_NO_DISPLAY) { outErr = "eglGetDisplay failed"; return false; }

    EGLint major = 0, minor = 0;
    if (!eglInitialize(g.display, &major, &minor)) {
        outErr = "eglInitialize failed";
        g.Teardown(); return false;
    }

    const EGLint attribs[] = {
        EGL_RENDERABLE_TYPE, EGL_OPENGL_ES3_BIT,
        EGL_SURFACE_TYPE, EGL_WINDOW_BIT,
        EGL_RED_SIZE, 8, EGL_GREEN_SIZE, 8, EGL_BLUE_SIZE, 8, EGL_ALPHA_SIZE, 8,
        EGL_NONE
    };
    EGLConfig config = nullptr;
    EGLint numConfigs = 0;
    if (!eglChooseConfig(g.display, attribs, &config, 1, &numConfigs) || numConfigs == 0) {
        outErr = "eglChooseConfig failed";
        g.Teardown(); return false;
    }

    const EGLint ctxAttribs[] = { EGL_CONTEXT_CLIENT_VERSION, 3, EGL_NONE };
    g.context = eglCreateContext(g.display, config, EGL_NO_CONTEXT, ctxAttribs);
    if (g.context == EGL_NO_CONTEXT) {
        outErr = "eglCreateContext failed";
        g.Teardown(); return false;
    }

    g.nativeWindow = window;
    ANativeWindow_acquire(window);
    g.surface = eglCreateWindowSurface(g.display, config, window, nullptr);
    if (g.surface == EGL_NO_SURFACE) {
        outErr = "eglCreateWindowSurface failed";
        g.Teardown(); return false;
    }

    if (!eglMakeCurrent(g.display, g.surface, g.surface, g.context)) {
        outErr = "eglMakeCurrent failed";
        g.Teardown(); return false;
    }

    // Unbind from the calling (creation) thread so the render thread can
    // freely call eglMakeCurrent without getting EGL_BAD_ACCESS.
    eglMakeCurrent(g.display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);

    VGLOG_I("GLES session created");
    return true;
}

// ---------------------------------------------------------------------------
// Layout JSON builder (mirrors Kotlin buildLayoutJson).
// ---------------------------------------------------------------------------
static std::string BuildLayoutJson(const ParsedLayoutParams& p) {
    using namespace vanguard::compositors;
    const char* modeStr = (p.mode == MultiCamLayoutMode::kSplitScreen) ? "splitScreen" : "pip";
    const char* anchorStr = "freeFloating";
    switch (p.anchor) {
        case MultiCamPiPAnchor::kTopLeft:     anchorStr = "topLeft";     break;
        case MultiCamPiPAnchor::kTopRight:    anchorStr = "topRight";    break;
        case MultiCamPiPAnchor::kBottomLeft:  anchorStr = "bottomLeft";  break;
        case MultiCamPiPAnchor::kBottomRight: anchorStr = "bottomRight"; break;
        default: break;
    }
    const char* dirStr = (p.direction == MultiCamSplitDirection::kLeftRight) ? "leftRight" : "topBottom";
    char buf[512];
    std::snprintf(buf, sizeof(buf),
        "{\"layoutMode\":\"%s\",\"pipAnchor\":\"%s\","
        "\"splitDirection\":\"%s\","
        "\"splitRatio\":%.4f,\"pipWidthFraction\":%.4f}",
        modeStr, anchorStr, dirStr, p.splitRatio, p.pipWidthFraction);
    return buf;
}

// ---------------------------------------------------------------------------
// Vulkan per-frame composite render
//   - Imports front/back AHBs.
//   - Acquires swapchain image.
//   - Records a clear render pass (solid color proof for Slice 1).
//   - Submits + presents.
//   - Releases AHB imports.
// ---------------------------------------------------------------------------
static bool VulkanCompositeFrame(VulkanDualCamSession& s,
                                 AHardwareBuffer* frontAhb,
                                 AHardwareBuffer* backAhb,
                                 const ParsedLayoutParams& /*layout*/) {
    using namespace vanguard::render;

    // Import front AHB.
    HardwareBufferHandle frontHandle = kInvalidHardwareBufferHandle;
    HardwareBufferDescriptor frontDesc{};
    if (frontAhb) {
        auto res = s.imports.importBuffer(static_cast<void*>(frontAhb), -1, &frontHandle, &frontDesc);
        if (res != HardwareBufferImportResult::kSuccess) {
            VGLOG_W("Front AHB import failed result=%d", static_cast<int>(res));
            frontHandle = kInvalidHardwareBufferHandle;
        }
    }

    // Import back AHB.
    HardwareBufferHandle backHandle = kInvalidHardwareBufferHandle;
    HardwareBufferDescriptor backDesc{};
    if (backAhb) {
        auto res = s.imports.importBuffer(static_cast<void*>(backAhb), -1, &backHandle, &backDesc);
        if (res != HardwareBufferImportResult::kSuccess) {
            VGLOG_W("Back AHB import failed result=%d", static_cast<int>(res));
            backHandle = kInvalidHardwareBufferHandle;
        }
    }

    // Acquire next swapchain image.
    uint32_t imageIndex = 0;
    uint64_t acquireSemHandle = 0;
    const uint32_t imgCount = s.swapchain.getImageCount();
    // Per-session rotating frame slot (not global static — D4a fix).
    const uint32_t slot = s.frameSlot.fetch_add(1) % imgCount;

    // Encode acquire semaphore handle.
    VkSemaphore acquireSem = s.imageAvailableSemaphores[slot];
    std::memcpy(&acquireSemHandle, &acquireSem, sizeof(uint64_t));

    VkFence fence = s.inFlightFences[slot];
    // Wait for GPU to finish the previous frame that used this slot.
    vkWaitForFences(s.device, 1, &fence, VK_TRUE, UINT64_MAX);
    // Drain retired AHB imports from that frame now GPU work has completed (D4c fix).
    s.imports.drainRetiredForFrame(slot);
    // Reset fence once (and only once) after the wait (D4d fix — no duplicate reset later).
    vkResetFences(s.device, 1, &fence);

    // Pass fenceHandle=0: WSI GPU-GPU sync goes through acquireSem, not the
    // in-flight fence. The fence belongs exclusively to vkQueueSubmit (D4b fix).
    auto acquireResult = s.swapchain.acquireNextImage(acquireSemHandle, 0,
                                                       &imageIndex, UINT64_MAX);
    if (acquireResult == SwapchainResult::kOutOfDate ||
        acquireResult == SwapchainResult::kSurfaceLost) {
        VGLOG_W("acquireNextImage: swapchain out-of-date or surface lost — skipping frame");
        // Release any imports before returning.
        if (frontHandle != kInvalidHardwareBufferHandle) s.imports.releaseBuffer(frontHandle, nullptr);
        if (backHandle  != kInvalidHardwareBufferHandle) s.imports.releaseBuffer(backHandle,  nullptr);
        return false;
    }
    if (acquireResult != SwapchainResult::kSuccess && acquireResult != SwapchainResult::kSuboptimal) {
        VGLOG_W("acquireNextImage unexpected result=%d", static_cast<int>(acquireResult));
        if (frontHandle != kInvalidHardwareBufferHandle) s.imports.releaseBuffer(frontHandle, nullptr);
        if (backHandle  != kInvalidHardwareBufferHandle) s.imports.releaseBuffer(backHandle,  nullptr);
        return false;
    }

    // Record command buffer: clear pass into the swapchain framebuffer.
    VkCommandBuffer cb = s.commandBuffers[imageIndex];
    vkResetCommandBuffer(cb, 0);

    VkCommandBufferBeginInfo beginInfo{ VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO };
    beginInfo.flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
    vkBeginCommandBuffer(cb, &beginInfo);

    // Render pass — clear the framebuffer to opaque black (Slice 1 proof pass).
    VkClearValue clearColor{};
    clearColor.color = {{0.0f, 0.0f, 0.0f, 1.0f}};

    uint64_t rpHandle = s.swapchain.getRenderPassHandle();
    uint64_t fbHandle = s.swapchain.getFramebufferHandle(imageIndex);

    if (rpHandle != 0 && fbHandle != 0) {
        VkRenderPass  rp{}; std::memcpy(&rp, &rpHandle, sizeof(VkRenderPass));
        VkFramebuffer fb{}; std::memcpy(&fb, &fbHandle, sizeof(VkFramebuffer));

        const uint32_t w = s.swapchain.getExtentWidth();
        const uint32_t h = s.swapchain.getExtentHeight();

        VkRenderPassBeginInfo rpBegin{ VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO };
        rpBegin.renderPass        = rp;
        rpBegin.framebuffer       = fb;
        rpBegin.renderArea.offset = {0, 0};
        rpBegin.renderArea.extent = {w, h};
        rpBegin.clearValueCount   = 1;
        rpBegin.pClearValues      = &clearColor;

        vkCmdBeginRenderPass(cb, &rpBegin, VK_SUBPASS_CONTENTS_INLINE);
        // TODO Slice 3: bind pipeline, descriptor sets, draw imported AHB textures here.
        vkCmdEndRenderPass(cb);
    }

    vkEndCommandBuffer(cb);

    // Submit.
    VkSemaphore renderFinishedSem = s.renderFinishedSemaphores[slot];
    uint64_t renderFinishedHandle = 0;
    std::memcpy(&renderFinishedHandle, &renderFinishedSem, sizeof(uint64_t));

    VkPipelineStageFlags waitStage = VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT;
    VkSubmitInfo submit{ VK_STRUCTURE_TYPE_SUBMIT_INFO };
    submit.waitSemaphoreCount   = 1;
    submit.pWaitSemaphores      = &acquireSem;
    submit.pWaitDstStageMask    = &waitStage;
    submit.commandBufferCount   = 1;
    submit.pCommandBuffers      = &cb;
    submit.signalSemaphoreCount = 1;
    submit.pSignalSemaphores    = &renderFinishedSem;

    // Fence was already reset after vkWaitForFences above; do NOT reset again here.
    if (vkQueueSubmit(s.queue, 1, &submit, fence) != VK_SUCCESS) {
        VGLOG_W("vkQueueSubmit failed");
        if (frontHandle != kInvalidHardwareBufferHandle) s.imports.releaseBuffer(frontHandle, nullptr);
        if (backHandle  != kInvalidHardwareBufferHandle) s.imports.releaseBuffer(backHandle,  nullptr);
        return false;
    }

    // Mark AHB imports as submitted (so retirement queue uses correct slot).
    if (frontHandle != kInvalidHardwareBufferHandle) s.imports.markBufferSubmitted(frontHandle, slot);
    if (backHandle  != kInvalidHardwareBufferHandle) s.imports.markBufferSubmitted(backHandle,  slot);

    // Present.
    SwapchainResult presentResult = s.swapchain.presentImage(
        static_cast<void*>(s.queue), renderFinishedHandle, imageIndex);

    // After GPU completes this slot's fence (next time we wait), drain retired imports.
    // Note: drainRetiredForFrame deferred to next frame's fence wait (approximation acceptable
    // for Slice 1; Slice 3 will use a proper per-slot retired drain after fence wait).

    // Release AHB imports back to retired queue.
    if (frontHandle != kInvalidHardwareBufferHandle) s.imports.releaseBuffer(frontHandle, nullptr);
    if (backHandle  != kInvalidHardwareBufferHandle) s.imports.releaseBuffer(backHandle,  nullptr);

    if (presentResult == SwapchainResult::kOutOfDate ||
        presentResult == SwapchainResult::kSurfaceLost) {
        VGLOG_W("presentImage: swapchain out-of-date after present");
        return false; // Slice 3 will add resize handling.
    }

    return true;
}

// ---------------------------------------------------------------------------
// GLES per-frame composite render (clear + swap — full draw in Slice 3).
// ---------------------------------------------------------------------------
static bool GlesCompositeFrame(GlesDualCamSession& g) {
    if (!eglMakeCurrent(g.display, g.surface, g.surface, g.context)) {
        VGLOG_W("eglMakeCurrent failed in render frame");
        return false;
    }
    // Slice 1 proof: clear to opaque black.
    glClearColor(0.0f, 0.0f, 0.0f, 1.0f);
    glClear(GL_COLOR_BUFFER_BIT);
    // TODO Slice 3: bind GlesMultiCamSpatialCompositor drawSpatialComposite here.
    if (!eglSwapBuffers(g.display, g.surface)) {
        VGLOG_W("eglSwapBuffers failed");
        return false;
    }
    return true;
}

} // anonymous namespace

// ===========================================================================
// JNI entry points
// ===========================================================================

extern "C" {

// ---------------------------------------------------------------------------
// nativeCreateDualCamSession
// ---------------------------------------------------------------------------
JNIEXPORT jlong JNICALL
Java_com_connects_vanguard_1media_1engine_bridge_VanguardNativeBridge_nativeCreateDualCamSession(
    JNIEnv* env, jclass /*cls*/,
    jobject outputSurface, jint width, jint height, jboolean useVulkan)
{
    VGLOG_I("nativeCreateDualCamSession useVulkan=%d width=%d height=%d",
            static_cast<int>(useVulkan), width, height);

    if (!outputSurface) {
        VGLOG_E("outputSurface is null");
        return 0L;
    }

    ANativeWindow* window = ANativeWindow_fromSurface(env, outputSurface);
    if (!window) {
        VGLOG_E("ANativeWindow_fromSurface returned null");
        return 0L;
    }

    auto session = std::make_unique<DualCamSession>();
    session->canvasWidth  = static_cast<uint32_t>(width);
    session->canvasHeight = static_cast<uint32_t>(height);
    session->useVulkan    = static_cast<bool>(useVulkan);

    std::string err;
    bool ok = false;

    if (useVulkan) {
        session->vk = std::make_unique<VulkanDualCamSession>();
        ok = CreateVulkanSession(*session->vk, window, static_cast<uint32_t>(width),
                                 static_cast<uint32_t>(height), err);
        if (!ok) {
            VGLOG_W("Vulkan session creation failed: %s", err.c_str());
            ANativeWindow_release(window);
            return 0L;
        }
    } else {
        session->gles = std::make_unique<GlesDualCamSession>();
        ok = CreateGlesSession(*session->gles, window, err);
        if (!ok) {
            VGLOG_W("GLES session creation failed: %s", err.c_str());
            ANativeWindow_release(window);
            return 0L;
        }
    }

    // The session's sub-session owns the ANativeWindow reference now; release our ref.
    ANativeWindow_release(window);

    jlong handle = reinterpret_cast<jlong>(session.release());
    VGLOG_I("nativeCreateDualCamSession success handle=%lld", static_cast<long long>(handle));
    return handle;
}

// ---------------------------------------------------------------------------
// nativeDualCamCompositeFrame
// ---------------------------------------------------------------------------
JNIEXPORT jboolean JNICALL
Java_com_connects_vanguard_1media_1engine_bridge_VanguardNativeBridge_nativeDualCamCompositeFrame(
    JNIEnv* env, jclass /*cls*/,
    jlong sessionHandle,
    jobject frontHardwareBuffer,
    jobject backHardwareBuffer,
    jstring layoutParamsJson)
{
    if (sessionHandle == 0L) {
        VGLOG_W("nativeDualCamCompositeFrame: null session handle");
        return JNI_FALSE;
    }

    auto* session = reinterpret_cast<DualCamSession*>(sessionHandle);

    // Parse layout JSON.
    ParsedLayoutParams layout;
    if (layoutParamsJson) {
        const char* jsonCStr = env->GetStringUTFChars(layoutParamsJson, nullptr);
        if (jsonCStr) {
            layout = ParseLayoutJson(std::string(jsonCStr));
            env->ReleaseStringUTFChars(layoutParamsJson, jsonCStr);
        }
    }
    if (!layout.ok) {
        VGLOG_W("nativeDualCamCompositeFrame: layout parse failed: %s", layout.rejectionReason.c_str());
        // Fall through with default layout for robustness.
        layout.ok        = true;
        layout.mode      = vanguard::compositors::MultiCamLayoutMode::kPictureInPicture;
        layout.anchor    = vanguard::compositors::MultiCamPiPAnchor::kBottomRight;
        layout.direction = vanguard::compositors::MultiCamSplitDirection::kLeftRight;
    }

    if (session->useVulkan && session->vk && session->vk->isValid()) {
        // Resolve Java HardwareBuffer objects → AHardwareBuffer*.
        static auto fnFromHwBuf = ResolveAHBFromHardwareBuffer();
        AHardwareBuffer* frontAhb = (frontHardwareBuffer && fnFromHwBuf)
            ? fnFromHwBuf(env, frontHardwareBuffer) : nullptr;
        AHardwareBuffer* backAhb  = (backHardwareBuffer && fnFromHwBuf)
            ? fnFromHwBuf(env, backHardwareBuffer) : nullptr;

        bool ok = VulkanCompositeFrame(*session->vk, frontAhb, backAhb, layout);
        return ok ? JNI_TRUE : JNI_FALSE;
    } else if (!session->useVulkan && session->gles && session->gles->isValid()) {
        // GLES path: SurfaceTextures updated Kotlin-side before calling here;
        // native side clears + swaps.
        bool ok = GlesCompositeFrame(*session->gles);
        return ok ? JNI_TRUE : JNI_FALSE;
    }

    VGLOG_W("nativeDualCamCompositeFrame: no valid backend session");
    return JNI_FALSE;
}

// ---------------------------------------------------------------------------
// nativeComputeMultiCamLayout — thin JSON wrapper over ComputeMultiCamLayout().
// ---------------------------------------------------------------------------
JNIEXPORT jstring JNICALL
Java_com_connects_vanguard_1media_1engine_bridge_VanguardNativeBridge_nativeComputeMultiCamLayout(
    JNIEnv* env, jclass /*cls*/,
    jstring layoutParamsJson, jint canvasWidth, jint canvasHeight)
{
    using namespace vanguard::compositors;

    if (!layoutParamsJson) {
        return env->NewStringUTF("{\"error\":\"null_layout_params\"}");
    }
    const char* jsonCStr = env->GetStringUTFChars(layoutParamsJson, nullptr);
    if (!jsonCStr) {
        return env->NewStringUTF("{\"error\":\"get_string_chars_failed\"}");
    }
    ParsedLayoutParams p = ParseLayoutJson(std::string(jsonCStr));
    env->ReleaseStringUTFChars(layoutParamsJson, jsonCStr);

    if (!p.ok) {
        std::string errJson = "{\"error\":\"parse_failed\",\"reason\":\"" + p.rejectionReason + "\"}";
        return env->NewStringUTF(errJson.c_str());
    }

    // Clamp splitRatio and pipWidthFraction to safe ranges.
    const double splitRatio = std::max(0.2, std::min(0.8, p.splitRatio));
    const double pipWidth   = std::max(0.05, std::min(0.95, p.pipWidthFraction));
    const double canvasAr   = (canvasHeight > 0)
        ? static_cast<double>(canvasWidth) / static_cast<double>(canvasHeight)
        : 9.0 / 16.0;

    MultiCamLayout layout{};
    layout.mode         = p.mode;
    layout.canvasWidth  = static_cast<double>(canvasWidth);
    layout.canvasHeight = static_cast<double>(canvasHeight);
    layout.pip.anchor              = p.anchor;
    layout.pip.centerX             = std::max(0.0, std::min(1.0, p.pipCenterX));
    layout.pip.centerY             = std::max(0.0, std::min(1.0, p.pipCenterY));
    layout.pip.normalizedWidth     = pipWidth;
    layout.pip.aspectRatio         = canvasAr;
    layout.pip.marginFraction      = 0.02;
    layout.pip.cornerRadiusFractionOfCanvasWidth = 0.02;
    layout.pip.opacity             = 1.0;
    layout.split.direction         = p.direction;
    layout.split.splitRatio        = splitRatio;

    const MultiCamLayoutResult result = ComputeMultiCamLayout(layout);

    char buf[512];
    std::snprintf(buf, sizeof(buf),
        "{\"primaryViewport\":{\"x\":%.4f,\"y\":%.4f,\"w\":%.4f,\"h\":%.4f},"
        "\"secondaryViewport\":{\"x\":%.4f,\"y\":%.4f,\"w\":%.4f,\"h\":%.4f},"
        "\"secondaryOpacity\":%.4f}",
        result.primaryViewport.x,   result.primaryViewport.y,
        result.primaryViewport.width, result.primaryViewport.height,
        result.secondaryViewport.x,  result.secondaryViewport.y,
        result.secondaryViewport.width, result.secondaryViewport.height,
        result.secondaryOpacity);

    return env->NewStringUTF(buf);
}

// ---------------------------------------------------------------------------
// nativeDestroyDualCamSession
// ---------------------------------------------------------------------------
JNIEXPORT void JNICALL
Java_com_connects_vanguard_1media_1engine_bridge_VanguardNativeBridge_nativeDestroyDualCamSession(
    JNIEnv* /*env*/, jclass /*cls*/,
    jlong sessionHandle)
{
    if (sessionHandle == 0L) {
        VGLOG_W("nativeDestroyDualCamSession: null handle, nothing to do");
        return;
    }
    VGLOG_I("nativeDestroyDualCamSession handle=%lld", static_cast<long long>(sessionHandle));
    auto* session = reinterpret_cast<DualCamSession*>(sessionHandle);
    session->Teardown();
    delete session;
    VGLOG_I("nativeDestroyDualCamSession complete");
}

} // extern "C"

#endif // __ANDROID__
