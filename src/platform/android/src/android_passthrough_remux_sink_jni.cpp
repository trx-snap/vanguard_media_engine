// P2-CPP-PASSTHROUGH: PassthroughRemuxSinkNode native foundation validation.
// Kotlin-initiated only. This translation unit never touches
// MediaExtractor/MediaMuxer, performs no media file IO, and holds no global
// refs / cached JNIEnv / attached threads. It only builds a local, in-memory
// vanguard::graph::Graph (dummy source + optional dummy processing nodes +
// PassthroughRemuxSinkNode) to validate topology/timeline correctness ahead
// of any production remux work, which stays entirely Kotlin-owned.
//
// This translation unit is Android-only and must NOT be included in iOS or
// host builds. It is added via the Android-only target_sources block in
// src/CMakeLists.txt.
//
// JNI entry points (matching VanguardNativeBridge.kt P2-CPP-PASSTHROUGH declarations):
//   createAndroidDagPhase2PassthroughRemuxSinkSession   -> jstring
//   validateAndroidDagPhase2PassthroughRemuxSinkSession -> jstring
//   destroyAndroidDagPhase2PassthroughRemuxSinkSession  -> jstring

#include <jni.h>

#include <atomic>
#include <cstdint>
#include <cstdio>
#include <memory>
#include <mutex>
#include <string>
#include <unordered_map>
#include <vector>

#include "vanguard/core/status.h"
#include "vanguard/graph/graph.h"
#include "vanguard/graph/node.h"
#include "vanguard/sinks/passthrough_remux_sink_node.h"

namespace {

// ---------------------------------------------------------------------------
// Local helpers (duplicated per-translation-unit, matching existing convention)
// ---------------------------------------------------------------------------

std::string JStringToStdString(JNIEnv* env, jstring str) {
    if (str == nullptr) return "";
    const char* chars = env->GetStringUTFChars(str, nullptr);
    if (chars == nullptr) return "";
    std::string result(chars);
    env->ReleaseStringUTFChars(str, chars);
    return result;
}

// Upper bound on synthetic processing nodes accepted per validate() call, to
// keep this diagnostic bounded against a malformed/adversarial caller. The
// architecture only ever admits a direct source->sink topology (see
// directPath check below), so any processingNodeCount > 0 fails closed
// anyway; this cap just bounds the graph-construction cost before that.
constexpr int kMaxProcessingNodes = 4096;

// ---------------------------------------------------------------------------
// Local dummy nodes used only to exercise graph topology/timeline evaluation
// for this validation session. They carry no media state.
// ---------------------------------------------------------------------------

class LocalDummySourceNode : public vanguard::graph::Node {
public:
    explicit LocalDummySourceNode(std::string id) : id_(std::move(id)) {
        outputPorts_.push_back({"video_out", vanguard::graph::PortDataType::kVideoFrame});
        outputPorts_.push_back({"audio_out", vanguard::graph::PortDataType::kAudioPacket});
    }

    const std::string&                                 id()          const override { return id_; }
    vanguard::graph::NodeKind                          kind()        const override { return vanguard::graph::NodeKind::kSource; }
    vanguard::graph::NodeType                          type()        const override { return vanguard::graph::NodeType::kCustom; }
    const std::vector<vanguard::graph::PortDescriptor>& inputPorts()  const override { return inputPorts_; }
    const std::vector<vanguard::graph::PortDescriptor>& outputPorts() const override { return outputPorts_; }

private:
    std::string                                   id_;
    std::vector<vanguard::graph::PortDescriptor> inputPorts_;
    std::vector<vanguard::graph::PortDescriptor> outputPorts_;
};

class LocalDummyProcessingNode : public vanguard::graph::Node {
public:
    explicit LocalDummyProcessingNode(std::string id) : id_(std::move(id)) {}

