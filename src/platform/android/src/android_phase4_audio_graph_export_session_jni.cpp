// P4-AUDIO-PASS2-GRAPH-NATIVE-SESSION / P4-AUDIO-PASS2-NATIVE-GAIN-ENVELOPE:
// parameterized N-source (up to 8) True-DAG audio graph EXPORT session. One
// session = one C++ Graph holding one AudioMixBusNode ("graph_export_mix")
// plus up to eight DecodedAudioPcmSourceNode instances built with the 6-arg
// node-owned-transport constructor (each node owns its
// AudioSpscAudioRingBuffer + AudioDecoderRingWriter +
// RingBufferAudioSampleProvider triple by composition). prepare() freezes
// the topology and constructs a GraphAudioScheduler via the tag-dispatched
// AutoDiscoverSourceProviders constructor with the session-owned mix-params
// map, so the native graph owns per-frame gain/envelope evaluation
// (AudioGainEnvelope inside AudioMixBusNode) for tracks added via the
// add-with-envelope verb. The legacy add verb stays byte-compatible for
// diagnostics: it registers no mix-params entry, so its tracks mix at
// static unit gain with a null envelope, exactly as before. Windows are
// rendered synchronously, contiguously, and export-style: startFrame must
// equal the session's own nextRenderFrame cursor (no skips, retries, or
// reorders), and any provider zero-fill underrun during a window fails that
// window closed (zero-filled audio is corruption for an export session,
// never a silent-success).
//
// Every graph export source node uses timelineStartPtsUs=0 and
// expectedFrameCount=totalFrames so all providers are called in lockstep
// (native per-node timeline gating is an explicit non-claim here). Envelope
// times are absolute output-timeline microseconds; the scheduler stamps
// envelopeStartPtsUs = windowPtsUs so the mix bus evaluates the same axis.
//
// Honest non-claims: no byte identity with the prior Kotlin pre-scaling
// route, no performance claim, no runtime/realtime sink, no
// AudioTrack/AAudio/OpenSL/Oboe, no MediaCodec/MediaExtractor, no file IO,
// no native worker threads, no audible-output claim, no app/editor/product,
// no streaming/cache, no iOS.
//
// This translation unit is Android-only and must NOT be included in iOS or
// host builds; it is added via the Android-only target_sources block in
// src/CMakeLists.txt. Its session registry is disjoint from every other
// diagnostic session registry.
//
// JNI entry points (VanguardNativeBridge.kt instance declarations):
//   createAndroidDagPhase4AudioGraphExportSession              -> jstring
//   addAndroidDagPhase4AudioGraphExportTrack                   -> jstring
//   addAndroidDagPhase4AudioGraphExportTrackWithEnvelope       -> jstring
//   prepareAndroidDagPhase4AudioGraphExportSession             -> jstring
//   ingestAndroidDagPhase4AudioGraphExportTrackPcm             -> jstring
//   renderAndroidDagPhase4AudioGraphExportWindow               -> jstring
//   destroyAndroidDagPhase4AudioGraphExportSession             -> jstring

#include <jni.h>

#include <atomic>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <memory>
#include <mutex>
#include <string>
#include <unordered_map>
#include <vector>

#include "vanguard/audio/audio_decoder_ring_writer.h"
#include "vanguard/audio/audio_gain_envelope.h"
#include "vanguard/audio/audio_mix_bus_node.h"
#include "vanguard/audio/decoded_audio_pcm_source_node.h"
#include "vanguard/audio/graph_audio_scheduler.h"
#include "vanguard/audio/ring_buffer_audio_sample_provider.h"
#include "vanguard/graph/graph.h"

namespace {

using vanguard::audio::AudioDecoderRingWriter;
using vanguard::audio::AudioGainEnvelope;
using vanguard::audio::AudioMixBusNode;
using vanguard::audio::AutoDiscoverSourceProviders;
using vanguard::audio::DecodedAudioPcmSourceNode;
using vanguard::audio::GraphAudioScheduler;
using vanguard::audio::RingBufferAudioSampleProvider;
using vanguard::graph::Graph;
using WriterStatus    = AudioDecoderRingWriter::Status;
using SchedulerResult = GraphAudioScheduler::SchedulerResult;

// Must stay byte-identical to PROOF_BOUNDARY in
// AndroidAudioGraphExportSessionDriver.kt. It describes the legacy
// diagnostic add-track route (unit gain, no production swap) and is frozen
// harness data, not a claim about the add-with-envelope production verb.
constexpr const char* kProofBoundary =
    "native_true_dag_pass2_graph_export_session_diagnostic_only_n_source_node_owned_ring_graph_"
    "scheduler_mixbus_unit_gain_no_production_route_swap_no_android_mixdown_engine_change_no_"
    "legacy_chunk_mixer_change_no_runtime_realtime_sink_no_audiotrack_no_aaudio_no_opensl_no_"
    "oboe_no_mediacodec_no_mediaextractor_no_file_io_no_native_worker_threads_no_app_no_editor_"
    "no_product_no_streaming_no_cache_no_ios";

constexpr const char* kMixNodeId = "graph_export_mix";

constexpr size_t  kMaxLiveSessions          = 8;
constexpr size_t  kMaxTrackCount            = AudioMixBusNode::kMaxTrackCount; // 8
constexpr int64_t kSourceRingCapacityFrames = 8192;
constexpr int32_t kMaxIngestFrames          = 8192;

std::string JStringToStdString(JNIEnv* env, jstring str) {
    if (str == nullptr) return "";
    const char* chars = env->GetStringUTFChars(str, nullptr);
    if (chars == nullptr) return "";
    std::string result(chars);
    env->ReleaseStringUTFChars(str, chars);
    return result;
}

const char* WriterStatusName(WriterStatus s) {
    switch (s) {
        case WriterStatus::kOk:              return "ok";
        case WriterStatus::kPartialWrite:    return "partial_write";
        case WriterStatus::kRingFull:        return "ring_full";
        case WriterStatus::kFormatMismatch:  return "format_mismatch";
        case WriterStatus::kInvalidArgument: return "invalid_argument";
        case WriterStatus::kAlreadyEos:      return "already_eos";
        case WriterStatus::kAwaitingSeekAck: return "awaiting_seek_ack";
    }
    return "unknown";
}

const char* SchedulerResultName(SchedulerResult r) {
    switch (r) {
        case SchedulerResult::kOk:                   return "ok";
        case SchedulerResult::kSilence:              return "silence";
        case SchedulerResult::kStaleGeneration:      return "stale_generation";
        case SchedulerResult::kInvalidTarget:        return "invalid_target";
        case SchedulerResult::kInvalidFrameCount:    return "invalid_frame_count";
        case SchedulerResult::kInsufficientCapacity: return "insufficient_capacity";
        case SchedulerResult::kSampleRateMismatch:   return "sample_rate_mismatch";
        case SchedulerResult::kProviderMissing:      return "provider_missing";
        case SchedulerResult::kProviderError:        return "provider_error";
        case SchedulerResult::kMixFailure:           return "mix_failure";
        case SchedulerResult::kWindowPtsOverflow:    return "window_pts_overflow";
    }
    return "unknown";
}

// ---------------------------------------------------------------------------
// Graph export session. The per-session mutex guards every member below
// (the Kotlin driver runs one worker thread, but the native seam still
// enforces the frozen per-session-mutex convention). The graph must be
// fully populated before prepare() constructs the scheduler, which
// snapshots the graph generation; addTrack after prepare is rejected so
// the snapshot can never go stale within a session's own lifecycle.
// ---------------------------------------------------------------------------
struct GraphExportSession {
    std::mutex mutex;

