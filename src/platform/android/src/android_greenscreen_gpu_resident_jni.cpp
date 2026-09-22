// android_greenscreen_gpu_resident_jni.cpp
// ANDROID-GREENSCREEN-GPU-RESIDENT: production JNI surface backing
// AndroidGreenScreenGpuResidentNativeBridge.kt (the native half of
// AndroidGreenScreenGpuResidentPreviewBackend.kt).
//
// Every entry point resolves a jlong handle to a
// GlesGreenScreenGpuResidentRenderer owned by a small process-wide registry
// (mutex held only for the lookup, never across GL work) and fails closed
// (0 / false / no-op) on an unknown handle. The Kotlin owner confines every
// call except nativeDestroy to its single render thread; the registry only
// guards against stale handles after destroy.
//
// Ownership: the renderer owns EGL/GL objects only. The Android Surface
// passed to nativeAttachOutputSurface is borrowed (ANativeWindow acquired for
// the duration of the attach and released on detach/destroy); the
// SurfaceTexture, camera Surface and TFLite interpreter stay in Kotlin.
// Direct ByteBuffers are read/written in place through
// GetDirectBufferAddress; no JNI copies of frame data.

#include <jni.h>

#if defined(__ANDROID__)

#include <android/log.h>
#include <android/native_window.h>
#include <android/native_window_jni.h>

#include <cstdint>
#include <memory>
#include <mutex>
#include <string>
#include <unordered_map>

#include "gles_green_screen_gpu_resident_renderer.h"

#define VG_GS_GPU_RESIDENT_JNI_TAG "VanguardGreenScreenGpuResident"
#define VG_GS_GPU_RESIDENT_JNI_LOGW(...) \
    __android_log_print(ANDROID_LOG_WARN, VG_GS_GPU_RESIDENT_JNI_TAG, __VA_ARGS__)

namespace {

using vanguard::render::GlesGreenScreenGpuResidentRect;
using vanguard::render::GlesGreenScreenGpuResidentRenderer;

struct RendererEntry {
    std::shared_ptr<GlesGreenScreenGpuResidentRenderer> renderer;
    std::string lastError;
};

std::mutex gRegistryMutex;
std::unordered_map<jlong, std::shared_ptr<RendererEntry>> gRegistry;
jlong gNextHandle = 1;

std::shared_ptr<RendererEntry> Lookup(jlong handle) {
    std::lock_guard<std::mutex> lock(gRegistryMutex);
    auto it = gRegistry.find(handle);
    if (it == gRegistry.end()) return nullptr;
    return it->second;
}

void RecordError(const std::shared_ptr<RendererEntry>& entry, const std::string& error) {
    if (!error.empty()) entry->lastError = error;
}

jstring NewJString(JNIEnv* env, const std::string& value) {
    return env->NewStringUTF(value.c_str());
}

}  // namespace

#define VG_GS_GPU_RESIDENT_JNI(ret, name) \
    extern "C" JNIEXPORT ret JNICALL \
    Java_com_connects_vanguard_1media_1engine_greenscreen_AndroidGreenScreenGpuResidentNativeBridge_##name

VG_GS_GPU_RESIDENT_JNI(jlong, nativeCreate)(JNIEnv* /*env*/, jobject /*thiz*/) {
    auto entry = std::make_shared<RendererEntry>();
    entry->renderer = std::make_shared<GlesGreenScreenGpuResidentRenderer>();
    std::string error;
    if (!entry->renderer->Initialize(&error)) {
        VG_GS_GPU_RESIDENT_JNI_LOGW("ANDROID_GREENSCREEN_GPU_RESIDENT_NATIVE_CREATE_FAILED %s", error.c_str());
        entry->renderer->Destroy();
        return 0;
    }
    std::lock_guard<std::mutex> lock(gRegistryMutex);
    const jlong handle = gNextHandle++;
    gRegistry[handle] = entry;
    return handle;
}

VG_GS_GPU_RESIDENT_JNI(void, nativeDestroy)(JNIEnv* /*env*/, jobject /*thiz*/, jlong handle) {
    std::shared_ptr<RendererEntry> entry;
    {
        std::lock_guard<std::mutex> lock(gRegistryMutex);
        auto it = gRegistry.find(handle);
        if (it == gRegistry.end()) return;
        entry = it->second;
        gRegistry.erase(it);
    }
    entry->renderer->Destroy();
}

VG_GS_GPU_RESIDENT_JNI(jboolean, nativeMakeCurrent)(JNIEnv* /*env*/, jobject /*thiz*/, jlong handle) {
    auto entry = Lookup(handle);
    if (!entry) return JNI_FALSE;
    return entry->renderer->MakeCurrent() ? JNI_TRUE : JNI_FALSE;
}

