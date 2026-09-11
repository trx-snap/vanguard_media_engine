#include <jni.h>
#include <android/native_window_jni.h>
#include <android/native_window.h>
#include <android/hardware_buffer.h>
#include "vanguard/android/android_duet_vulkan_preview_session.h"
#include <dlfcn.h>
#include <mutex>
#include <unordered_map>
#include <atomic>
#include <memory>

using vanguard::android::AndroidDuetVulkanPreviewSession;

namespace {
    std::atomic<jlong> gNextSessionId{1};
    std::mutex gSessionMutex;
    std::unordered_map<jlong, std::shared_ptr<AndroidDuetVulkanPreviewSession>> gSessions;

    std::shared_ptr<AndroidDuetVulkanPreviewSession> GetSession(jlong handle) {
        std::lock_guard<std::mutex> lock(gSessionMutex);
        auto it = gSessions.find(handle);
        if (it != gSessions.end()) {
            return it->second;
        }
        return nullptr;
    }

    // AHardwareBuffer_fromHardwareBuffer is resolved via dlopen/dlsym (rather
    // than linked directly) to match this codebase's established pattern for
    // this NDK symbol (see e.g. android_phase4b1_texture_playback_jni.cpp).
    using FnAHardwareBuffer_fromHardwareBuffer = AHardwareBuffer* (*)(JNIEnv*, jobject);

    AHardwareBuffer* ResolveAHardwareBufferFromJObject(JNIEnv* env, jobject jHwBuf) {
        if (!jHwBuf) return nullptr;
        void* lib = dlopen("libandroid.so", RTLD_NOW | RTLD_LOCAL);
        if (!lib) return nullptr;
        auto fn = reinterpret_cast<FnAHardwareBuffer_fromHardwareBuffer>(
            dlsym(lib, "AHardwareBuffer_fromHardwareBuffer"));
        AHardwareBuffer* buf = fn ? fn(env, jHwBuf) : nullptr;
        dlclose(lib);
        return buf;
    }

    jboolean UpdateMaskImpl(
        JNIEnv* env, jlong handle, jobject maskBytes, jint width, jint height) {
        if (!maskBytes || width <= 0 || height <= 0) {
            return JNI_FALSE;
        }

        auto session = GetSession(handle);
        if (!session) {
            return JNI_FALSE;
        }

        void* address = env->GetDirectBufferAddress(maskBytes);
        const jlong capacity = env->GetDirectBufferCapacity(maskBytes);
        if (!address || capacity <= 0) {
            return JNI_FALSE;
        }

        const bool ok = session->UpdateMask(
            static_cast<const uint8_t*>(address), static_cast<size_t>(capacity),
            static_cast<uint32_t>(width), static_cast<uint32_t>(height));
        return ok ? JNI_TRUE : JNI_FALSE;
    }

    // ANDROID-DUET-VULKAN-LAYOUT: greenScreenEnabled selects the session's
    // mask-composite path (rects ignored) or the opaque two-layer layout path
    // (decoder aspect-filled into the source rect, camera into the camera
    // rect). Rects are canvas pixel rects already rounded / clamped by the
    // Kotlin compositor; a non-positive layout rect size fails closed here
    // without touching the session.
    jboolean RenderFrameImpl(
        JNIEnv* env, jlong handle, jobject decoderHardwareBuffer, jobject cameraHardwareBuffer,
        jboolean greenScreenEnabled,
        jint sourceX, jint sourceY, jint sourceWidth, jint sourceHeight,
        jint cameraX, jint cameraY, jint cameraWidth, jint cameraHeight) {
        if (!decoderHardwareBuffer || !cameraHardwareBuffer) {
            return JNI_FALSE;
        }
        const bool layoutMode = greenScreenEnabled == JNI_FALSE;
        if (layoutMode &&
            (sourceWidth <= 0 || sourceHeight <= 0 || cameraWidth <= 0 || cameraHeight <= 0)) {
            return JNI_FALSE;
        }

        auto session = GetSession(handle);
        if (!session) {
            return JNI_FALSE;
        }

        AHardwareBuffer* decoderBuffer = ResolveAHardwareBufferFromJObject(env, decoderHardwareBuffer);
        if (!decoderBuffer) {
            return JNI_FALSE;
        }
        AHardwareBuffer* cameraBuffer = ResolveAHardwareBufferFromJObject(env, cameraHardwareBuffer);
        if (!cameraBuffer) {
            return JNI_FALSE;
        }

        vanguard::android::AndroidDuetVulkanPreviewLayoutRect sourceRect;
        sourceRect.x = static_cast<int32_t>(sourceX);
        sourceRect.y = static_cast<int32_t>(sourceY);
        sourceRect.width = static_cast<int32_t>(sourceWidth);
        sourceRect.height = static_cast<int32_t>(sourceHeight);
        vanguard::android::AndroidDuetVulkanPreviewLayoutRect cameraRect;
        cameraRect.x = static_cast<int32_t>(cameraX);
        cameraRect.y = static_cast<int32_t>(cameraY);
        cameraRect.width = static_cast<int32_t>(cameraWidth);
        cameraRect.height = static_cast<int32_t>(cameraHeight);

        const bool ok = session->RenderFrame(
            static_cast<void*>(decoderBuffer), static_cast<void*>(cameraBuffer),
            !layoutMode, sourceRect, cameraRect);
        return ok ? JNI_TRUE : JNI_FALSE;
    }