    Graph                            graphTopology;
    std::shared_ptr<AudioMixBusNode> mixBus;

    // Insertion order == mix-bus input-port order; the map is the id index.
    std::vector<std::string> trackOrder;
    std::unordered_map<std::string, std::shared_ptr<DecodedAudioPcmSourceNode>> tracks;

    // P4-AUDIO-PASS2-NATIVE-GAIN-ENVELOPE: session-owned per-track gain
    // envelopes plus the scheduler mix-params map handed to
    // GraphAudioScheduler at prepare(). unordered_map values have stable
    // addresses, so each mixParams entry (and the scheduler's RoutedSource)
    // may hold a non-owning pointer into `envelopes`. Tracks added via the
    // legacy add verb have no entry here (unit gain, null envelope). Both
    // maps are declared BEFORE `scheduler` so the scheduler — which holds
    // non-owning envelope pointers — is destroyed first.
    std::unordered_map<std::string, AudioGainEnvelope> envelopes;
    std::unordered_map<std::string, GraphAudioScheduler::SourceMixParams> mixParams;

    std::unique_ptr<GraphAudioScheduler> scheduler;
    bool     prepared{false};
    bool     destroyed{false};
    uint64_t snapshotGeneration{0};

    int32_t sampleRate{0};
    int32_t channelCount{0};
    int64_t maxFramesPerMix{0};

    // Export window cursor/metrics; mutated only on a PASS render.
    int64_t nextRenderFrame{0};
    int64_t windowCount{0};
    int64_t silentWindowCount{0};

