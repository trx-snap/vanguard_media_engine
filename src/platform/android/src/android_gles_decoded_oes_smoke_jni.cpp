// Phase 1-Unit AW-OES: Android GLES Decoded SurfaceTexture/OES DAG Render
// Foundation JNI bridge.
//
// Android-only translation unit added via CMake target_sources block.
//
// Route:
//   MediaCodec decoded frame -> Android SurfaceTexture(oesTextureId) bound to
//   a native-allocated GL_TEXTURE_EXTERNAL_OES texture name -> native
//   SurfaceTexture.updateTexImage() (via JNI) -> diagnostic source->sink
//   Graph::evaluatePlayhead() gate using the decoded frame's
//   MediaCodec.BufferInfo.presentationTimeUs -> GlesBackend
//   presentDiagnosticExternalOesTexture() on a Flutter
//   TextureRegistry.SurfaceProducer window surface.
//
// This is a session-based route (create/render/destroy), matching the
// Phase 4A pattern (android_phase4a_decoder_smoke_jni.cpp): the caller
// creates one session, calls the render entry point once per decoded frame,
// then destroys the session.
//
// Original Phase 1-Unit AW (ImageReader.PRIVATE + AHardwareBuffer import of
// the decoded frame) remains DEFERRED / VERIFIED_PHYSICAL_FAILURE
// (`ahb_import_unsupported_format`); this translation unit does not import
// any AHardwareBuffer, use ImageReader.PRIVATE, or otherwise attempt to fix
// that failure. It proves only the alternate SurfaceTexture/OES render path.
//
// Non-claims: diagnostic-only foundation; no color-correct YUV->RGB
// conversion beyond what GlesTextureFrameRenderer already performs for other
// GL_TEXTURE_EXTERNAL_OES draws, no product UI, no ConnectsApp wiring, no
// Phase 1 closure.
//
// JNI entry points (matching VanguardNativeBridge.kt declarations):
//   createAndroidDagPhase1AWOESSession  -> jstring
//   renderAndroidDagPhase1AWOESFrame    -> jstring
//   destroyAndroidDagPhase1AWOESSession -> jstring

#include <jni.h>

#include <android/native_window_jni.h>

#include <atomic>
#include <cstdint>
#include <cstdio>
#include <memory>
#include <mutex>
#include <string>
#include <unordered_map>

#include "vanguard/graph/frame_request.h"
#include "vanguard/graph/graph.h"
#include "vanguard/render/gles_backend.h"
#include "vanguard/render/render_transform.h"

namespace {

constexpr const char* kProofBoundary =
    "gles_decoded_surfacetexture_oes_dag_render_no_ahb_import_no_product_ui";

// ── Phase 1-Unit AW-OES: private diagnostic DAG nodes ─────────────────────
// Local to this translation unit; not part of any product graph session.
// The Graph never transports the decoded pixel/texture data itself -- it
// only gates active/inactive state via evaluatePlayhead(), exactly as the
// Unit AX/BB diagnostic DAGs do; the actual OES texture presentation is
// wired manually below after a successful evaluation.

class DiagAWOesSourceNode final : public vanguard::graph::Node {
public:
    explicit DiagAWOesSourceNode(std::string id) : id_(std::move(id)) {
        outputPorts_ = {{ "kVideoFrame", vanguard::graph::PortDataType::kVideoFrame }};
    }

    const std::string&                  id()          const override { return id_; }
    vanguard::graph::NodeKind           kind()        const override { return vanguard::graph::NodeKind::kSource; }
    vanguard::graph::NodeType           type()        const override { return vanguard::graph::NodeType::kHardwareBufferSource; }
    const std::vector<vanguard::graph::PortDescriptor>& inputPorts()  const override { return inputPorts_; }
    const std::vector<vanguard::graph::PortDescriptor>& outputPorts() const override { return outputPorts_; }