    const std::string&                                 id()          const override { return id_; }
    vanguard::graph::NodeKind                          kind()        const override { return vanguard::graph::NodeKind::kProcessing; }
    vanguard::graph::NodeType                          type()        const override { return vanguard::graph::NodeType::kCustom; }
    const std::vector<vanguard::graph::PortDescriptor>& inputPorts()  const override { return ports_; }
    const std::vector<vanguard::graph::PortDescriptor>& outputPorts() const override { return ports_; }

private:
    std::string                                   id_;
    std::vector<vanguard::graph::PortDescriptor> ports_;
};

// ---------------------------------------------------------------------------
// Passthrough remux sink validation session
// ---------------------------------------------------------------------------

struct PassthroughRemuxSinkSession {
    // Guards `destroyed` against a racing destroy(); immutable fields below
    // are set once at construction and never mutated afterwards.
    std::mutex  mutex;
    std::string sourceNodeId;
    std::string sinkNodeId;
    uint64_t    startPtsUs{0};
    uint64_t    durationUs{0};
    bool        requiresAudio{false};
    bool        destroyed{false};
    std::string sessionId;
};

// ---------------------------------------------------------------------------
// Session registry (guarded by its own mutex; distinct from the per-session
// mutex above). Values are shared_ptr so a session looked up here stays
// alive for the duration of a call even if destroy() concurrently erases it
// from the map.
// ---------------------------------------------------------------------------

std::mutex                                                                     gPassthroughRemuxSessionRegistryMutex;
std::unordered_map<std::string, std::shared_ptr<PassthroughRemuxSinkSession>> gPassthroughRemuxSessions;
std::atomic<uint64_t>                                                          gNextPassthroughRemuxSessionId{1};

} // namespace

// ---------------------------------------------------------------------------
// JNI: createAndroidDagPhase2PassthroughRemuxSinkSession
// ---------------------------------------------------------------------------
extern "C" JNIEXPORT jstring JNICALL
Java_com_connects_vanguard_1media_1engine_bridge_VanguardNativeBridge_createAndroidDagPhase2PassthroughRemuxSinkSession(
    JNIEnv*  env,
    jobject  /* this */,
    jstring  sourceNodeIdJ,
    jstring  sinkNodeIdJ,
    jlong    startPtsUsJ,
    jlong    durationUsJ,
    jboolean requiresAudioJ) {

    char status[512];

    if (!sourceNodeIdJ || !sinkNodeIdJ) {
        std::snprintf(status, sizeof(status),
            "status=FAIL;reason=null_node_id");
        return env->NewStringUTF(status);
    }

    const std::string sourceNodeId = JStringToStdString(env, sourceNodeIdJ);
    const std::string sinkNodeId   = JStringToStdString(env, sinkNodeIdJ);

    if (sourceNodeId.empty() || sinkNodeId.empty()) {
        std::snprintf(status, sizeof(status),
            "status=FAIL;reason=empty_node_id");
        return env->NewStringUTF(status);
    }

    if (durationUsJ <= 0) {
        std::snprintf(status, sizeof(status),
            "status=FAIL;reason=invalid_duration");
        return env->NewStringUTF(status);
    }

    auto session = std::make_shared<PassthroughRemuxSinkSession>();
    session->sourceNodeId  = sourceNodeId;
    session->sinkNodeId    = sinkNodeId;
    session->startPtsUs    = static_cast<uint64_t>(startPtsUsJ);
    session->durationUs    = static_cast<uint64_t>(durationUsJ);
    session->requiresAudio = (requiresAudioJ == JNI_TRUE);

    const uint64_t sid = gNextPassthroughRemuxSessionId.fetch_add(1, std::memory_order_relaxed);
    char sidBuf[32];
    std::snprintf(sidBuf, sizeof(sidBuf), "p2prs_%llu",
        static_cast<unsigned long long>(sid));
    session->sessionId = sidBuf;

    {
        std::lock_guard<std::mutex> lock(gPassthroughRemuxSessionRegistryMutex);
        gPassthroughRemuxSessions[session->sessionId] = session;
    }

    std::snprintf(status, sizeof(status),
        "status=PASS;sessionId=%s", session->sessionId.c_str());
    return env->NewStringUTF(status);
}