    std::string sessionId;
};

// ---------------------------------------------------------------------------
// Session registry (own mutex, disjoint from every other diagnostic seam).
// Values are shared_ptr so an entry point that looked a session up stays
// safe even if destroy concurrently erases the map entry.
// ---------------------------------------------------------------------------
std::mutex gGraphExportRegistryMutex;
std::unordered_map<std::string, std::shared_ptr<GraphExportSession>> gGraphExportSessions;
std::atomic<uint64_t> gNextGraphExportSessionId{1};

std::shared_ptr<GraphExportSession> FindGraphExportSession(const std::string& sessionId) {
    std::lock_guard<std::mutex> lock(gGraphExportRegistryMutex);
    auto it = gGraphExportSessions.find(sessionId);
    return it == gGraphExportSessions.end() ? nullptr : it->second;
}

// The 6-arg node constructor always composes a RingBufferAudioSampleProvider,
// so this downcast of the base-typed accessor is exact (diagnostics-only
// underrun metric access, same justification as the node-owned pipeline TU).
RingBufferAudioSampleProvider* TrackProvider(DecodedAudioPcmSourceNode& node) {
    return static_cast<RingBufferAudioSampleProvider*>(node.audioSampleProvider());
}

const char* EnvelopeBuildFailReason(AudioGainEnvelope::BuildResult r) {
    switch (r) {
        case AudioGainEnvelope::BuildResult::kOk:
            return nullptr;
        case AudioGainEnvelope::BuildResult::kTooManyKeyframes:
            return "envelope_build_too_many_keyframes";
        case AudioGainEnvelope::BuildResult::kNonFiniteGain:
            return "envelope_build_non_finite_gain";
        case AudioGainEnvelope::BuildResult::kUnsupportedInterpolation:
            return "envelope_build_unsupported_interpolation";
        case AudioGainEnvelope::BuildResult::kInvalidRange:
            return "envelope_build_invalid_range";
        case AudioGainEnvelope::BuildResult::kNullOutput:
            return "envelope_build_null_output";
        case AudioGainEnvelope::BuildResult::kEmptyAfterNormalize:
            return "envelope_build_empty_after_normalize";
    }
    return "envelope_build_failed";
}

// Builds the native track envelope from the raw Kotlin-supplied spec params
// (Kotlin only converts seconds to integer microseconds) via
// AudioGainEnvelope::ForTrack. ForTrack's static path deliberately does not
// clamp `volume` (Kotlin parity), so an out-of-range volume — negative or
// above unity — yields out-of-range envelope keyframes that AudioMixBusNode
// would reject per frame (kInvalidEnvelopeGain). When that happens the
// envelope is rebuilt from clamped explicit keyframes, inserting the exact
// 0.0/1.0 boundary-crossing keyframes per linear segment so the clamped
// shape matches sample-level clamping of the original ramp, then
// re-normalised with mixGain=1.0 (the original mixGain was already applied
// by the first build). Non-finite inputs stay fail-closed inside ForTrack.
// Returns nullptr on success (with *outGainClamped reporting whether any
// out-of-range keyframe was clamped) or a static fail-reason token.
const char* BuildTrackEnvelope(const AudioGainEnvelope::Keyframe* rawKeyframes,
                               size_t             rawCount,
                               double             volume,
                               double             mixGain,
                               int64_t            fadeInUs,
                               int64_t            fadeOutUs,
                               int64_t            trackStartUs,
                               int64_t            trackEndUs,
                               AudioGainEnvelope* outEnvelope,
                               bool*              outGainClamped) {
    *outGainClamped = false;
    const AudioGainEnvelope::BuildResult built = AudioGainEnvelope::ForTrack(
        rawKeyframes, rawCount, volume, mixGain,
        fadeInUs, fadeOutUs, trackStartUs, trackEndUs, outEnvelope);
    if (built != AudioGainEnvelope::BuildResult::kOk) {
        return EnvelopeBuildFailReason(built);
    }

    bool outOfRange = false;
    for (size_t i = 0; i < outEnvelope->keyframeCount(); ++i) {
        const double g = outEnvelope->keyframeAt(i).gain;
        if (g < 0.0 || g > 1.0) {
            outOfRange = true;
            break;
        }
    }
    if (!outOfRange) {
        return nullptr;
    }

    AudioGainEnvelope::Keyframe clamped[AudioGainEnvelope::kMaxRawKeyframes];
    size_t clampedCount = 0;
    const size_t count = outEnvelope->keyframeCount();
    for (size_t i = 0; i < count; ++i) {
        const AudioGainEnvelope::Keyframe& kf = outEnvelope->keyframeAt(i);
        if (i > 0) {
            // Insert the 0.0/1.0 crossing keyframes of the linear segment
            // (prev -> kf), ordered by time along the segment.
            const AudioGainEnvelope::Keyframe& prev = outEnvelope->keyframeAt(i - 1);
            const double  g0 = prev.gain;
            const double  g1 = kf.gain;
            const int64_t t0 = prev.timeUs;
            const int64_t t1 = kf.timeUs;
            int64_t crossTimes[2];
            double  crossGains[2];
            size_t  crossCount = 0;
            const double bounds[2] = {0.0, 1.0};
            for (double bound : bounds) {
                if ((g0 < bound && g1 > bound) || (g0 > bound && g1 < bound)) {
                    const double fraction = (bound - g0) / (g1 - g0);
                    crossTimes[crossCount] =
                        t0 + static_cast<int64_t>(
                                 std::floor(fraction * static_cast<double>(t1 - t0)));
                    crossGains[crossCount] = bound;
                    ++crossCount;
                }
            }
            if (crossCount == 2 && crossTimes[0] > crossTimes[1]) {
                const int64_t tSwap = crossTimes[0];
                const double  gSwap = crossGains[0];
                crossTimes[0] = crossTimes[1];
                crossGains[0] = crossGains[1];
                crossTimes[1] = tSwap;
                crossGains[1] = gSwap;
            }
            for (size_t c = 0; c < crossCount; ++c) {
                if (clampedCount >= AudioGainEnvelope::kMaxRawKeyframes) {
                    return "envelope_clamp_keyframe_overflow";
                }
                clamped[clampedCount++] = AudioGainEnvelope::Keyframe{
                    crossTimes[c], crossGains[c],
                    AudioGainEnvelope::Interpolation::kLinear};
            }
        }
        if (clampedCount >= AudioGainEnvelope::kMaxRawKeyframes) {
            return "envelope_clamp_keyframe_overflow";
        }
        double g = kf.gain;
        if (g < 0.0) {
            g = 0.0;
        } else if (g > 1.0) {
            g = 1.0;
        }
        clamped[clampedCount++] = AudioGainEnvelope::Keyframe{
            kf.timeUs, g, AudioGainEnvelope::Interpolation::kLinear};
    }

    const AudioGainEnvelope::BuildResult rebuilt = AudioGainEnvelope::Normalize(
        clamped, clampedCount, trackStartUs, trackEndUs, /*mixGain=*/1.0, outEnvelope);
    if (rebuilt != AudioGainEnvelope::BuildResult::kOk) {
        return EnvelopeBuildFailReason(rebuilt);
    }
    *outGainClamped = true;
    return nullptr;
}

// Shared add-track core for both add verbs. The caller holds session.mutex
// and has already rejected destroyed/prepared sessions. `envelope` == nullptr
// is the legacy diagnostic path (no envelopes/mixParams entry, so the
// scheduler keeps static unit gain with a null envelope for that source);
// non-null copies the envelope into session.envelopes and registers a
// unit-static-gain mixParams entry pointing at that stored copy. Fails
// closed: on any failure the graph, trackOrder, tracks, envelopes and
// mixParams are all left unmutated (the connect/registration failure paths
// roll their own mutations back).
bool AddGraphExportTrackLocked(GraphExportSession&      session,
                               const std::string&       trackId,
                               int64_t                  frames,
                               const AudioGainEnvelope* envelope,
                               char*                    status,
                               size_t                   statusSize,
                               size_t*                  outTrackIndex) {
    if (trackId.empty()) {
        std::snprintf(status, statusSize, "status=FAIL;reason=empty_track_id");
        return false;
    }
    if (session.tracks.count(trackId) != 0) {
        std::snprintf(status, statusSize, "status=FAIL;reason=duplicate_track_id");
        return false;
    }
    if (session.trackOrder.size() >= kMaxTrackCount) {
        std::snprintf(status, statusSize,
            "status=FAIL;reason=total_track_count_exceeded:%zu",
            session.trackOrder.size() + 1);
        return false;
    }
    if (frames <= 0 ||
        frames > static_cast<int64_t>(session.sampleRate) *
                     DecodedAudioPcmSourceNode::kMaxExpectedSeconds) {
        std::snprintf(status, statusSize, "status=FAIL;reason=invalid_total_frames");
        return false;
    }

    std::shared_ptr<DecodedAudioPcmSourceNode> node;
    try {
        node = std::make_shared<DecodedAudioPcmSourceNode>(
            trackId,
            session.sampleRate,
            session.channelCount,
            frames,
            /*timelineStartPtsUs=*/0,
            kSourceRingCapacityFrames);
    } catch (const std::exception& e) {
        std::snprintf(status, statusSize, "status=FAIL;reason=%s", e.what());
        return false;
    } catch (...) {
        std::snprintf(status, statusSize, "status=FAIL;reason=node_construction_failed");
        return false;
    }
    if (!node->ownsRing()) {
        std::snprintf(status, statusSize, "status=FAIL;reason=node_transport_missing");
        return false;
    }

    if (!session.graphTopology.addNode(node).ok()) {
        std::snprintf(status, statusSize, "status=FAIL;reason=graph_add_node_failed");
        return false;
    }

    const size_t trackIndex = session.trackOrder.size();
    const std::string& inputPortId = session.mixBus->inputPorts()[trackIndex].id;
    if (!session.graphTopology.connect(trackId, "audio_out", kMixNodeId, inputPortId).ok()) {
        // Fail closed and keep the graph consistent: the orphan node must
        // not be discoverable by a later prepare().
        (void)session.graphTopology.removeNode(trackId);
        std::snprintf(status, statusSize, "status=FAIL;reason=graph_connect_failed");
        return false;
    }

    try {
        if (envelope != nullptr) {
            session.envelopes[trackId] = *envelope;
            GraphAudioScheduler::SourceMixParams params;
            params.gain     = 1.0;
            params.envelope = &session.envelopes[trackId];
            session.mixParams[trackId] = params;
        }
        session.trackOrder.push_back(trackId);
        session.tracks[trackId] = std::move(node);
    } catch (...) {
        session.envelopes.erase(trackId);
        session.mixParams.erase(trackId);
        if (!session.trackOrder.empty() && session.trackOrder.back() == trackId) {
            session.trackOrder.pop_back();
        }
        session.tracks.erase(trackId);
        (void)session.graphTopology.removeNode(trackId);
        std::snprintf(status, statusSize, "status=FAIL;reason=track_registration_failed");
        return false;
    }

    *outTrackIndex = trackIndex;
    return true;
}

} // namespace