    bool     isActiveAt(uint64_t /*timelinePtsUs*/) const override { return true; }
    uint64_t mapTimelineToLocalPts(uint64_t pts)    const override { return pts; }
    float    blendWeightAt(uint64_t /*pts*/)        const override { return 1.0f; }

private:
    std::string id_;
    std::vector<vanguard::graph::PortDescriptor> inputPorts_;
    std::vector<vanguard::graph::PortDescriptor> outputPorts_;
};

class DiagAWOesTextureSurfaceSinkNode final : public vanguard::graph::Node {
public:
    explicit DiagAWOesTextureSurfaceSinkNode(std::string id) : id_(std::move(id)) {
        inputPorts_ = {{ "kVideoFrame", vanguard::graph::PortDataType::kVideoFrame }};
    }

    const std::string&                  id()          const override { return id_; }
    vanguard::graph::NodeKind           kind()        const override { return vanguard::graph::NodeKind::kSink; }
    vanguard::graph::NodeType           type()        const override { return vanguard::graph::NodeType::kPreviewSurfaceSink; }
    const std::vector<vanguard::graph::PortDescriptor>& inputPorts()  const override { return inputPorts_; }
    const std::vector<vanguard::graph::PortDescriptor>& outputPorts() const override { return outputPorts_; }

    bool     isActiveAt(uint64_t /*timelinePtsUs*/) const override { return true; }
    uint64_t mapTimelineToLocalPts(uint64_t pts)    const override { return pts; }
    float    blendWeightAt(uint64_t /*pts*/)        const override { return 1.0f; }

private:
    std::string id_;
    std::vector<vanguard::graph::PortDescriptor> inputPorts_;
    std::vector<vanguard::graph::PortDescriptor> outputPorts_;
};

// ---------------------------------------------------------------------------
// Session structure + registry (mirrors android_phase4a_decoder_smoke_jni.cpp)
// ---------------------------------------------------------------------------

struct AWOesSession {
    ANativeWindow*                    nativeWindow{nullptr};
    vanguard::render::GlesBackend     backend;
    vanguard::graph::Graph            graph;
    uint64_t                          graphGenerationId{0};
    bool                              initialized{false};
    bool                              surfaceAttached{false};
    bool                              graphBuilt{false};
    uint32_t                          oesTextureId{0};
    int32_t                           width{0};
    int32_t                           height{0};
    int                               renderedFrames{0};
    std::string                       sessionId;
};

std::mutex                                        gSessionMutex;
std::unordered_map<std::string, AWOesSession*>    gSessions;
std::atomic<uint64_t>                             gNextSessionId{1};

std::string SanitizeString(const char* input) {
    if (!input) {
        return "";
    }
    std::string s(input);
    for (char& c : s) {
        if (c == ';' || c == '\n' || c == '\r') {
            c = '_';
        }
    }
    return s;
}

// Destroys a not-yet-registered session on any create-path failure. Assumes
// the session has not been published to gSessions yet.
void DestroyUnregisteredSession(AWOesSession* session) {
    if (session == nullptr) {
        return;
    }
    if (session->oesTextureId != 0) {
        session->backend.deleteDiagnosticExternalOesTexture(session->oesTextureId);
    }
    if (session->surfaceAttached) {
        session->backend.detachSurface();
    }
    if (session->initialized) {
        session->backend.shutdown();
    }
    if (session->nativeWindow != nullptr) {
        ANativeWindow_release(session->nativeWindow);
    }
    delete session;
}

} // namespace