    jlong CreateSessionImpl() {
        auto session = std::make_shared<AndroidDuetVulkanPreviewSession>();
        if (!session->Initialize()) {
            return 0;
        }

        jlong handle = gNextSessionId.fetch_add(1);
        std::lock_guard<std::mutex> lock(gSessionMutex);
        gSessions[handle] = std::move(session);
        return handle;
    }

    jboolean AttachSurfaceImpl(
        JNIEnv* env, jlong handle, jobject surface, jint widthPx, jint heightPx) {
        if (!surface || widthPx <= 0 || heightPx <= 0) {
            return JNI_FALSE;
        }

        auto session = GetSession(handle);
        if (!session) {
            return JNI_FALSE;
        }

        ANativeWindow* window = ANativeWindow_fromSurface(env, surface);
        if (!window) {
            return JNI_FALSE;
        }

        bool result = session->AttachSurface(window, static_cast<uint32_t>(widthPx), static_cast<uint32_t>(heightPx));
        ANativeWindow_release(window);

        return result ? JNI_TRUE : JNI_FALSE;
    }

    void DetachSurfaceImpl(jlong handle) {
        auto session = GetSession(handle);
        if (session) {
            session->DetachSurface();
        }
    }

    void DestroySessionImpl(jlong handle) {
        std::shared_ptr<AndroidDuetVulkanPreviewSession> toDestroy;
        {
            std::lock_guard<std::mutex> lock(gSessionMutex);
            auto it = gSessions.find(handle);
            if (it != gSessions.end()) {
                toDestroy = std::move(it->second);
                gSessions.erase(it);
            }
        }
        // toDestroy released outside lock
    }
}

// ---------------------------------------------------------------------------
// Companion object JNI bindings (default Kotlin companion method naming)
// ---------------------------------------------------------------------------
extern "C" JNIEXPORT jlong JNICALL
Java_com_connects_vanguard_1media_1engine_bridge_VanguardNativeBridge_00024Companion_createAndroidDuetVulkanPreviewSession(
    JNIEnv* /*env*/, jobject /*companion*/) {
    return CreateSessionImpl();
}

extern "C" JNIEXPORT jboolean JNICALL
Java_com_connects_vanguard_1media_1engine_bridge_VanguardNativeBridge_00024Companion_attachAndroidDuetVulkanPreviewSurface(
    JNIEnv* env, jobject /*companion*/, jlong handle, jobject surface, jint widthPx, jint heightPx) {
    return AttachSurfaceImpl(env, handle, surface, widthPx, heightPx);
}

extern "C" JNIEXPORT void JNICALL
Java_com_connects_vanguard_1media_1engine_bridge_VanguardNativeBridge_00024Companion_detachAndroidDuetVulkanPreviewSurface(
    JNIEnv* /*env*/, jobject /*companion*/, jlong handle) {
    DetachSurfaceImpl(handle);
}

