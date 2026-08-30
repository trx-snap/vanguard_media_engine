// P3-CAM-CONCURRENT: Camera2 dual-camera concurrent PRIVATE AHardwareBuffer
// ingest validation diagnostic. Kotlin owns Camera2 device/session lifecycle
// (CameraManager.openCamera, CameraCaptureSession, ImageReader) for each
// camera; this translation unit only validates cameraSourceNodeId admission
// and imports/releases an AHardwareBuffer within one JNI call. No cross-call
// buffer retention, no Camera2 ownership in C++, no compositor, no PiP/split,
// no recording/export claim, no render/DAG graph evaluation.
//
// This translation unit is Android-only and must NOT be included in iOS or
// host builds. It is added via the Android-only target_sources block in
// src/CMakeLists.txt.
//
// JNI entry points (matching VanguardNativeBridge.kt P3-CAM-CONCURRENT declarations):
//   createAndroidDagPhase3CameraConcurrentIngestSession  -> jstring
//   ingestAndroidDagPhase3CameraConcurrentFrame          -> jstring
//   destroyAndroidDagPhase3CameraConcurrentIngestSession -> jstring

#include <jni.h>

#include <android/hardware_buffer.h>
#include <dlfcn.h>
#include <unistd.h>

#include <atomic>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <memory>
#include <mutex>
#include <string>
#include <unordered_map>
#include <unordered_set>
#include <vector>

#include "vanguard/render/vulkan_backend.h"

// ---------------------------------------------------------------------------
// Local helpers (duplicated per-translation-unit, matching existing convention)
// ---------------------------------------------------------------------------
namespace {

using FnAHardwareBuffer_fromHardwareBuffer =
    AHardwareBuffer* (*)(JNIEnv*, jobject);

AHardwareBuffer* ResolveAHardwareBufferFromJObject(JNIEnv* env, jobject jHwBuf) {
    void* lib = dlopen("libandroid.so", RTLD_NOW | RTLD_LOCAL);
    if (!lib) return nullptr;
    auto fn = reinterpret_cast<FnAHardwareBuffer_fromHardwareBuffer>(
        dlsym(lib, "AHardwareBuffer_fromHardwareBuffer"));
    AHardwareBuffer* buf = nullptr;
    if (fn && jHwBuf) {
        buf = fn(env, jHwBuf);
    }
    dlclose(lib);
    return buf;
}

std::string JStringToStdString(JNIEnv* env, jstring str) {
    if (str == nullptr) return "";
    const char* chars = env->GetStringUTFChars(str, nullptr);
    if (chars == nullptr) return "";
    std::string result(chars);
    env->ReleaseStringUTFChars(str, chars);
    return result;
}

const char* HwBufResultName(vanguard::render::HardwareBufferImportResult r) {
    using R = vanguard::render::HardwareBufferImportResult;
    switch (r) {
        case R::kSuccess:                     return "success";
        case R::kUnavailable:                 return "unavailable";
        case R::kBackendNotInitialized:       return "backend_not_initialized";
        case R::kInvalidArgument:             return "invalid_argument";
        case R::kDuplicateImport:             return "duplicate_import";
        case R::kIncompatibleBuffer:          return "incompatible_buffer";
        case R::kVulkanFunctionUnavailable:   return "vulkan_function_unavailable";
        case R::kVulkanFailure:               return "vulkan_failure";
        case R::kUnknownHandle:               return "unknown_handle";
    }
    return "unknown";
}

// ---------------------------------------------------------------------------
// Phase3 camera-concurrent-ingest diagnostic session
// ---------------------------------------------------------------------------

struct Phase3CameraConcurrentIngestSession {
    // Guards admission/import/release/counters for this session. Kotlin drives
    // camera callbacks from its own background HandlerThread(s), so ingest
    // calls for different cameraSourceNodeIds may race each other here.
    std::mutex                                mutex;
    std::unordered_set<std::string>           allowedCameraSourceNodeIds;
    std::unordered_map<std::string, uint64_t> perSourceFrameCounters;
    uint64_t                                  totalFrameCounter{0};
    vanguard::render::VulkanBackend           backend;
    bool                                       backendInitialized{false};
    // Set under `mutex` by destroy while still holding the registry's last
    // shared_ptr reference; checked under `mutex` by ingest so an in-flight
    // ingest that raced the registry erase fails closed instead of touching a
    // session mid/post-shutdown.
    bool                                        destroyed{false};
    std::string                                sessionId;
};

// ---------------------------------------------------------------------------
// Session registry (guarded by its own mutex; distinct from the per-session
// mutex above, which guards only admission/import/release/counters).
//
// Values are shared_ptr so a session looked up here and handed to ingest
// stays alive even if destroy() concurrently erases it from the map: ingest
// holds its own reference for the duration of the call, and the object is
// only freed once every such reference (plus the map's) is gone.
// ---------------------------------------------------------------------------

std::mutex                                                                             gPhase3CameraSessionRegistryMutex;
std::unordered_map<std::string, std::shared_ptr<Phase3CameraConcurrentIngestSession>> gPhase3CameraSessions;
std::atomic<uint64_t>                                                                  gNextPhase3CameraSessionId{1};

} // namespace