// ---------------------------------------------------------------------------
// JNI: createAndroidDagPhase1AWOESSession
// Initializes GlesBackend, attaches the SurfaceProducer surface, creates a
// GL_TEXTURE_EXTERNAL_OES texture name, and builds a minimal source->sink
// diagnostic Graph. Returns "status=OK;sessionId=<id>;textureId=<id>;..." or
// "status=FAIL;reason=...".
// ---------------------------------------------------------------------------
extern "C" JNIEXPORT jstring JNICALL
Java_com_connects_vanguard_1media_1engine_bridge_VanguardNativeBridge_createAndroidDagPhase1AWOESSession(
    JNIEnv*  env,
    jobject  /* this */,
    jobject  surface,
    jint     width,
    jint     height) {

    char status[512];

    if (surface == nullptr || width <= 0 || height <= 0) {
        std::snprintf(status, sizeof(status),
            "status=FAIL;reason=invalid_args;sessionId=none;textureId=-1");
        return env->NewStringUTF(status);
    }

    ANativeWindow* nativeWindow = ANativeWindow_fromSurface(env, surface);
    if (nativeWindow == nullptr) {
        std::snprintf(status, sizeof(status),
            "status=FAIL;reason=native_window_failed;sessionId=none;textureId=-1");
        return env->NewStringUTF(status);
    }

    auto* session = new AWOesSession();
    session->nativeWindow = nativeWindow;
    session->width = width;
    session->height = height;

    uint64_t sid = gNextSessionId.fetch_add(1, std::memory_order_relaxed);
    char sidBuf[32];
    std::snprintf(sidBuf, sizeof(sidBuf), "aw_oes_%llu", static_cast<unsigned long long>(sid));
    session->sessionId = sidBuf;

    if (!session->backend.initialize()) {
        const std::string lastError = SanitizeString(session->backend.lastError());
        DestroyUnregisteredSession(session);
        std::snprintf(status, sizeof(status),
            "status=FAIL;reason=backend_init_failed;sessionId=none;textureId=-1;lastError=%s",
            lastError.c_str());
        return env->NewStringUTF(status);
    }
    session->initialized = true;

    if (!session->backend.attachSurface(nativeWindow, static_cast<uint32_t>(width), static_cast<uint32_t>(height))) {
        const std::string lastError = SanitizeString(session->backend.lastError());
        DestroyUnregisteredSession(session);
        std::snprintf(status, sizeof(status),
            "status=FAIL;reason=surface_attach_failed;sessionId=none;textureId=-1;lastError=%s",
            lastError.c_str());
        return env->NewStringUTF(status);
    }
    session->surfaceAttached = true;

    const uint32_t oesTextureId = session->backend.createDiagnosticExternalOesTexture();
    if (oesTextureId == 0) {
        const std::string lastError = SanitizeString(session->backend.lastError());
        DestroyUnregisteredSession(session);
        std::snprintf(status, sizeof(status),
            "status=FAIL;reason=oes_texture_create_failed;sessionId=none;textureId=-1;lastError=%s",
            lastError.c_str());
        return env->NewStringUTF(status);
    }
    session->oesTextureId = oesTextureId;

    auto srcNode = std::make_shared<DiagAWOesSourceNode>("diag_aw_oes_src");
    auto sinkNode = std::make_shared<DiagAWOesTextureSurfaceSinkNode>("diag_aw_oes_sink");

    const auto addSrcStatus = session->graph.addNode(srcNode);
    const auto addSinkStatus = session->graph.addNode(sinkNode);
    const auto connectStatus = session->graph.connect(
        "diag_aw_oes_src", "kVideoFrame", "diag_aw_oes_sink", "kVideoFrame");

    if (!addSrcStatus.ok() || !addSinkStatus.ok() || !connectStatus.ok()) {
        DestroyUnregisteredSession(session);
        std::snprintf(status, sizeof(status),
            "status=FAIL;reason=graph_build_failed;sessionId=none;textureId=-1");
        return env->NewStringUTF(status);
    }
    session->graphGenerationId = session->graph.generationId();
    session->graphBuilt = true;

    {
        std::lock_guard<std::mutex> lock(gSessionMutex);
        gSessions[session->sessionId] = session;
    }

    std::snprintf(status, sizeof(status),
        "status=OK;sessionId=%s;textureId=%u;width=%d;height=%d;proofBoundary=%s",
        session->sessionId.c_str(), oesTextureId, width, height, kProofBoundary);
    return env->NewStringUTF(status);
}