// ---------------------------------------------------------------------------
// JNI: createAndroidDagPhase4AudioGraphExportSession
// ---------------------------------------------------------------------------
extern "C" JNIEXPORT jstring JNICALL
Java_com_connects_vanguard_1media_1engine_bridge_VanguardNativeBridge_createAndroidDagPhase4AudioGraphExportSession(
    JNIEnv* env,
    jobject /* this */,
    jint    sampleRate,
    jint    channelCount,
    jint    maxFramesPerMix) {

    char status[768];

    if (sampleRate < DecodedAudioPcmSourceNode::kMinSampleRate ||
        sampleRate > DecodedAudioPcmSourceNode::kMaxSampleRate) {
        std::snprintf(status, sizeof(status), "status=FAIL;reason=invalid_sample_rate");
        return env->NewStringUTF(status);
    }
    if (channelCount < DecodedAudioPcmSourceNode::kMinChannelCount ||
        channelCount > DecodedAudioPcmSourceNode::kMaxChannelCount) {
        std::snprintf(status, sizeof(status), "status=FAIL;reason=invalid_channel_count");
        return env->NewStringUTF(status);
    }
    if (maxFramesPerMix < AudioMixBusNode::kMinMaxFramesPerMix ||
        maxFramesPerMix > AudioMixBusNode::kMaxMaxFramesPerMix) {
        std::snprintf(status, sizeof(status), "status=FAIL;reason=invalid_max_frames_per_mix");
        return env->NewStringUTF(status);
    }

    std::shared_ptr<GraphExportSession> session;
    try {
        session = std::make_shared<GraphExportSession>();
        session->mixBus = std::make_shared<AudioMixBusNode>(
            kMixNodeId,
            static_cast<int32_t>(sampleRate),
            static_cast<int32_t>(channelCount),
            static_cast<int64_t>(maxFramesPerMix));
        if (!session->graphTopology.addNode(session->mixBus).ok()) {
            std::snprintf(status, sizeof(status), "status=FAIL;reason=graph_add_mix_node_failed");
            return env->NewStringUTF(status);
        }
        session->sampleRate      = static_cast<int32_t>(sampleRate);
        session->channelCount    = static_cast<int32_t>(channelCount);
        session->maxFramesPerMix = static_cast<int64_t>(maxFramesPerMix);

        const uint64_t sid = gNextGraphExportSessionId.fetch_add(1, std::memory_order_relaxed);
        char sidBuf[32];
        std::snprintf(sidBuf, sizeof(sidBuf), "p4agx_%llu", static_cast<unsigned long long>(sid));
        session->sessionId = sidBuf;
    } catch (const std::exception& e) {
        std::snprintf(status, sizeof(status), "status=FAIL;reason=%s", e.what());
        return env->NewStringUTF(status);
    } catch (...) {
        std::snprintf(status, sizeof(status), "status=FAIL;reason=session_construction_failed");
        return env->NewStringUTF(status);
    }

    {
        std::lock_guard<std::mutex> lock(gGraphExportRegistryMutex);
        if (gGraphExportSessions.size() >= kMaxLiveSessions) {
            std::snprintf(status, sizeof(status), "status=FAIL;reason=session_capacity_exceeded");
            return env->NewStringUTF(status);
        }
        gGraphExportSessions[session->sessionId] = session;
    }

    std::snprintf(status, sizeof(status),
        "status=PASS;sessionId=%s;proofBoundary=%s;sampleRate=%d;channelCount=%d;"
        "maxFramesPerMix=%d;mixNodeId=%s;inputPortCount=%zu",
        session->sessionId.c_str(),
        kProofBoundary,
        static_cast<int>(sampleRate),
        static_cast<int>(channelCount),
        static_cast<int>(maxFramesPerMix),
        kMixNodeId,
        session->mixBus->inputPorts().size());
    return env->NewStringUTF(status);
}