VG_GS_GPU_RESIDENT_JNI(jint, nativeGetCameraTextureId)(JNIEnv* /*env*/, jobject /*thiz*/, jlong handle) {
    auto entry = Lookup(handle);
    if (!entry) return 0;
    return static_cast<jint>(entry->renderer->CameraTextureId());
}

VG_GS_GPU_RESIDENT_JNI(jboolean, nativeConfigureModelInput)(
    JNIEnv* /*env*/, jobject /*thiz*/, jlong handle, jint width, jint height) {
    auto entry = Lookup(handle);
    if (!entry) return JNI_FALSE;
    std::string error;
    const bool ok = entry->renderer->MakeCurrent() &&
                    entry->renderer->ConfigureModelInput(width, height, &error);
    RecordError(entry, error);
    return ok ? JNI_TRUE : JNI_FALSE;
}

VG_GS_GPU_RESIDENT_JNI(jboolean, nativeAttachOutputSurface)(
    JNIEnv* env, jobject /*thiz*/, jlong handle, jobject surface, jint widthPx, jint heightPx) {
    auto entry = Lookup(handle);
    if (!entry || surface == nullptr) return JNI_FALSE;
    ANativeWindow* window = ANativeWindow_fromSurface(env, surface);
    if (window == nullptr) {
        RecordError(entry, "ANativeWindow_fromSurface returned null");
        return JNI_FALSE;
    }
    std::string error;
    const bool ok = entry->renderer->AttachOutputWindow(window, widthPx, heightPx, &error);
    // The renderer acquired its own reference on success; drop the JNI one.
    ANativeWindow_release(window);
    RecordError(entry, error);
    return ok ? JNI_TRUE : JNI_FALSE;
}

VG_GS_GPU_RESIDENT_JNI(void, nativeDetachOutputSurface)(JNIEnv* /*env*/, jobject /*thiz*/, jlong handle) {
    auto entry = Lookup(handle);
    if (!entry) return;
    entry->renderer->DetachOutputWindow();
}

VG_GS_GPU_RESIDENT_JNI(void, nativeSetLayout)(
    JNIEnv* /*env*/, jobject /*thiz*/, jlong handle,
    jfloat sourceLeft, jfloat sourceTop, jfloat sourceWidth, jfloat sourceHeight,
    jfloat cameraLeft, jfloat cameraTop, jfloat cameraWidth, jfloat cameraHeight) {
    auto entry = Lookup(handle);
    if (!entry) return;
    GlesGreenScreenGpuResidentRect source;
    source.left = sourceLeft;
    source.top = sourceTop;
    source.width = sourceWidth;
    source.height = sourceHeight;
    GlesGreenScreenGpuResidentRect camera;
    camera.left = cameraLeft;
    camera.top = cameraTop;
    camera.width = cameraWidth;
    camera.height = cameraHeight;
    entry->renderer->SetLayout(source, camera);
}

VG_GS_GPU_RESIDENT_JNI(void, nativeSetCameraTransform)(
    JNIEnv* env, jobject /*thiz*/, jlong handle, jfloatArray stMatrix, jfloat cameraUprightAspect) {
    auto entry = Lookup(handle);
    if (!entry || stMatrix == nullptr) return;
    if (env->GetArrayLength(stMatrix) < 16) return;
    float matrix[16];
    env->GetFloatArrayRegion(stMatrix, 0, 16, matrix);
    entry->renderer->SetCameraTransform(matrix, cameraUprightAspect);
}

VG_GS_GPU_RESIDENT_JNI(void, nativeSetBackgroundBlack)(JNIEnv* /*env*/, jobject /*thiz*/, jlong handle) {
    auto entry = Lookup(handle);
    if (!entry) return;
    entry->renderer->SetBackgroundBlack();
}

VG_GS_GPU_RESIDENT_JNI(void, nativeSetBackgroundSolidColor)(
    JNIEnv* /*env*/, jobject /*thiz*/, jlong handle, jint argb) {
    auto entry = Lookup(handle);
    if (!entry) return;
    entry->renderer->SetBackgroundSolidColor(static_cast<uint32_t>(argb));
}

VG_GS_GPU_RESIDENT_JNI(jboolean, nativeSetBackgroundImage)(
    JNIEnv* env, jobject /*thiz*/, jlong handle, jobject rgba, jint width, jint height, jboolean aspectFill) {
    auto entry = Lookup(handle);
    if (!entry || rgba == nullptr || width <= 0 || height <= 0) return JNI_FALSE;
    const uint8_t* pixels = static_cast<const uint8_t*>(env->GetDirectBufferAddress(rgba));
    const jlong capacity = env->GetDirectBufferCapacity(rgba);
    const jlong required = static_cast<jlong>(width) * static_cast<jlong>(height) * 4;
    if (pixels == nullptr || capacity < required) {
        RecordError(entry, "background image buffer is not direct or too small");
        return JNI_FALSE;
    }
    std::string error;
    const bool ok = entry->renderer->SetBackgroundImage(pixels, width, height, aspectFill == JNI_TRUE, &error);
    RecordError(entry, error);
    return ok ? JNI_TRUE : JNI_FALSE;
}

