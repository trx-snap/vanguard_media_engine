#include <jni.h>
#include <android/native_window_jni.h>
#include <android/native_window.h>
#include "vanguard/android/android_duet_vulkan_preview_session.h"
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