// ---------------------------------------------------------------------------
// JNI: addAndroidDagPhase4AudioGraphExportTrack
// Legacy diagnostic add verb, byte-compatible: unit gain, null envelope (no
// envelopes/mixParams entry). Rejected after prepare() so the scheduler's
// generation snapshot stays authoritative. Every track uses
// timelineStartPtsUs=0 and expectedFrameCount=totalFrames (lockstep
// providers, no per-node timeline gating claim) and the 6-arg
// node-owned-transport constructor.
// ---------------------------------------------------------------------------
extern "C" JNIEXPORT jstring JNICALL
Java_com_connects_vanguard_1media_1engine_bridge_VanguardNativeBridge_addAndroidDagPhase4AudioGraphExportTrack(
    JNIEnv* env,
    jobject /* this */,
    jstring sessionIdJ,
    jstring trackIdJ,
    jlong   totalFrames) {

    char status[512];

    const std::string sid = JStringToStdString(env, sessionIdJ);
    const std::shared_ptr<GraphExportSession> session = FindGraphExportSession(sid);
    if (!session) {
        std::snprintf(status, sizeof(status), "status=FAIL;reason=session_not_found");
        return env->NewStringUTF(status);
    }

    std::lock_guard<std::mutex> lock(session->mutex);
    if (session->destroyed) {
        std::snprintf(status, sizeof(status), "status=FAIL;reason=session_destroyed");
        return env->NewStringUTF(status);
    }
    if (session->prepared) {
        std::snprintf(status, sizeof(status), "status=FAIL;reason=session_already_prepared");
        return env->NewStringUTF(status);
    }

    const std::string trackId = JStringToStdString(env, trackIdJ);
    const int64_t frames = static_cast<int64_t>(totalFrames);
    size_t trackIndex = 0;
    if (!AddGraphExportTrackLocked(*session, trackId, frames, /*envelope=*/nullptr,
                                   status, sizeof(status), &trackIndex)) {
        return env->NewStringUTF(status);
    }

    std::snprintf(status, sizeof(status),
        "status=PASS;trackId=%s;trackIndex=%zu;inputPort=%s;totalFrames=%lld;trackCount=%zu",
        trackId.c_str(),
        trackIndex,
        session->mixBus->inputPorts()[trackIndex].id.c_str(),
        static_cast<long long>(frames),
        session->trackOrder.size());
    return env->NewStringUTF(status);
}

// ---------------------------------------------------------------------------
// JNI: addAndroidDagPhase4AudioGraphExportTrackWithEnvelope
// P4-AUDIO-PASS2-NATIVE-GAIN-ENVELOPE production add verb: one atomic call
// builds the native AudioGainEnvelope from the raw spec params (Kotlin only
// converts seconds to integer microseconds) BEFORE any graph mutation, then
// constructs the node, adds it, connects it, and registers
// track/envelope/mixParams together. Any failure — including every
// envelope_* reason — leaves graph, tracks, envelopes and mixParams
// unmutated. Same prepare barrier and lockstep totalFrames semantics as the
// legacy verb.
// ---------------------------------------------------------------------------
extern "C" JNIEXPORT jstring JNICALL
Java_com_connects_vanguard_1media_1engine_bridge_VanguardNativeBridge_addAndroidDagPhase4AudioGraphExportTrackWithEnvelope(
    JNIEnv*      env,
    jobject /* this */,
    jstring      sessionIdJ,
    jstring      trackIdJ,
    jlong        totalFrames,
    jdouble      volume,
    jdouble      mixGain,
    jlong        fadeInUs,
    jlong        fadeOutUs,
    jlong        trackStartUs,
    jlong        trackEndUs,
    jlongArray   keyframeTimesUsJ,
    jdoubleArray keyframeGainsJ) {

    char status[640];

    const std::string sid = JStringToStdString(env, sessionIdJ);
    const std::shared_ptr<GraphExportSession> session = FindGraphExportSession(sid);
    if (!session) {
        std::snprintf(status, sizeof(status), "status=FAIL;reason=session_not_found");
        return env->NewStringUTF(status);
    }

    std::lock_guard<std::mutex> lock(session->mutex);
    if (session->destroyed) {
        std::snprintf(status, sizeof(status), "status=FAIL;reason=session_destroyed");
        return env->NewStringUTF(status);
    }
    if (session->prepared) {
        std::snprintf(status, sizeof(status), "status=FAIL;reason=session_already_prepared");
        return env->NewStringUTF(status);
    }

    // Keyframe arrays travel as a matched pair: both null (static
    // volume/fade path) or both present with identical lengths.
    if ((keyframeTimesUsJ == nullptr) != (keyframeGainsJ == nullptr)) {
        std::snprintf(status, sizeof(status),
            "status=FAIL;reason=envelope_keyframe_array_mismatch");
        return env->NewStringUTF(status);
    }
    size_t rawCount = 0;
    AudioGainEnvelope::Keyframe rawKeyframes[AudioGainEnvelope::kMaxRawKeyframes];
    if (keyframeTimesUsJ != nullptr) {
        const jsize timesLen = env->GetArrayLength(keyframeTimesUsJ);
        const jsize gainsLen = env->GetArrayLength(keyframeGainsJ);
        if (timesLen != gainsLen) {
            std::snprintf(status, sizeof(status),
                "status=FAIL;reason=envelope_keyframe_array_mismatch");
            return env->NewStringUTF(status);
        }
        if (timesLen < 0 ||
            static_cast<size_t>(timesLen) > AudioGainEnvelope::kMaxRawKeyframes) {
            std::snprintf(status, sizeof(status),
                "status=FAIL;reason=envelope_keyframe_count_exceeded:%lld",
                static_cast<long long>(timesLen));
            return env->NewStringUTF(status);
        }
        if (timesLen > 0) {
            jlong   times[AudioGainEnvelope::kMaxRawKeyframes];
            jdouble gains[AudioGainEnvelope::kMaxRawKeyframes];
            env->GetLongArrayRegion(keyframeTimesUsJ, 0, timesLen, times);
            env->GetDoubleArrayRegion(keyframeGainsJ, 0, gainsLen, gains);
            for (jsize i = 0; i < timesLen; ++i) {
                rawKeyframes[i] = AudioGainEnvelope::Keyframe{
                    static_cast<int64_t>(times[i]),
                    static_cast<double>(gains[i]),
                    AudioGainEnvelope::Interpolation::kLinear};
            }
            rawCount = static_cast<size_t>(timesLen);
        }
    }

    // Envelope build happens entirely before any graph mutation.
    AudioGainEnvelope envelope;
    bool gainClamped = false;
    const char* envelopeFail = BuildTrackEnvelope(
        rawCount > 0 ? rawKeyframes : nullptr, rawCount,
        static_cast<double>(volume), static_cast<double>(mixGain),
        static_cast<int64_t>(fadeInUs), static_cast<int64_t>(fadeOutUs),
        static_cast<int64_t>(trackStartUs), static_cast<int64_t>(trackEndUs),
        &envelope, &gainClamped);
    if (envelopeFail != nullptr) {
        std::snprintf(status, sizeof(status), "status=FAIL;reason=%s", envelopeFail);
        return env->NewStringUTF(status);
    }

    const std::string trackId = JStringToStdString(env, trackIdJ);
    const int64_t frames = static_cast<int64_t>(totalFrames);
    size_t trackIndex = 0;
    if (!AddGraphExportTrackLocked(*session, trackId, frames, &envelope,
                                   status, sizeof(status), &trackIndex)) {
        return env->NewStringUTF(status);
    }

    std::snprintf(status, sizeof(status),
        "status=PASS;trackId=%s;trackIndex=%zu;inputPort=%s;totalFrames=%lld;trackCount=%zu;"
        "gainClamped=%s;envelopeKeyframeCount=%zu",
        trackId.c_str(),
        trackIndex,
        session->mixBus->inputPorts()[trackIndex].id.c_str(),
        static_cast<long long>(frames),
        session->trackOrder.size(),
        gainClamped ? "true" : "false",
        session->envelopes[trackId].keyframeCount());
    return env->NewStringUTF(status);
}