VG_GS_GPU_RESIDENT_JNI(void, nativeSetBackgroundImageScaleMode)(
    JNIEnv* /*env*/, jobject /*thiz*/, jlong handle, jboolean aspectFill) {
    auto entry = Lookup(handle);
    if (!entry) return;
    entry->renderer->SetBackgroundImageScaleMode(aspectFill == JNI_TRUE);
}

VG_GS_GPU_RESIDENT_JNI(void, nativeClearBackgroundImage)(JNIEnv* /*env*/, jobject /*thiz*/, jlong handle) {
    auto entry = Lookup(handle);
    if (!entry) return;
    entry->renderer->ClearBackgroundImage();
}

VG_GS_GPU_RESIDENT_JNI(void, nativeSetFilterToggles)(
    JNIEnv* /*env*/, jobject /*thiz*/, jlong handle, jboolean guidedFilter, jboolean temporalStabilizer,
    jboolean despill) {
    auto entry = Lookup(handle);
    if (!entry) return;
    entry->renderer->SetFilterToggles(guidedFilter == JNI_TRUE, temporalStabilizer == JNI_TRUE,
                                      despill == JNI_TRUE);
}

VG_GS_GPU_RESIDENT_JNI(jboolean, nativeDownscaleCameraToModelInput)(
    JNIEnv* env, jobject /*thiz*/, jlong handle, jobject modelInput) {
    auto entry = Lookup(handle);
    if (!entry || modelInput == nullptr) return JNI_FALSE;
    float* out = static_cast<float*>(env->GetDirectBufferAddress(modelInput));
    const jlong capacity = env->GetDirectBufferCapacity(modelInput);
    if (out == nullptr || capacity <= 0) {
        RecordError(entry, "model input buffer is not direct");
        return JNI_FALSE;
    }
    std::string error;
    const bool ok = entry->renderer->DownscaleCameraToModelInput(
        out, static_cast<size_t>(capacity) / sizeof(float), &error);
    RecordError(entry, error);
    return ok ? JNI_TRUE : JNI_FALSE;
}

VG_GS_GPU_RESIDENT_JNI(jboolean, nativeUploadCoarseMask)(
    JNIEnv* env, jobject /*thiz*/, jlong handle, jobject mask, jint width, jint height) {
    auto entry = Lookup(handle);
    if (!entry || mask == nullptr) return JNI_FALSE;
    const float* data = static_cast<const float*>(env->GetDirectBufferAddress(mask));
    const jlong capacity = env->GetDirectBufferCapacity(mask);
    if (data == nullptr || capacity <= 0) {
        RecordError(entry, "mask buffer is not direct");
        return JNI_FALSE;
    }
    std::string error;
    const bool ok = entry->renderer->UploadCoarseMask(
        data, static_cast<size_t>(capacity) / sizeof(float), width, height, &error);
    RecordError(entry, error);
    return ok ? JNI_TRUE : JNI_FALSE;
}

VG_GS_GPU_RESIDENT_JNI(jboolean, nativeRenderFrame)(
    JNIEnv* /*env*/, jobject /*thiz*/, jlong handle, jint cameraMode, jboolean refineMask) {
    auto entry = Lookup(handle);
    if (!entry) return JNI_FALSE;
    GlesGreenScreenGpuResidentRenderer::CameraMode mode;
    switch (cameraMode) {
        case 1: mode = GlesGreenScreenGpuResidentRenderer::CameraMode::kPlaceholder; break;
        case 2: mode = GlesGreenScreenGpuResidentRenderer::CameraMode::kPassthrough; break;
        case 3: mode = GlesGreenScreenGpuResidentRenderer::CameraMode::kMasked; break;
        default: mode = GlesGreenScreenGpuResidentRenderer::CameraMode::kNone; break;
    }
    std::string error;
    const bool ok = entry->renderer->RenderFrame(mode, refineMask == JNI_TRUE, &error);
    RecordError(entry, error);
    return ok ? JNI_TRUE : JNI_FALSE;
}

VG_GS_GPU_RESIDENT_JNI(jstring, nativeStatsSummary)(JNIEnv* env, jobject /*thiz*/, jlong handle) {
    auto entry = Lookup(handle);
    if (!entry) return NewJString(env, "unknown_handle");
    return NewJString(env, entry->renderer->StatsSummary());
}

VG_GS_GPU_RESIDENT_JNI(jstring, nativeLastError)(JNIEnv* env, jobject /*thiz*/, jlong handle) {
    auto entry = Lookup(handle);
    if (!entry) return NewJString(env, "unknown_handle");
    return NewJString(env, entry->lastError);
}

#endif  // defined(__ANDROID__)