// ---------------------------------------------------------------------------
// JNI: validateAndroidDagPhase2PassthroughRemuxSinkSession
// ---------------------------------------------------------------------------
extern "C" JNIEXPORT jstring JNICALL
Java_com_connects_vanguard_1media_1engine_bridge_VanguardNativeBridge_validateAndroidDagPhase2PassthroughRemuxSinkSession(
    JNIEnv*  env,
    jobject  /* this */,
    jstring  sessionIdJ,
    jlong    timelinePtsUsJ,
    jboolean connectVideoJ,
    jboolean connectAudioJ,
    jint     processingNodeCount) {

    char status[512];

    if (!sessionIdJ) {
        std::snprintf(status, sizeof(status),
            "status=FAIL;reason=null_session_id");
        return env->NewStringUTF(status);
    }

    const std::string sid = JStringToStdString(env, sessionIdJ);

    std::shared_ptr<PassthroughRemuxSinkSession> session;
    {
        std::lock_guard<std::mutex> lock(gPassthroughRemuxSessionRegistryMutex);
        auto it = gPassthroughRemuxSessions.find(sid);
        if (it != gPassthroughRemuxSessions.end()) session = it->second;
    }

    if (!session) {
        std::snprintf(status, sizeof(status),
            "status=FAIL;reason=session_not_found");
        return env->NewStringUTF(status);
    }

    // Held for the whole call: this validation only touches in-memory,
    // per-session-immutable fields plus the `destroyed` flag, so there is no
    // benefit to a finer-grained critical section (matches the ingest
    // pattern in android_phase2_concurrent_decode_jni.cpp).
    std::lock_guard<std::mutex> sessionLock(session->mutex);

    if (session->destroyed) {
        std::snprintf(status, sizeof(status),
            "status=FAIL;reason=session_destroyed");
        return env->NewStringUTF(status);
    }

    const bool connectVideo = (connectVideoJ == JNI_TRUE);
    const bool connectAudio = (connectAudioJ == JNI_TRUE);

    if (!connectVideo) {
        std::snprintf(status, sizeof(status),
            "status=FAIL;reason=video_not_connected");
        return env->NewStringUTF(status);
    }

    if (session->requiresAudio && !connectAudio) {
        std::snprintf(status, sizeof(status),
            "status=FAIL;reason=audio_required_not_connected");
        return env->NewStringUTF(status);
    }

    if (processingNodeCount < 0) {
        std::snprintf(status, sizeof(status),
            "status=FAIL;reason=invalid_processing_node_count");
        return env->NewStringUTF(status);
    }

    if (processingNodeCount > kMaxProcessingNodes) {
        std::snprintf(status, sizeof(status),
            "status=FAIL;reason=processing_node_count_too_large");
        return env->NewStringUTF(status);
    }

    // Build a local, in-memory graph: dummy source -> [dummy processing
    // nodes, left unconnected] -> the real PassthroughRemuxSinkNode. Only a
    // direct source->sink topology is architecturally admitted here; any
    // processingNodeCount > 0 adds always-active, unconnected nodes that
    // make the directPath check below fail closed.
    vanguard::graph::Graph graph;

    auto source = std::make_shared<LocalDummySourceNode>(session->sourceNodeId);
    if (!graph.addNode(source).ok()) {
        std::snprintf(status, sizeof(status),
            "status=FAIL;reason=graph_add_source_failed");
        return env->NewStringUTF(status);
    }

    auto sink = std::make_shared<vanguard::sinks::PassthroughRemuxSinkNode>(
        session->sinkNodeId, session->startPtsUs, session->durationUs, session->requiresAudio);
    if (!graph.addNode(sink).ok()) {
        std::snprintf(status, sizeof(status),
            "status=FAIL;reason=graph_add_sink_failed");
        return env->NewStringUTF(status);
    }

    for (int i = 0; i < processingNodeCount; ++i) {
        char procId[64];
        std::snprintf(procId, sizeof(procId), "__p2prs_proc_%d", i);
        auto proc = std::make_shared<LocalDummyProcessingNode>(std::string(procId));
        if (!graph.addNode(proc).ok()) {
            std::snprintf(status, sizeof(status),
                "status=FAIL;reason=graph_add_processing_node_failed");
            return env->NewStringUTF(status);
        }
    }

    if (!graph.connect(session->sourceNodeId, "video_out", session->sinkNodeId, "video_in").ok()) {
        std::snprintf(status, sizeof(status),
            "status=FAIL;reason=graph_connect_video_failed");
        return env->NewStringUTF(status);
    }

    if (session->requiresAudio) {
        if (!graph.connect(session->sourceNodeId, "audio_out", session->sinkNodeId, "audio_in").ok()) {
            std::snprintf(status, sizeof(status),
                "status=FAIL;reason=graph_connect_audio_failed");
            return env->NewStringUTF(status);
        }
    }

    vanguard::graph::FrameRequest request;
    request.timelinePtsUs = static_cast<uint64_t>(timelinePtsUsJ);
    request.generationId  = graph.generationId();

    vanguard::graph::FrameEvaluationResult result;
    if (!graph.evaluatePlayhead(request, result).ok()) {
        std::snprintf(status, sizeof(status),
            "status=FAIL;reason=graph_evaluate_failed");
        return env->NewStringUTF(status);
    }

    bool sinkActive = false;
    for (const auto& info : result.activeNodeDetails) {
        if (info.nodeId == session->sinkNodeId) {
            sinkActive = true;
            break;
        }
    }

    if (!sinkActive) {
        std::snprintf(status, sizeof(status),
            "status=FAIL;reason=sink_not_active");
        return env->NewStringUTF(status);
    }

    // Direct path means exactly {source, sink} were active — any extra
    // active node (e.g. a synthetic processing node) breaks the direct
    // source->sink topology this validation slice admits.
    const bool directPath = result.activeNodeDetails.size() == 2;
    if (!directPath) {
        std::snprintf(status, sizeof(status),
            "status=FAIL;reason=not_direct_path");
        return env->NewStringUTF(status);
    }

    std::snprintf(status, sizeof(status),
        "status=PASS;sessionId=%s;sinkActive=true;directPath=true;hasVideo=%s;hasAudio=%s;"
        "processingNodeCount=%d",
        session->sessionId.c_str(),
        result.hasVideo ? "true" : "false",
        result.hasAudio ? "true" : "false",
        static_cast<int>(processingNodeCount));
    return env->NewStringUTF(status);
}