// ---------------------------------------------------------------------------
// JNI: prepareAndroidDagPhase4AudioGraphExportSession
// One-way prepare barrier: freezes the topology and constructs the
// auto-discovery GraphAudioScheduler over the session-owned mixParams map
// (per-source unit static gain + non-owning pointer into session->envelopes
// for envelope tracks; legacy tracks have no entry and keep unit gain with
// a null envelope). Fails closed (session stays unprepared, scheduler
// discarded) unless the target is valid and every added track routed.
// ---------------------------------------------------------------------------
extern "C" JNIEXPORT jstring JNICALL
Java_com_connects_vanguard_1media_1engine_bridge_VanguardNativeBridge_prepareAndroidDagPhase4AudioGraphExportSession(
    JNIEnv* env,
    jobject /* this */,
    jstring sessionIdJ) {

    char status[512];

    const std::string sid = JStringToStdString(env, sessionIdJ);
    const std::shared_ptr<GraphExportSession> session = FindGraphExportSession(sid);
    if (!session) {
        std::snprintf(status, sizeof(status), "status=FAIL;reason=session_not_found");
        return env->NewStringUTF(status);
    }

    std::lock_guard<std::mutex> lock(session->mutex);
    if (session->destroyed) {
        std::snprintf(status, sizeof(status), "status=FAIL;reason=session_destroyed");
        return env->NewStringUTF(status);
    }
    if (session->prepared) {
        std::snprintf(status, sizeof(status), "status=FAIL;reason=session_already_prepared");
        return env->NewStringUTF(status);
    }
    if (session->trackOrder.empty()) {
        std::snprintf(status, sizeof(status), "status=FAIL;reason=no_tracks_added");
        return env->NewStringUTF(status);
    }

    try {
        session->scheduler = std::make_unique<GraphAudioScheduler>(
            session->graphTopology, kMixNodeId, AutoDiscoverSourceProviders{},
            &session->mixParams);
    } catch (const std::exception& e) {
        session->scheduler.reset();
        std::snprintf(status, sizeof(status), "status=FAIL;reason=%s", e.what());
        return env->NewStringUTF(status);
    } catch (...) {
        session->scheduler.reset();
        std::snprintf(status, sizeof(status), "status=FAIL;reason=scheduler_construction_failed");
        return env->NewStringUTF(status);
    }

    if (!session->scheduler->targetValid()) {
        session->scheduler.reset();
        std::snprintf(status, sizeof(status), "status=FAIL;reason=invalid_target");
        return env->NewStringUTF(status);
    }
    if (session->scheduler->routedSourceCount() != session->trackOrder.size()) {
        const size_t routed = session->scheduler->routedSourceCount();
        session->scheduler.reset();
        std::snprintf(status, sizeof(status),
            "status=FAIL;reason=routed_source_count_mismatch:%zu/%zu",
            routed, session->trackOrder.size());
        return env->NewStringUTF(status);
    }

    session->snapshotGeneration = session->scheduler->snapshotGeneration();
    session->prepared = true;

    std::snprintf(status, sizeof(status),
        "status=PASS;routedSourceCount=%zu;requestedTrackCount=%zu;snapshotGeneration=%llu",
        session->scheduler->routedSourceCount(),
        session->trackOrder.size(),
        static_cast<unsigned long long>(session->snapshotGeneration));
    return env->NewStringUTF(status);
}