// ---------------------------------------------------------------------------
// JNI: createAndroidDagPhase3CameraConcurrentIngestSession
// ---------------------------------------------------------------------------
extern "C" JNIEXPORT jstring JNICALL
Java_com_connects_vanguard_1media_1engine_bridge_VanguardNativeBridge_createAndroidDagPhase3CameraConcurrentIngestSession(
    JNIEnv*      env,
    jobject      /* this */,
    jobjectArray cameraSourceNodeIdsJ) {

    char status[1024];

    if (!cameraSourceNodeIdsJ) {
        std::snprintf(status, sizeof(status),
            "status=FAIL;reason=null_camera_source_node_ids;sessionId=none");
        return env->NewStringUTF(status);
    }

    const jsize n = env->GetArrayLength(cameraSourceNodeIdsJ);
    if (n < 2) {
        std::snprintf(status, sizeof(status),
            "status=FAIL;reason=insufficient_camera_source_node_ids;sessionId=none");
        return env->NewStringUTF(status);
    }

    std::vector<std::string> ids;
    ids.reserve(static_cast<size_t>(n));
    for (jsize i = 0; i < n; ++i) {
        jstring elem = static_cast<jstring>(env->GetObjectArrayElement(cameraSourceNodeIdsJ, i));
        if (!elem) {
            std::snprintf(status, sizeof(status),
                "status=FAIL;reason=null_camera_source_node_id_element;sessionId=none");
            return env->NewStringUTF(status);
        }
        std::string s = JStringToStdString(env, elem);
        env->DeleteLocalRef(elem);
        if (s.empty()) {
            std::snprintf(status, sizeof(status),
                "status=FAIL;reason=empty_camera_source_node_id;sessionId=none");
            return env->NewStringUTF(status);
        }
        ids.push_back(std::move(s));
    }

    const std::unordered_set<std::string> uniq(ids.begin(), ids.end());
    if (uniq.size() != ids.size()) {
        std::snprintf(status, sizeof(status),
            "status=FAIL;reason=duplicate_camera_source_node_id;sessionId=none");
        return env->NewStringUTF(status);
    }

    auto session = std::make_shared<Phase3CameraConcurrentIngestSession>();
    session->allowedCameraSourceNodeIds = uniq;
    for (const auto& id : ids) {
        session->perSourceFrameCounters[id] = 0;
    }

    if (!session->backend.initialize()) {
        std::snprintf(status, sizeof(status),
            "status=FAIL;reason=backend_init_failed;sessionId=none");
        return env->NewStringUTF(status);
    }
    session->backendInitialized = true;

    const uint64_t sid = gNextPhase3CameraSessionId.fetch_add(1, std::memory_order_relaxed);
    char sidBuf[32];
    std::snprintf(sidBuf, sizeof(sidBuf), "p3cci_%llu",
        static_cast<unsigned long long>(sid));
    session->sessionId = sidBuf;

    {
        std::lock_guard<std::mutex> lock(gPhase3CameraSessionRegistryMutex);
        gPhase3CameraSessions[session->sessionId] = session;
    }

    std::snprintf(status, sizeof(status),
        "status=PASS;sessionId=%s;cameraSourceCount=%d",
        session->sessionId.c_str(), static_cast<int>(n));
    return env->NewStringUTF(status);
}