// ---------------------------------------------------------------------------
// JNI: destroyAndroidDagPhase2PassthroughRemuxSinkSession
// ---------------------------------------------------------------------------
extern "C" JNIEXPORT jstring JNICALL
Java_com_connects_vanguard_1media_1engine_bridge_VanguardNativeBridge_destroyAndroidDagPhase2PassthroughRemuxSinkSession(
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

    // Erasing under the registry lock guarantees destroy runs exactly once
    // per session: a concurrent/duplicate destroy call finds nothing and
    // fails closed, matching android_phase2_concurrent_decode_jni.cpp.
    std::shared_ptr<PassthroughRemuxSinkSession> session;
    {
        std::lock_guard<std::mutex> lock(gPassthroughRemuxSessionRegistryMutex);
        auto it = gPassthroughRemuxSessions.find(sid);
        if (it != gPassthroughRemuxSessions.end()) {
            session = it->second;
            gPassthroughRemuxSessions.erase(it);
        }
    }

    if (!session) {
        std::snprintf(status, sizeof(status),
            "status=FAIL;reason=session_not_found");
        return env->NewStringUTF(status);
    }

    {
        std::lock_guard<std::mutex> sessionLock(session->mutex);
        session->destroyed = true;
    }

    std::snprintf(status, sizeof(status),
        "status=PASS;sessionId=%s", sid.c_str());
    return env->NewStringUTF(status);
}