// ---------------------------------------------------------------------------
// JNI: ingestAndroidDagPhase4AudioGraphExportTrackPcm
// Allowed only after prepare() (topology frozen). Pushes interleaved
// little-endian signed PCM16 from a direct ByteBuffer (byte offset 0)
// through the NODE-OWNED ring writer. Only a full write is accepted; any
// partial/rejected write fails closed with the writer's status token and
// the accepted count. Never calls setEos, ingestChunk, or requestSeek.
// ---------------------------------------------------------------------------
extern "C" JNIEXPORT jstring JNICALL
Java_com_connects_vanguard_1media_1engine_bridge_VanguardNativeBridge_ingestAndroidDagPhase4AudioGraphExportTrackPcm(
    JNIEnv* env,
    jobject /* this */,
    jstring sessionIdJ,
    jstring trackIdJ,
    jobject pcmBufferJ,
    jint    frameCount) {

    char status[512];

    const std::string sid = JStringToStdString(env, sessionIdJ);
    const std::shared_ptr<GraphExportSession> session = FindGraphExportSession(sid);
    if (!session) {
        std::snprintf(status, sizeof(status),
            "status=FAIL;reason=session_not_found;acceptedFrames=0");
        return env->NewStringUTF(status);
    }

    std::lock_guard<std::mutex> lock(session->mutex);
    if (session->destroyed) {
        std::snprintf(status, sizeof(status),
            "status=FAIL;reason=session_destroyed;acceptedFrames=0");
        return env->NewStringUTF(status);
    }
    if (!session->prepared) {
        std::snprintf(status, sizeof(status),
            "status=FAIL;reason=session_not_prepared;acceptedFrames=0");
        return env->NewStringUTF(status);
    }

    const std::string trackId = JStringToStdString(env, trackIdJ);
    auto it = session->tracks.find(trackId);
    if (it == session->tracks.end()) {
        std::snprintf(status, sizeof(status),
            "status=FAIL;reason=track_not_found;acceptedFrames=0");
        return env->NewStringUTF(status);
    }
    if (frameCount < 1 || frameCount > kMaxIngestFrames) {
        std::snprintf(status, sizeof(status),
            "status=FAIL;reason=invalid_frame_count;acceptedFrames=0");
        return env->NewStringUTF(status);
    }
    if (!pcmBufferJ) {
        std::snprintf(status, sizeof(status),
            "status=FAIL;reason=null_pcm_buffer;acceptedFrames=0");
        return env->NewStringUTF(status);
    }
    const jlong bufferCapacityBytes = env->GetDirectBufferCapacity(pcmBufferJ);
    if (bufferCapacityBytes < 0) {
        std::snprintf(status, sizeof(status),
            "status=FAIL;reason=non_direct_buffer;acceptedFrames=0");
        return env->NewStringUTF(status);
    }
    void* rawAddr = env->GetDirectBufferAddress(pcmBufferJ);
    if (!rawAddr) {
        std::snprintf(status, sizeof(status),
            "status=FAIL;reason=direct_buffer_address_unavailable;acceptedFrames=0");
        return env->NewStringUTF(status);
    }
    const int64_t requiredBytes =
        static_cast<int64_t>(frameCount) * session->channelCount * 2ll;
    if (static_cast<int64_t>(bufferCapacityBytes) < requiredBytes) {
        std::snprintf(status, sizeof(status),
            "status=FAIL;reason=insufficient_buffer_capacity;acceptedFrames=0");
        return env->NewStringUTF(status);
    }

    DecodedAudioPcmSourceNode& node = *it->second;
    int64_t accepted = 0;
    const WriterStatus writerStatus = node.ringWriter()->write(
        static_cast<const int16_t*>(rawAddr),
        static_cast<int64_t>(frameCount),
        session->sampleRate,
        session->channelCount,
        &accepted);

    if (writerStatus != WriterStatus::kOk || accepted != static_cast<int64_t>(frameCount)) {
        std::snprintf(status, sizeof(status),
            "status=FAIL;reason=ring_write_%s;acceptedFrames=%lld;framesRequested=%d",
            WriterStatusName(writerStatus),
            static_cast<long long>(accepted),
            static_cast<int>(frameCount));
        return env->NewStringUTF(status);
    }

    std::snprintf(status, sizeof(status),
        "status=PASS;trackId=%s;acceptedFrames=%lld;ringAvailableReadFrames=%lld",
        trackId.c_str(),
        static_cast<long long>(accepted),
        static_cast<long long>(node.ring()->availableReadFrames()));
    return env->NewStringUTF(status);
}