// ---------------------------------------------------------------------------
// JNI: renderAndroidDagPhase1AWOESFrame
// Called once per decoded frame, after the caller has released the decoded
// output buffer onto the Surface backing `surfaceTexture` with render=true.
// Makes the backend's window surface current, calls
// SurfaceTexture.updateTexImage() via JNI, evaluates the diagnostic Graph
// using the caller-supplied decoded presentationTimeUs, and presents the
// session's OES texture. Returns "status=PASS;..." or "status=FAIL;...".
// ---------------------------------------------------------------------------
extern "C" JNIEXPORT jstring JNICALL
Java_com_connects_vanguard_1media_1engine_bridge_VanguardNativeBridge_renderAndroidDagPhase1AWOESFrame(
    JNIEnv*  env,
    jobject  /* this */,
    jstring  sessionIdJ,
    jobject  surfaceTexture,
    jlong    presentationTimeUs,
    jint     frameIndex,
    jint     rotationDegrees,
    jboolean mirrorHorizontal) {

    char status[512];

    if (sessionIdJ == nullptr || surfaceTexture == nullptr) {
        std::snprintf(status, sizeof(status),
            "status=FAIL;frameIndex=%d;reason=invalid_args",
            static_cast<int>(frameIndex));
        return env->NewStringUTF(status);
    }

    const char* sidCStr = env->GetStringUTFChars(sessionIdJ, nullptr);
    std::string sid(sidCStr ? sidCStr : "");
    if (sidCStr) env->ReleaseStringUTFChars(sessionIdJ, sidCStr);

    AWOesSession* session = nullptr;
    {
        std::lock_guard<std::mutex> lock(gSessionMutex);
        auto it = gSessions.find(sid);
        if (it != gSessions.end()) session = it->second;
    }

    if (session == nullptr) {
        std::snprintf(status, sizeof(status),
            "status=FAIL;frameIndex=%d;reason=session_not_found;sessionId=%s",
            static_cast<int>(frameIndex), sid.c_str());
        return env->NewStringUTF(status);
    }

    if (!session->initialized || !session->surfaceAttached || !session->graphBuilt) {
        std::snprintf(status, sizeof(status),
            "status=FAIL;frameIndex=%d;reason=session_not_ready",
            static_cast<int>(frameIndex));
        return env->NewStringUTF(status);
    }

    // ── 1. Make the backend's window EGL context current ────────────────────
    // Required before calling SurfaceTexture.updateTexImage(), which
    // operates on the currently-bound GL context.
    if (!session->backend.diagnosticMakeSurfaceCurrent()) {
        const std::string lastError = SanitizeString(session->backend.lastError());
        std::snprintf(status, sizeof(status),
            "status=FAIL;frameIndex=%d;reason=make_current_failed;lastError=%s",
            static_cast<int>(frameIndex), lastError.c_str());
        return env->NewStringUTF(status);
    }

    // ── 2. SurfaceTexture.updateTexImage() via JNI ───────────────────────────
    jclass surfaceTextureClass = env->GetObjectClass(surfaceTexture);
    jmethodID updateTexImageMethod = (surfaceTextureClass != nullptr)
        ? env->GetMethodID(surfaceTextureClass, "updateTexImage", "()V")
        : nullptr;
    if (surfaceTextureClass != nullptr) {
        env->DeleteLocalRef(surfaceTextureClass);
    }
    if (updateTexImageMethod == nullptr) {
        if (env->ExceptionCheck()) {
            env->ExceptionClear();
        }
        std::snprintf(status, sizeof(status),
            "status=FAIL;frameIndex=%d;reason=update_tex_image_method_not_found",
            static_cast<int>(frameIndex));
        return env->NewStringUTF(status);
    }

    env->CallVoidMethod(surfaceTexture, updateTexImageMethod);
    if (env->ExceptionCheck()) {
        env->ExceptionClear();
        std::snprintf(status, sizeof(status),
            "status=FAIL;frameIndex=%d;reason=update_tex_image_exception",
            static_cast<int>(frameIndex));
        return env->NewStringUTF(status);
    }

    // ── 3. Evaluate the diagnostic Graph using the decoded PTS ──────────────
    vanguard::graph::FrameRequest request;
    request.timelinePtsUs = static_cast<uint64_t>(presentationTimeUs < 0 ? 0 : presentationTimeUs);
    request.generationId = session->graphGenerationId;
    request.canvasWidth = static_cast<uint32_t>(session->width);
    request.canvasHeight = static_cast<uint32_t>(session->height);

    vanguard::graph::FrameEvaluationResult evalResult;
    const auto evalStatus = session->graph.evaluatePlayhead(request, evalResult);

    if (!evalStatus.ok() || !evalResult.ok() || !evalResult.hasVideo ||
        evalResult.activeNodes.empty()) {
        std::snprintf(status, sizeof(status),
            "status=FAIL;frameIndex=%d;reason=evaluation_failed;presentationTimeUs=%lld",
            static_cast<int>(frameIndex), static_cast<long long>(presentationTimeUs));
        return env->NewStringUTF(status);
    }

    // ── 4. Present the session's OES texture ─────────────────────────────────
    vanguard::render::VideoFrameTransform transform;
    transform.rotationDegrees = static_cast<uint32_t>(rotationDegrees);
    transform.mirrorHorizontal = (mirrorHorizontal == JNI_TRUE);

    const bool presentOk = session->backend.presentDiagnosticExternalOesTexture(
        session->oesTextureId, transform);
    if (!presentOk) {
        const std::string lastError = SanitizeString(session->backend.lastError());
        std::snprintf(status, sizeof(status),
            "status=FAIL;frameIndex=%d;reason=present_failed;lastError=%s",
            static_cast<int>(frameIndex), lastError.c_str());
        return env->NewStringUTF(status);
    }

    session->renderedFrames++;

    std::snprintf(status, sizeof(status),
        "status=PASS;frameIndex=%d;renderedFrames=%d;presentationTimeUs=%lld;"
        "textureId=%u;proofBoundary=%s",
        static_cast<int>(frameIndex), session->renderedFrames,
        static_cast<long long>(presentationTimeUs), session->oesTextureId, kProofBoundary);
    return env->NewStringUTF(status);
}

