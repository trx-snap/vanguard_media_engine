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
// Ownership: the renderer owns EGL/GL objects only. The Android Surfaces
// passed to nativeAttachOutputSurface and nativeAttachRecorderSurface are
// borrowed (ANativeWindow acquired for the duration of the attach and
// released on detach/destroy); the SurfaceTexture, camera Surface, recorder
// MediaCodec/Surface and TFLite interpreter stay in Kotlin.
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
#include "gles_green_screen_gpu_segmenter.h"

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

// Kotlin camera-mode int (AndroidGreenScreenGpuResidentPreviewBackend
// CAMERA_MODE_*) -> renderer enum; unknown values fail closed to kNone.
GlesGreenScreenGpuResidentRenderer::CameraMode ToCameraMode(jint cameraMode) {
    switch (cameraMode) {
        case 1: return GlesGreenScreenGpuResidentRenderer::CameraMode::kPlaceholder;
        case 2: return GlesGreenScreenGpuResidentRenderer::CameraMode::kPassthrough;
        case 3: return GlesGreenScreenGpuResidentRenderer::CameraMode::kMasked;
        default: return GlesGreenScreenGpuResidentRenderer::CameraMode::kNone;
    }
}

// nativeRenderFrameCapturing result bits (mirrored by the Kotlin backend).
constexpr jint kRenderFrameSwappedBit = 1;
constexpr jint kRenderFrameCapturedBit = 2;

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

// ---------------------------------------------------------------------------
// VG-LIVE-GREENSCREEN-RECORDING: secondary encoder window surface. The
// recorder's MediaCodec input Surface is borrowed exactly like the output
// Surface above; the renderer acquires its own ANativeWindow reference for
// the duration of the attach and never releases the Surface itself.
// ---------------------------------------------------------------------------

VG_GS_GPU_RESIDENT_JNI(jboolean, nativeAttachRecorderSurface)(
    JNIEnv* env, jobject /*thiz*/, jlong handle, jobject surface, jint widthPx, jint heightPx) {
    auto entry = Lookup(handle);
    if (!entry || surface == nullptr) return JNI_FALSE;
    ANativeWindow* window = ANativeWindow_fromSurface(env, surface);
    if (window == nullptr) {
        RecordError(entry, "ANativeWindow_fromSurface(recorder) returned null");
        return JNI_FALSE;
    }
    std::string error;
    const bool ok = entry->renderer->AttachRecorderWindow(window, widthPx, heightPx, &error);
    // The renderer acquired its own reference on success; drop the JNI one.
    ANativeWindow_release(window);
    RecordError(entry, error);
    return ok ? JNI_TRUE : JNI_FALSE;
}

VG_GS_GPU_RESIDENT_JNI(void, nativeDetachRecorderSurface)(JNIEnv* /*env*/, jobject /*thiz*/, jlong handle) {
    auto entry = Lookup(handle);
    if (!entry) return;
    entry->renderer->DetachRecorderWindow();
}