// ---------------------------------------------------------------------------
// JNI: renderAndroidDagPhase4AudioGraphExportWindow
// Contiguous export windows only: startFrame must equal the session's
// nextRenderFrame cursor. Provider underrun metrics are snapshotted around
// renderWindow(); any zero-fill growth fails the window closed with
// source_underrun:<trackId> (never a PASS), because zero-filled audio is
// corruption for an export session. kOk and kSilence are the only PASS
// scheduler results; the cursor/metrics advance only on PASS. Every PASS
// also reports the scheduler's envelope telemetry (envelopeApplied /
// envelopeEvaluations / minEffectiveGain / maxEffectiveGain) so Kotlin can
// evidence that the native graph owned the per-frame gain math.
// ---------------------------------------------------------------------------
extern "C" JNIEXPORT jstring JNICALL
Java_com_connects_vanguard_1media_1engine_bridge_VanguardNativeBridge_renderAndroidDagPhase4AudioGraphExportWindow(
    JNIEnv* env,
    jobject /* this */,
    jstring sessionIdJ,
    jlong   startFrame,
    jint    frameCount,
    jobject outPcmBufferJ) {

    char status[896];

    const std::string sid = JStringToStdString(env, sessionIdJ);
    const std::shared_ptr<GraphExportSession> session = FindGraphExportSession(sid);
    if (!session) {
        std::snprintf(status, sizeof(status), "status=FAIL;reason=session_not_found");
        return env->NewStringUTF(status);
    }

    std::lock_guard<std::mutex> lock(session->mutex);
    if (session->destroyed) {
        std::snprintf(status, sizeof(status), "status=FAIL;reason=session_destroyed");
        return env->NewStringUTF(status);
    }
    if (!session->prepared) {
        std::snprintf(status, sizeof(status), "status=FAIL;reason=session_not_prepared");
        return env->NewStringUTF(status);
    }
    if (frameCount < 1 || static_cast<int64_t>(frameCount) > session->maxFramesPerMix) {
        std::snprintf(status, sizeof(status), "status=FAIL;reason=invalid_frame_count");
        return env->NewStringUTF(status);
    }
    if (static_cast<int64_t>(startFrame) != session->nextRenderFrame) {
        std::snprintf(status, sizeof(status),
            "status=FAIL;reason=non_contiguous_window:%lld/%lld",
            static_cast<long long>(session->nextRenderFrame),
            static_cast<long long>(startFrame));
        return env->NewStringUTF(status);
    }
    if (!outPcmBufferJ) {
        std::snprintf(status, sizeof(status), "status=FAIL;reason=null_out_buffer");
        return env->NewStringUTF(status);
    }
    const jlong outCapacityBytes = env->GetDirectBufferCapacity(outPcmBufferJ);
    if (outCapacityBytes < 0) {
        std::snprintf(status, sizeof(status), "status=FAIL;reason=non_direct_buffer");
        return env->NewStringUTF(status);
    }
    void* outAddr = env->GetDirectBufferAddress(outPcmBufferJ);
    if (!outAddr) {
        std::snprintf(status, sizeof(status),
            "status=FAIL;reason=direct_buffer_address_unavailable");
        return env->NewStringUTF(status);
    }
    const int64_t requiredSamples =
        static_cast<int64_t>(frameCount) * session->channelCount;
    if (static_cast<int64_t>(outCapacityBytes) < requiredSamples * 2ll) {
        std::snprintf(status, sizeof(status),
            "status=FAIL;reason=insufficient_buffer_capacity");
        return env->NewStringUTF(status);
    }

    // Per-track provider underrun snapshot (fixed arrays: max 8 tracks).
    uint64_t underrunBefore[kMaxTrackCount]   = {0};
    uint64_t zeroFilledBefore[kMaxTrackCount] = {0};
    for (size_t i = 0; i < session->trackOrder.size(); ++i) {
        RingBufferAudioSampleProvider* provider =
            TrackProvider(*session->tracks[session->trackOrder[i]]);
        underrunBefore[i]   = provider->underrunEvents();
        zeroFilledBefore[i] = provider->framesZeroFilled();
    }

    GraphAudioScheduler::SchedulerOutput out{};
    const SchedulerResult result = session->scheduler->renderWindow(
        static_cast<int64_t>(startFrame),
        static_cast<int64_t>(frameCount),
        static_cast<int16_t*>(outAddr),
        requiredSamples,
        &out);

    // Underrun check first: a zero-filled window is corruption for this
    // export session even when the scheduler itself reported kOk/kSilence.
    for (size_t i = 0; i < session->trackOrder.size(); ++i) {
        RingBufferAudioSampleProvider* provider =
            TrackProvider(*session->tracks[session->trackOrder[i]]);
        if (provider->underrunEvents() != underrunBefore[i] ||
            provider->framesZeroFilled() != zeroFilledBefore[i]) {
            std::snprintf(status, sizeof(status),
                "status=FAIL;reason=source_underrun:%s;schedulerResult=%s",
                session->trackOrder[i].c_str(),
                SchedulerResultName(result));
            return env->NewStringUTF(status);
        }
    }

    if (result != SchedulerResult::kOk && result != SchedulerResult::kSilence) {
        std::snprintf(status, sizeof(status),
            "status=FAIL;reason=scheduler_result:%s", SchedulerResultName(result));
        return env->NewStringUTF(status);
    }

    session->nextRenderFrame += static_cast<int64_t>(frameCount);
    session->windowCount += 1;
    if (out.silence) {
        session->silentWindowCount += 1;
    }

    std::snprintf(status, sizeof(status),
        "status=PASS;framesRendered=%lld;routedTrackCount=%zu;mixCalled=%s;silence=%s;"
        "checksum=%016llx;windowCount=%lld;silentWindowCount=%lld;nextRenderFrame=%lld;"
        "envelopeApplied=%s;envelopeEvaluations=%lld;minEffectiveGain=%.6f;"
        "maxEffectiveGain=%.6f",
        static_cast<long long>(out.framesRendered),
        out.routedTrackCount,
        out.mixCalled ? "true" : "false",
        out.silence ? "true" : "false",
        static_cast<unsigned long long>(out.checksum),
        static_cast<long long>(session->windowCount),
        static_cast<long long>(session->silentWindowCount),
        static_cast<long long>(session->nextRenderFrame),
        out.envelopeApplied ? "true" : "false",
        static_cast<long long>(out.envelopeEvaluations),
        out.minEffectiveGain,
        out.maxEffectiveGain);
    return env->NewStringUTF(status);
}

// ---------------------------------------------------------------------------
// JNI: destroyAndroidDagPhase4AudioGraphExportSession
// Idempotent erase-once under the registry mutex; both the first and any
// repeated destroy report status=PASS (destroyed=true only on the erase).
// An in-flight call that raced the erase keeps its shared_ptr, so the
// session is freed only when the last reference drops.
// ---------------------------------------------------------------------------
extern "C" JNIEXPORT jstring JNICALL
Java_com_connects_vanguard_1media_1engine_bridge_VanguardNativeBridge_destroyAndroidDagPhase4AudioGraphExportSession(
    JNIEnv* env,
    jobject /* this */,
    jstring sessionIdJ) {

    const std::string sid = JStringToStdString(env, sessionIdJ);

    std::shared_ptr<GraphExportSession> session;
    {
        std::lock_guard<std::mutex> lock(gGraphExportRegistryMutex);
        auto it = gGraphExportSessions.find(sid);
        if (it != gGraphExportSessions.end()) {
            session = it->second;
            gGraphExportSessions.erase(it);
        }
    }
    if (session) {
        std::lock_guard<std::mutex> lock(session->mutex);
        session->destroyed = true;
        return env->NewStringUTF("status=PASS;destroyed=true");
    }
    return env->NewStringUTF("status=PASS;destroyed=false;reason=already_destroyed");
}