// ---------------------------------------------------------------------------
// JNI: ingestAndroidDagPhase3CameraConcurrentFrame
// ---------------------------------------------------------------------------
extern "C" JNIEXPORT jstring JNICALL
Java_com_connects_vanguard_1media_1engine_bridge_VanguardNativeBridge_ingestAndroidDagPhase3CameraConcurrentFrame(
    JNIEnv*  env,
    jobject  /* this */,
    jstring  sessionIdJ,
    jstring  cameraSourceNodeIdJ,
    jobject  hardwareBufferJ,
    jint     width,
    jint     height,
    jlong    cameraTimestampNs,
    jint     frameIndex,
    jlong    generationIdJ,
    jint     rotationDegrees,
    jboolean mirrorHorizontal) {

    // Phase3 camera-concurrent-ingest is an ingest-validation diagnostic only:
    // no render/DAG evaluation occurs, so rotation/mirror carry no transform
    // semantics here.
    (void)rotationDegrees;
    (void)mirrorHorizontal;

    char status[768];

    if (!sessionIdJ || !cameraSourceNodeIdJ || !hardwareBufferJ || width <= 0 || height <= 0) {
        std::snprintf(status, sizeof(status),
            "status=FAIL;frameIndex=%d;reason=invalid_args",
            static_cast<int>(frameIndex));
        return env->NewStringUTF(status);
    }

    const std::string sid = JStringToStdString(env, sessionIdJ);
    const std::string cameraSourceNodeId = JStringToStdString(env, cameraSourceNodeIdJ);

    std::shared_ptr<Phase3CameraConcurrentIngestSession> session;
    {
        std::lock_guard<std::mutex> lock(gPhase3CameraSessionRegistryMutex);
        auto it = gPhase3CameraSessions.find(sid);
        if (it != gPhase3CameraSessions.end()) session = it->second;
    }

    if (!session) {
        std::snprintf(status, sizeof(status),
            "status=FAIL;frameIndex=%d;reason=session_not_found;sessionId=%s",
            static_cast<int>(frameIndex), sid.c_str());
        return env->NewStringUTF(status);
    }

    // Per-session mutex around admission check, import, release, and counters.
    // Holding this shared_ptr keeps the session alive even if destroy() erases
    // it from the registry between the lookup above and this lock.
    std::lock_guard<std::mutex> sessionLock(session->mutex);

    if (session->destroyed) {
        std::snprintf(status, sizeof(status),
            "status=FAIL;frameIndex=%d;reason=session_destroyed;sessionId=%s",
            static_cast<int>(frameIndex), sid.c_str());
        return env->NewStringUTF(status);
    }

    if (session->allowedCameraSourceNodeIds.find(cameraSourceNodeId) ==
        session->allowedCameraSourceNodeIds.end()) {
        std::snprintf(status, sizeof(status),
            "status=FAIL;frameIndex=%d;reason=camera_source_node_id_not_admitted;"
            "sessionId=%s;cameraSourceNodeId=%s",
            static_cast<int>(frameIndex), sid.c_str(), cameraSourceNodeId.c_str());
        return env->NewStringUTF(status);
    }

    if (!session->backendInitialized) {
        std::snprintf(status, sizeof(status),
            "status=FAIL;frameIndex=%d;reason=backend_not_initialized;sessionId=%s",
            static_cast<int>(frameIndex), sid.c_str());
        return env->NewStringUTF(status);
    }

    AHardwareBuffer* ahwb = ResolveAHardwareBufferFromJObject(env, hardwareBufferJ);
    if (!ahwb) {
        std::snprintf(status, sizeof(status),
            "status=FAIL;frameIndex=%d;reason=ahardwarebuffer_resolve_failed;sessionId=%s",
            static_cast<int>(frameIndex), sid.c_str());
        return env->NewStringUTF(status);
    }

    vanguard::render::HardwareBufferHandle handle =
        vanguard::render::kInvalidHardwareBufferHandle;
    vanguard::render::HardwareBufferDescriptor descriptor{};
    const auto importResult = session->backend.importHardwareBuffer(
        ahwb, -1, &handle, &descriptor);

    if (importResult != vanguard::render::HardwareBufferImportResult::kSuccess) {
        std::snprintf(status, sizeof(status),
            "status=FAIL;frameIndex=%d;reason=import_failed;importResult=%s;sessionId=%s",
            static_cast<int>(frameIndex),
            HwBufResultName(importResult), sid.c_str());
        return env->NewStringUTF(status);
    }

    int releaseFenceFd = -1;
    const auto releaseResult =
        session->backend.releaseHardwareBuffer(handle, &releaseFenceFd);
    if (releaseFenceFd >= 0) {
        ::close(releaseFenceFd);
        releaseFenceFd = -1;
    }

    if (releaseResult != vanguard::render::HardwareBufferImportResult::kSuccess) {
        std::snprintf(status, sizeof(status),
            "status=FAIL;frameIndex=%d;reason=release_failed;releaseResult=%s;sessionId=%s",
            static_cast<int>(frameIndex),
            HwBufResultName(releaseResult), sid.c_str());
        return env->NewStringUTF(status);
    }

    session->perSourceFrameCounters[cameraSourceNodeId] += 1;
    session->totalFrameCounter += 1;

    std::snprintf(status, sizeof(status),
        "status=PASS;sessionId=%s;cameraSourceNodeId=%s;frameIndex=%d;cameraTimestampNs=%lld;"
        "generationId=%llu;importResult=success;releaseResult=success",
        sid.c_str(), cameraSourceNodeId.c_str(),
        static_cast<int>(frameIndex),
        static_cast<long long>(cameraTimestampNs),
        static_cast<unsigned long long>(generationIdJ));
    return env->NewStringUTF(status);
}