// Returns GlesGreenScreenGpuResidentRenderer::RecorderFrameStatus as an int
// (0 submitted, 1 skipped, 2 failed). An unknown handle fails closed as 2 so
// the Kotlin owner detaches the recorder instead of feeding a dead renderer.
VG_GS_GPU_RESIDENT_JNI(jint, nativeRenderRecorderFrame)(
    JNIEnv* /*env*/, jobject /*thiz*/, jlong handle, jlong presentationTimeNs) {
    auto entry = Lookup(handle);
    if (!entry) return static_cast<jint>(GlesGreenScreenGpuResidentRenderer::RecorderFrameStatus::kFailed);
    std::string error;
    const auto status = entry->renderer->RenderRecorderFrame(static_cast<int64_t>(presentationTimeNs), &error);
    RecordError(entry, error);
    return static_cast<jint>(status);
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

VG_GS_GPU_RESIDENT_JNI(jint, nativeGetBackgroundVideoTextureId)(JNIEnv* /*env*/, jobject /*thiz*/, jlong handle) {
    auto entry = Lookup(handle);
    if (!entry) return 0;
    std::string error;
    const uint32_t texId = entry->renderer->EnsureBackgroundVideoTexture(&error);
    RecordError(entry, error);
    return static_cast<jint>(texId);
}

VG_GS_GPU_RESIDENT_JNI(void, nativeSetBackgroundVideoFrame)(
    JNIEnv* env, jobject /*thiz*/, jlong handle, jfloatArray stMatrix, jint videoWidth, jint videoHeight,
    jint rotationDegrees, jboolean aspectFill) {
    auto entry = Lookup(handle);
    if (!entry || stMatrix == nullptr) return;
    if (env->GetArrayLength(stMatrix) < 16) return;
    float matrix[16];
    env->GetFloatArrayRegion(stMatrix, 0, 16, matrix);
    entry->renderer->SetBackgroundVideoFrame(matrix, videoWidth, videoHeight, rotationDegrees, aspectFill == JNI_TRUE);
}

VG_GS_GPU_RESIDENT_JNI(void, nativeClearBackgroundVideo)(JNIEnv* /*env*/, jobject /*thiz*/, jlong handle) {
    auto entry = Lookup(handle);
    if (!entry) return;
    entry->renderer->ClearBackgroundVideo();
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
    std::string error;
    const bool ok = entry->renderer->RenderFrame(ToCameraMode(cameraMode), refineMask == JNI_TRUE, &error);
    RecordError(entry, error);
    return ok ? JNI_TRUE : JNI_FALSE;
}

// VG-LIVE-GREENSCREEN-PHOTO: nativeRenderFrame plus a one-shot read-back of
// the presented composite into the direct buffer rgbaOut (RGBA8, GL
// bottom-left row order, capacity >= outputWidth*outputHeight*4). Returns a
// bitmask: bit 0 = swapped (the nativeRenderFrame result), bit 1 = captured.
// The frame is always rendered/presented; a missing or non-direct buffer
// only fails the capture bit (reason in nativeLastError), never the preview.
VG_GS_GPU_RESIDENT_JNI(jint, nativeRenderFrameCapturing)(
    JNIEnv* env, jobject /*thiz*/, jlong handle, jint cameraMode, jboolean refineMask, jobject rgbaOut) {
    auto entry = Lookup(handle);
    if (!entry) return 0;
    const auto mode = ToCameraMode(cameraMode);
    uint8_t* out = nullptr;
    jlong capacity = 0;
    if (rgbaOut != nullptr) {
        out = static_cast<uint8_t*>(env->GetDirectBufferAddress(rgbaOut));
        capacity = env->GetDirectBufferCapacity(rgbaOut);
    }
    if (out == nullptr || capacity <= 0) {
        RecordError(entry, "composite capture buffer is missing or not direct");
        std::string error;
        const bool swapped = entry->renderer->RenderFrame(mode, refineMask == JNI_TRUE, &error);
        RecordError(entry, error);
        return swapped ? kRenderFrameSwappedBit : 0;
    }
    std::string error;
    bool captured = false;
    const bool swapped = entry->renderer->RenderFrameCapturing(
        mode, refineMask == JNI_TRUE, out, static_cast<size_t>(capacity), &captured, &error);
    RecordError(entry, error);
    return (swapped ? kRenderFrameSwappedBit : 0) | (captured ? kRenderFrameCapturedBit : 0);
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

// ---------------------------------------------------------------------------
// ANDROID-GREENSCREEN-GPU-SEGMENTER: embeddable segmenter surface
// (GlesGreenScreenGpuSegmenter) for a host compositor that owns its own EGL
// context, camera OES texture and final draw (AndroidDuetPreviewCompositor).
// Separate handle registry from the standalone renderer above; every call
// except nativeSegmenterCreate/Destroy is a thin forward and requires the
// host's ES 3.1 context to be current on the calling (render) thread. The
// camera OES texture is passed per call and never owned here.
// ---------------------------------------------------------------------------

namespace {

using vanguard::render::GlesGreenScreenGpuSegmenter;

struct SegmenterEntry {
    std::shared_ptr<GlesGreenScreenGpuSegmenter> segmenter;
    std::string lastError;
};

std::mutex gSegmenterRegistryMutex;
std::unordered_map<jlong, std::shared_ptr<SegmenterEntry>> gSegmenterRegistry;
jlong gNextSegmenterHandle = 1;

std::shared_ptr<SegmenterEntry> LookupSegmenter(jlong handle) {
    std::lock_guard<std::mutex> lock(gSegmenterRegistryMutex);
    auto it = gSegmenterRegistry.find(handle);
    if (it == gSegmenterRegistry.end()) return nullptr;
    return it->second;
}

void RecordSegmenterError(const std::shared_ptr<SegmenterEntry>& entry, const std::string& error) {
    if (!error.empty()) entry->lastError = error;
}

}  // namespace

VG_GS_GPU_RESIDENT_JNI(jlong, nativeSegmenterCreate)(JNIEnv* /*env*/, jobject /*thiz*/) {
    auto entry = std::make_shared<SegmenterEntry>();
    entry->segmenter = std::make_shared<GlesGreenScreenGpuSegmenter>();
    std::string error;
    if (!entry->segmenter->Initialize(&error)) {
        VG_GS_GPU_RESIDENT_JNI_LOGW("ANDROID_GREENSCREEN_GPU_SEGMENTER_NATIVE_CREATE_FAILED %s", error.c_str());
        entry->segmenter->Destroy();
        return 0;
    }
    std::lock_guard<std::mutex> lock(gSegmenterRegistryMutex);
    const jlong handle = gNextSegmenterHandle++;
    gSegmenterRegistry[handle] = entry;
    return handle;
}

VG_GS_GPU_RESIDENT_JNI(void, nativeSegmenterDestroy)(JNIEnv* /*env*/, jobject /*thiz*/, jlong handle) {
    std::shared_ptr<SegmenterEntry> entry;
    {
        std::lock_guard<std::mutex> lock(gSegmenterRegistryMutex);
        auto it = gSegmenterRegistry.find(handle);
        if (it == gSegmenterRegistry.end()) return;
        entry = it->second;
        gSegmenterRegistry.erase(it);
    }
    entry->segmenter->Destroy();
}

VG_GS_GPU_RESIDENT_JNI(jboolean, nativeSegmenterConfigureModelInput)(
    JNIEnv* /*env*/, jobject /*thiz*/, jlong handle, jint width, jint height) {
    auto entry = LookupSegmenter(handle);
    if (!entry) return JNI_FALSE;
    std::string error;
    const bool ok = entry->segmenter->ConfigureModelInput(width, height, &error);
    RecordSegmenterError(entry, error);
    return ok ? JNI_TRUE : JNI_FALSE;
}

VG_GS_GPU_RESIDENT_JNI(void, nativeSegmenterSetCameraTransform)(
    JNIEnv* env, jobject /*thiz*/, jlong handle, jfloatArray stMatrix, jfloat cameraUprightAspect) {
    auto entry = LookupSegmenter(handle);
    if (!entry || stMatrix == nullptr) return;
    if (env->GetArrayLength(stMatrix) < 16) return;
    float matrix[16];
    env->GetFloatArrayRegion(stMatrix, 0, 16, matrix);
    entry->segmenter->SetCameraTransform(matrix, cameraUprightAspect);
}

VG_GS_GPU_RESIDENT_JNI(void, nativeSegmenterSetAlphaTargetSize)(
    JNIEnv* /*env*/, jobject /*thiz*/, jlong handle, jint outputWidthPx, jint outputHeightPx) {
    auto entry = LookupSegmenter(handle);
    if (!entry) return;
    entry->segmenter->SetAlphaTargetSize(outputWidthPx, outputHeightPx);
}

VG_GS_GPU_RESIDENT_JNI(void, nativeSegmenterSetFilterToggles)(
    JNIEnv* /*env*/, jobject /*thiz*/, jlong handle, jboolean guidedFilter, jboolean temporalStabilizer) {
    auto entry = LookupSegmenter(handle);
    if (!entry) return;
    entry->segmenter->SetFilterToggles(guidedFilter == JNI_TRUE, temporalStabilizer == JNI_TRUE);
}

VG_GS_GPU_RESIDENT_JNI(jboolean, nativeSegmenterDownscaleCameraToModelInput)(
    JNIEnv* env, jobject /*thiz*/, jlong handle, jint cameraOesTexture, jobject modelInput) {
    auto entry = LookupSegmenter(handle);
    if (!entry || modelInput == nullptr) return JNI_FALSE;
    float* out = static_cast<float*>(env->GetDirectBufferAddress(modelInput));
    const jlong capacity = env->GetDirectBufferCapacity(modelInput);
    if (out == nullptr || capacity <= 0) {
        RecordSegmenterError(entry, "model input buffer is not direct");
        return JNI_FALSE;
    }
    std::string error;
    const bool ok = entry->segmenter->DownscaleCameraToModelInput(
        static_cast<uint32_t>(cameraOesTexture), out, static_cast<size_t>(capacity) / sizeof(float), &error);
    RecordSegmenterError(entry, error);
    return ok ? JNI_TRUE : JNI_FALSE;
}

VG_GS_GPU_RESIDENT_JNI(jboolean, nativeSegmenterUploadCoarseMask)(
    JNIEnv* env, jobject /*thiz*/, jlong handle, jobject mask, jint width, jint height) {
    auto entry = LookupSegmenter(handle);
    if (!entry || mask == nullptr) return JNI_FALSE;
    const float* data = static_cast<const float*>(env->GetDirectBufferAddress(mask));
    const jlong capacity = env->GetDirectBufferCapacity(mask);
    if (data == nullptr || capacity <= 0) {
        RecordSegmenterError(entry, "mask buffer is not direct");
        return JNI_FALSE;
    }
    std::string error;
    const bool ok = entry->segmenter->UploadCoarseMask(
        data, static_cast<size_t>(capacity) / sizeof(float), width, height, &error);
    RecordSegmenterError(entry, error);
    return ok ? JNI_TRUE : JNI_FALSE;
}

VG_GS_GPU_RESIDENT_JNI(jboolean, nativeSegmenterRefineAlpha)(
    JNIEnv* /*env*/, jobject /*thiz*/, jlong handle, jint cameraOesTexture) {
    auto entry = LookupSegmenter(handle);
    if (!entry) return JNI_FALSE;
    std::string error;
    const bool ok = entry->segmenter->RefineAlpha(static_cast<uint32_t>(cameraOesTexture), &error);
    RecordSegmenterError(entry, error);
    return ok ? JNI_TRUE : JNI_FALSE;
}

VG_GS_GPU_RESIDENT_JNI(jint, nativeSegmenterRefinedAlphaTextureId)(JNIEnv* /*env*/, jobject /*thiz*/, jlong handle) {
    auto entry = LookupSegmenter(handle);
    if (!entry) return 0;
    return static_cast<jint>(entry->segmenter->RefinedAlphaTextureId());
}

VG_GS_GPU_RESIDENT_JNI(jint, nativeSegmenterAlphaWidth)(JNIEnv* /*env*/, jobject /*thiz*/, jlong handle) {
    auto entry = LookupSegmenter(handle);
    if (!entry) return 0;
    return static_cast<jint>(entry->segmenter->AlphaWidth());
}

VG_GS_GPU_RESIDENT_JNI(jint, nativeSegmenterAlphaHeight)(JNIEnv* /*env*/, jobject /*thiz*/, jlong handle) {
    auto entry = LookupSegmenter(handle);
    if (!entry) return 0;
    return static_cast<jint>(entry->segmenter->AlphaHeight());
}

VG_GS_GPU_RESIDENT_JNI(void, nativeSegmenterResetMaskState)(JNIEnv* /*env*/, jobject /*thiz*/, jlong handle) {
    auto entry = LookupSegmenter(handle);
    if (!entry) return;
    entry->segmenter->ResetMaskState();
}

VG_GS_GPU_RESIDENT_JNI(jstring, nativeSegmenterStatsSummary)(JNIEnv* env, jobject /*thiz*/, jlong handle) {
    auto entry = LookupSegmenter(handle);
    if (!entry) return NewJString(env, "unknown_handle");
    return NewJString(env, entry->segmenter->StatsSummary());
}

VG_GS_GPU_RESIDENT_JNI(jstring, nativeSegmenterLastError)(JNIEnv* env, jobject /*thiz*/, jlong handle) {
    auto entry = LookupSegmenter(handle);
    if (!entry) return NewJString(env, "unknown_handle");
    return NewJString(env, entry->lastError);
}

#endif  // defined(__ANDROID__)