// ---------------------------------------------------------------------------
// JNI: destroyAndroidDagPhase1AWOESSession
// Deletes the OES texture, detaches the surface, shuts down the backend,
// releases the native window, and erases the session from the registry
// exactly once. Idempotent: a repeated call finds no session and returns a
// structured failure rather than double-freeing anything.
// ---------------------------------------------------------------------------
extern "C" JNIEXPORT jstring JNICALL
Java_com_connects_vanguard_1media_1engine_bridge_VanguardNativeBridge_destroyAndroidDagPhase1AWOESSession(
    JNIEnv*  env,
    jobject  /* this */,
    jstring  sessionIdJ) {

    char status[256];

    if (sessionIdJ == nullptr) {
        std::snprintf(status, sizeof(status), "status=FAIL;reason=null_session_id");
        return env->NewStringUTF(status);
    }

    const char* sidCStr = env->GetStringUTFChars(sessionIdJ, nullptr);
    std::string sid(sidCStr ? sidCStr : "");
    if (sidCStr) env->ReleaseStringUTFChars(sessionIdJ, sidCStr);

    AWOesSession* session = nullptr;
    {
        std::lock_guard<std::mutex> lock(gSessionMutex);
        auto it = gSessions.find(sid);
        if (it != gSessions.end()) {
            session = it->second;
            gSessions.erase(it);
        }
    }

    if (session == nullptr) {
        std::snprintf(status, sizeof(status),
            "status=FAIL;reason=session_not_found;sessionId=%s", sid.c_str());
        return env->NewStringUTF(status);
    }

    const int renderedFrames = session->renderedFrames;

    try {
        if (session->oesTextureId != 0) {
            session->backend.deleteDiagnosticExternalOesTexture(session->oesTextureId);
        }
        if (session->surfaceAttached) {
            session->backend.detachSurface();
        }
        if (session->initialized) {
            session->backend.shutdown();
        }
    } catch (...) {}

    if (session->nativeWindow != nullptr) {
        ANativeWindow_release(session->nativeWindow);
        session->nativeWindow = nullptr;
    }

    delete session;

    std::snprintf(status, sizeof(status),
        "status=OK;sessionId=%s;renderedFrames=%d", sid.c_str(), renderedFrames);
    return env->NewStringUTF(status);
}