// ---------------------------------------------------------------------------
// JNI: destroyAndroidDagPhase3CameraConcurrentIngestSession
// ---------------------------------------------------------------------------
extern "C" JNIEXPORT jstring JNICALL
Java_com_connects_vanguard_1media_1engine_bridge_VanguardNativeBridge_destroyAndroidDagPhase3CameraConcurrentIngestSession(
    JNIEnv* env,
    jobject /* this */,
    jstring sessionIdJ) {

    char status[256];

    if (!sessionIdJ) {
        std::snprintf(status, sizeof(status),
            "status=FAIL;reason=null_session_id");
        return env->NewStringUTF(status);
    }

    const std::string sid = JStringToStdString(env, sessionIdJ);

    // Erasing under the registry lock guarantees destroy runs exactly once per
    // session: a concurrent/duplicate destroy call finds nothing and fails closed.
    // Any ingest call that already copied the shared_ptr before this erase keeps
    // the session object alive until that call releases its reference; the
    // `destroyed` flag (set below under `mutex`) makes such a racing ingest fail
    // closed instead of touching a session mid/post-shutdown.
    std::shared_ptr<Phase3CameraConcurrentIngestSession> session;
    {
        std::lock_guard<std::mutex> lock(gPhase3CameraSessionRegistryMutex);
        auto it = gPhase3CameraSessions.find(sid);
        if (it != gPhase3CameraSessions.end()) {
            session = it->second;
            gPhase3CameraSessions.erase(it);
        }
    }

    if (!session) {
        std::snprintf(status, sizeof(status),
            "status=FAIL;reason=session_not_found;sessionId=%s", sid.c_str());
        return env->NewStringUTF(status);
    }

    uint64_t totalFrames = 0;
    {
        std::lock_guard<std::mutex> sessionLock(session->mutex);
        totalFrames = session->totalFrameCounter;
        session->destroyed = true;
        if (session->backendInitialized) {
            try {
                session->backend.shutdown();
            } catch (...) {}
            session->backendInitialized = false;
        }
    }

    // `session` (this function's shared_ptr) goes out of scope after this
    // point; the object is freed once no in-flight ingest call still holds a
    // reference.
    std::snprintf(status, sizeof(status),
        "status=PASS;sessionId=%s;totalFrames=%llu",
        sid.c_str(), static_cast<unsigned long long>(totalFrames));
    return env->NewStringUTF(status);
}