extern "C" JNIEXPORT void JNICALL
Java_com_connects_vanguard_1media_1engine_bridge_VanguardNativeBridge_00024Companion_destroyAndroidDuetVulkanPreviewSession(
    JNIEnv* /*env*/, jobject /*companion*/, jlong handle) {
    DestroySessionImpl(handle);
}

extern "C" JNIEXPORT jboolean JNICALL
Java_com_connects_vanguard_1media_1engine_bridge_VanguardNativeBridge_00024Companion_updateAndroidDuetVulkanPreviewMask(
    JNIEnv* env, jobject /*companion*/, jlong handle, jobject maskBytes, jint width, jint height) {
    return UpdateMaskImpl(env, handle, maskBytes, width, height);
}

extern "C" JNIEXPORT jboolean JNICALL
Java_com_connects_vanguard_1media_1engine_bridge_VanguardNativeBridge_00024Companion_renderAndroidDuetVulkanPreviewFrame(
    JNIEnv* env, jobject /*companion*/, jlong handle, jobject decoderHardwareBuffer, jobject cameraHardwareBuffer,
    jboolean greenScreenEnabled,
    jint sourceX, jint sourceY, jint sourceWidth, jint sourceHeight,
    jint cameraX, jint cameraY, jint cameraWidth, jint cameraHeight) {
    return RenderFrameImpl(env, handle, decoderHardwareBuffer, cameraHardwareBuffer,
                           greenScreenEnabled,
                           sourceX, sourceY, sourceWidth, sourceHeight,
                           cameraX, cameraY, cameraWidth, cameraHeight);
}

// ---------------------------------------------------------------------------
// Class-level JNI bindings (for @JvmStatic or direct class resolution)
// ---------------------------------------------------------------------------
extern "C" JNIEXPORT jlong JNICALL
Java_com_connects_vanguard_1media_1engine_bridge_VanguardNativeBridge_createAndroidDuetVulkanPreviewSession(
    JNIEnv* /*env*/, jclass /*clazz*/) {
    return CreateSessionImpl();
}

extern "C" JNIEXPORT jboolean JNICALL
Java_com_connects_vanguard_1media_1engine_bridge_VanguardNativeBridge_attachAndroidDuetVulkanPreviewSurface(
    JNIEnv* env, jclass /*clazz*/, jlong handle, jobject surface, jint widthPx, jint heightPx) {
    return AttachSurfaceImpl(env, handle, surface, widthPx, heightPx);
}

extern "C" JNIEXPORT void JNICALL
Java_com_connects_vanguard_1media_1engine_bridge_VanguardNativeBridge_detachAndroidDuetVulkanPreviewSurface(
    JNIEnv* /*env*/, jclass /*clazz*/, jlong handle) {
    DetachSurfaceImpl(handle);
}

extern "C" JNIEXPORT void JNICALL
Java_com_connects_vanguard_1media_1engine_bridge_VanguardNativeBridge_destroyAndroidDuetVulkanPreviewSession(
    JNIEnv* /*env*/, jclass /*clazz*/, jlong handle) {
    DestroySessionImpl(handle);
}

extern "C" JNIEXPORT jboolean JNICALL
Java_com_connects_vanguard_1media_1engine_bridge_VanguardNativeBridge_updateAndroidDuetVulkanPreviewMask(
    JNIEnv* env, jclass /*clazz*/, jlong handle, jobject maskBytes, jint width, jint height) {
    return UpdateMaskImpl(env, handle, maskBytes, width, height);
}

extern "C" JNIEXPORT jboolean JNICALL
Java_com_connects_vanguard_1media_1engine_bridge_VanguardNativeBridge_renderAndroidDuetVulkanPreviewFrame(
    JNIEnv* env, jclass /*clazz*/, jlong handle, jobject decoderHardwareBuffer, jobject cameraHardwareBuffer,
    jboolean greenScreenEnabled,
    jint sourceX, jint sourceY, jint sourceWidth, jint sourceHeight,
    jint cameraX, jint cameraY, jint cameraWidth, jint cameraHeight) {
    return RenderFrameImpl(env, handle, decoderHardwareBuffer, cameraHardwareBuffer,
                           greenScreenEnabled,
                           sourceX, sourceY, sourceWidth, sourceHeight,
                           cameraX, cameraY, cameraWidth, cameraHeight);
}
