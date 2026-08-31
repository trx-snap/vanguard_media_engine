// P4-AUDIO-AAUDIO-NODE-OWNED-SINK-DIAGNOSTIC (Android Phase 4 foundation
// under P4-AUDIO-GRAPH-TRANSPORT-CLOCK / P4-AUDIO-MIXBUS): session-scoped,
// step-driven, TWO-SOURCE closed-loop native audio graph pipeline JNI seam
// (identical node-owned/auto-discovery rig to
// android_phase4_multi_source_node_owned_pipeline_session_jni.cpp) whose
// mixed output is consumed by a MUTED native AAudio diagnostic sink:
//   track0/track1 DecodedAudioPcmSourceNode (6-arg constructor, each owns
//   its ring/writer/provider triple)
//     -> GraphAudioScheduler (AutoDiscoverSourceProviders tag constructor)
//     -> AudioMixBusNode -> ClockedAudioTransportCoordinator
//     -> output AudioSpscAudioRingBuffer
//     -> OWNER-THREAD pump: checksum REAL mixed PCM, then zero-scale it,
//        then push the muted frames into a separate sink
//        AudioSpscAudioRingBuffer
//     -> AAudio data callback: tryPopFrames-or-zero-fill ONLY.
//
// API 24 compatibility (mandatory correction): android minSdk is 24 and
// AAudio is API 26, so this TU NEVER direct-links libaaudio (no `aaudio` in
// target_link_libraries, no <aaudio/AAudio.h> include). The owner thread
// gates on android_get_device_api_level() >= 26, then
// dlopen("libaaudio.so")/dlsym resolves every required entry point before
// any stream is opened, failing closed with status=aaudio_unavailable /
// status=aaudio_symbol_missing:<name>. The API-26 symbol renames are
// handled with the samples-per-frame fallbacks
// (AAudioStreamBuilder_setSamplesPerFrame / AAudioStream_getSamplesPerFrame).
//
// Muted diagnostic (mandatory correction): AAudio has no per-stream
// setVolume analogue, so the owner-thread pump computes the graph output
// checksum over the REAL mixed PCM first, then zero-scales that PCM before
// it enters the callback sink ring. The data callback NEVER applies gain or
// any math policy: it only copies already-muted PCM out of the sink ring or
// zero-fills the shortfall, incrementing atomic counters. The error
// callback only sets atomics. Neither callback allocates, locks, logs,
// calls JNI, or touches the stream lifecycle.
//
// Threading: every non-destroy entry point is owner-thread-only
// (status=wrong_owner_thread otherwise) and, unlike the sibling pipeline
// TUs, destroy/close is ALSO owner-thread-only in this slice because it
// performs the AAudio requestStop/waitForStateChange/close sequence. The
// AAudio data/error callbacks run on the AAudio-owned callback thread and
// are the single deliberate exclusion from the owner-thread guard; the sink
// ring is SPSC with the owner thread as sole producer and the callback
// thread as sole consumer.
//
// Honest non-claims:
// - Diagnostic sink foundation only: no product playback, no editor UI, no
//   export/pass-2 reroute, no streaming/cache, no iOS.
// - No audible-output claim (all callback-fed PCM is zero), no speaker
//   route, no audio focus, no route-change handling, no dead-object
//   recovery, no low-latency/MMAP/EXCLUSIVE mode, no xrun-freedom or
//   latency/glitch claim.
// - No MediaCodec/MediaExtractor ownership in C++, no C++ file IO, no
//   native wall-clock reads (caller-derived sysTimeNs ticks only; the
//   tail-flush clamp derives from the caller-supplied anchor).
// - Spawns no native worker threads itself (the AAudio callback thread is
//   OS-owned); no locks inside the vanguard audio primitives; the only
//   mutex here guards the session registry map lifecycle.
// - Zero native steady-state allocation on the owner-thread paths after
//   open: status strings are fixed stack char[]s and the pump moves PCM
//   through a fixed stack scratch. AAudio's own internals are outside that
//   claim.
//
// This translation unit owns its own anonymous-namespace session registry,
// registry mutex, and handle space: handles minted here are NOT
// interchangeable with any other diagnostic session registry.
//
// This translation unit is Android-only and must NOT be included in iOS or
// host builds; it is added via the Android-only target_sources block in
// src/CMakeLists.txt.
//
// JNI entry points (VanguardNativeBridge.kt companion object):
//   createAaudioNodeOwnedSinkSmokeSession  -> jlong handle (0 on failure)
//   ingestAaudioNodeOwnedSinkPcm16         -> jstring key=value
//   startAaudioNodeOwnedSink               -> jstring key=value
//   stepAaudioNodeOwnedSink                -> jstring key=value
//   pumpAaudioNodeOwnedSink                -> jstring key=value
//   seekAaudioNodeOwnedSink                -> jstring key=value
//   setAaudioNodeOwnedSinkEos              -> jstring key=value
//   snapshotAaudioNodeOwnedSink            -> jstring key=value
//   destroyAaudioNodeOwnedSinkSmokeSession -> jstring key=value

#include <jni.h>

#include <android/api-level.h>
#include <dlfcn.h>

#include <algorithm>
#include <atomic>
#include <cstdarg>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <limits>
#include <memory>
#include <mutex>
#include <thread>
#include <unordered_map>

#include "vanguard/audio/audio_clock.h"
#include "vanguard/audio/audio_decoder_ring_writer.h"
#include "vanguard/audio/audio_mix_bus_node.h"
#include "vanguard/audio/audio_ring_buffer.h"
#include "vanguard/audio/audio_sample_provider.h"
#include "vanguard/audio/clocked_audio_transport_coordinator.h"
#include "vanguard/audio/decoded_audio_pcm_source_node.h"
#include "vanguard/audio/graph_audio_scheduler.h"
#include "vanguard/audio/ring_buffer_audio_sample_provider.h"
#include "vanguard/graph/graph.h"

namespace {

// Canonical proof boundary, embedded verbatim in the snapshot status and
// carried identically by the Kotlin driver/coordinator payload.
constexpr const char* kProofBoundary =
    "native_android_aaudio_callback_sink_diagnostic_only_runtime_dlopen_no_direct_libaaudio_link_min_sdk24_safe_real_decoder_plus_synthetic_second_track_two_decoded_audio_source_nodes_own_ring_writer_provider_by_composition_scheduler_auto_discovery_from_graph_topology_muted_owner_thread_zero_scale_before_callback_ring_callback_pop_or_silence_only_no_product_no_editor_no_connects_app_no_export_reroute_no_pass2_graph_reroute_no_streaming_no_cache_no_ios_no_audible_output_claim_no_speaker_route_no_audio_focus_no_route_change_no_dead_object_recovery_no_low_latency_mmap_exclusive_no_xrun_freedom_no_latency_glitch_claim";

using vanguard::audio::AudioClock;
using vanguard::audio::AudioDecoderRingWriter;
using vanguard::audio::AudioMixBusNode;
using vanguard::audio::AudioSpscAudioRingBuffer;
using vanguard::audio::AutoDiscoverSourceProviders;
using vanguard::audio::ClockedAudioTransportCoordinator;
using vanguard::audio::DecodedAudioPcmSourceNode;
using vanguard::audio::GraphAudioScheduler;
using vanguard::audio::RingBufferAudioSampleProvider;
using vanguard::core::Status;
using vanguard::graph::Graph;
using DispatchResult = ClockedAudioTransportCoordinator::DispatchResult;
using DispatchOutput = ClockedAudioTransportCoordinator::DispatchOutput;
using WriterStatus   = AudioDecoderRingWriter::Status;

constexpr size_t  kMaxLiveSessions        = 4;
constexpr int64_t kMaxIngestFramesPerCall = AudioDecoderRingWriter::kMaxWriteFrames;      // 8192
constexpr int64_t kMaxRingCapacityFrames  = AudioSpscAudioRingBuffer::kMaxCapacityFrames; // 65536
constexpr int64_t kPumpChunkFrames        = 512;
// 128 chunks * 512 frames covers the largest legal ring in one call while
// keeping the pump loop strictly bounded.
constexpr int     kMaxPumpIterations      = 128;
constexpr int64_t kMicrosPerSecond        = 1'000'000LL;
constexpr int64_t kInt64Max               = std::numeric_limits<int64_t>::max();

constexpr const char* kMixNodeId     = "aaudio_node_owned_sink_mix";
constexpr const char* kSource0NodeId = "aaudio_node_owned_sink_src0";
constexpr const char* kSource1NodeId = "aaudio_node_owned_sink_src1";

// ---------------------------------------------------------------------------
// Minimal local AAudio ABI surface. Deliberately NOT <aaudio/AAudio.h>: this
// TU must stay loadable on API 24 devices, so every AAudio type/constant is
// restated here (values fixed by the NDK ABI) and every function is reached
// exclusively through dlsym'd pointers.
// ---------------------------------------------------------------------------
struct VgAAudioStreamBuilder; // opaque
struct VgAAudioStream;        // opaque

constexpr int32_t kAaudioOk                     = 0;  // AAUDIO_OK
constexpr int32_t kAaudioDirectionOutput        = 0;  // AAUDIO_DIRECTION_OUTPUT
constexpr int32_t kAaudioFormatPcmI16           = 1;  // AAUDIO_FORMAT_PCM_I16
constexpr int32_t kAaudioSharingModeShared      = 1;  // AAUDIO_SHARING_MODE_SHARED
constexpr int32_t kAaudioPerformanceModeNone    = 10; // AAUDIO_PERFORMANCE_MODE_NONE
constexpr int32_t kAaudioCallbackResultContinue = 0;  // AAUDIO_CALLBACK_RESULT_CONTINUE
constexpr int32_t kAaudioStreamStateStarting    = 3;  // AAUDIO_STREAM_STATE_STARTING
constexpr int32_t kAaudioStreamStateStarted     = 4;  // AAUDIO_STREAM_STATE_STARTED
constexpr int32_t kAaudioStreamStateStopping    = 9;  // AAUDIO_STREAM_STATE_STOPPING
constexpr int64_t kAaudioStateWaitTimeoutNs     = 2'000'000'000LL;
constexpr int32_t kMinAaudioApiLevel            = 26;

using VgAaudioDataCallback  = int32_t (*)(VgAAudioStream*, void*, void*, int32_t);
using VgAaudioErrorCallback = void (*)(VgAAudioStream*, void*, int32_t);

// dlsym'd function-pointer table; resolved on the owner thread before any
// stream is opened. `setChannelCount`/`getChannelCount` fall back to the
// API-26 samples-per-frame exports (identical signatures) exactly like the
// well-known AAudio loaders do.
struct AaudioApi {
    int32_t (*createStreamBuilder)(VgAAudioStreamBuilder**)                          = nullptr;
    void    (*builderSetDirection)(VgAAudioStreamBuilder*, int32_t)                  = nullptr;
    void    (*builderSetSampleRate)(VgAAudioStreamBuilder*, int32_t)                 = nullptr;
    void    (*builderSetChannelCount)(VgAAudioStreamBuilder*, int32_t)               = nullptr;
    void    (*builderSetFormat)(VgAAudioStreamBuilder*, int32_t)                     = nullptr;
    void    (*builderSetSharingMode)(VgAAudioStreamBuilder*, int32_t)                = nullptr;
    void    (*builderSetPerformanceMode)(VgAAudioStreamBuilder*, int32_t)            = nullptr;
    void    (*builderSetDataCallback)(VgAAudioStreamBuilder*, VgAaudioDataCallback, void*)   = nullptr;
    void    (*builderSetErrorCallback)(VgAAudioStreamBuilder*, VgAaudioErrorCallback, void*) = nullptr;
    int32_t (*builderOpenStream)(VgAAudioStreamBuilder*, VgAAudioStream**)           = nullptr;
    int32_t (*builderDelete)(VgAAudioStreamBuilder*)                                 = nullptr;
    int32_t (*streamRequestStart)(VgAAudioStream*)                                   = nullptr;
    int32_t (*streamRequestStop)(VgAAudioStream*)                                    = nullptr;
    int32_t (*streamWaitForStateChange)(VgAAudioStream*, int32_t, int32_t*, int64_t) = nullptr;
    int32_t (*streamClose)(VgAAudioStream*)                                          = nullptr;
    int32_t (*streamGetSampleRate)(VgAAudioStream*)                                  = nullptr;
    int32_t (*streamGetChannelCount)(VgAAudioStream*)                                = nullptr;
    int32_t (*streamGetFormat)(VgAAudioStream*)                                      = nullptr;
    int32_t (*streamGetState)(VgAAudioStream*)                                       = nullptr;
};

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

// 1:1 mapping of all 13 ClockedAudioTransportCoordinator::DispatchResult
// values to distinct status tokens.
const char* DispatchResultName(DispatchResult r) {
    switch (r) {
        case DispatchResult::kOk:                   return "dispatch_ok";
        case DispatchResult::kSilence:              return "dispatch_silence";
        case DispatchResult::kNoFramesDue:          return "no_frames_due";
        case DispatchResult::kBackpressure:         return "output_backpressure";
        case DispatchResult::kAwaitingSeekAck:      return "awaiting_seek_ack";
        case DispatchResult::kNotStarted:           return "not_started";
        case DispatchResult::kPaused:               return "paused";
        case DispatchResult::kNonMonotonicTime:     return "non_monotonic_time";
        case DispatchResult::kNonUnitySpeed:        return "non_unity_speed";
        case DispatchResult::kSchedulerError:       return "scheduler_error";
        case DispatchResult::kRingPushShortfall:    return "ring_push_shortfall";
        case DispatchResult::kClockError:           return "clock_error";
        case DispatchResult::kInvalidConfiguration: return "invalid_configuration";
    }
    return "unknown";
}

// Same simple signed-sample accumulation shape as the adjacent pipeline
// seams: checksum = checksum * 31 + uint16(sample).
uint64_t AccumulateChecksum(uint64_t checksum, const int16_t* samples, int64_t count) {
    for (int64_t i = 0; i < count; ++i) {
        checksum = checksum * 31u + static_cast<uint64_t>(static_cast<uint16_t>(samples[i]));
    }
    return checksum;
}

bool IsPowerOfTwoInRingRange(int64_t v) {
    return v >= 64 && v <= kMaxRingCapacityFrames && (v & (v - 1)) == 0;
}

// Bounded stack-buffer appender used to build the wider status strings from
// several snprintf pieces without any heap allocation. Overflow is latched
// instead of silently truncating; callers must check overflowed() and fail
// closed.
class StatusAppender {
public:
    StatusAppender(char* buf, size_t cap) : buf_(buf), cap_(cap) {
        if (cap_ > 0) buf_[0] = '\0';
    }

    void appendf(const char* fmt, ...) {
        if (overflow_ || len_ >= cap_) { overflow_ = true; return; }
        va_list args;
        va_start(args, fmt);
        const int written = std::vsnprintf(buf_ + len_, cap_ - len_, fmt, args);
        va_end(args);
        if (written < 0 || static_cast<size_t>(written) >= cap_ - len_) {
            overflow_ = true;
            return;
        }
        len_ += static_cast<size_t>(written);
    }

    bool overflowed() const { return overflow_; }

private:
    char*  buf_;
    size_t cap_;
    size_t len_{0};
    bool   overflow_{false};
};

// Populates the one-mix/two-source diagnostic topology before the scheduler
// member snapshots and walks the graph generation; called from the
// session's member initializer list only. Edge-insertion order is the
// auto-discovery routed order: src0 -> primary_audio_in first,
// src1 -> secondary_audio_in second.
const Graph& PrepareTopology(Graph& g,
                             const std::shared_ptr<AudioMixBusNode>& mixBus,
                             const std::shared_ptr<DecodedAudioPcmSourceNode>& sourceNode0,
                             const std::shared_ptr<DecodedAudioPcmSourceNode>& sourceNode1) {
    (void)g.addNode(mixBus);
    (void)g.addNode(sourceNode0);
    (void)g.addNode(sourceNode1);
    (void)g.connect(kSource0NodeId, "audio_out", kMixNodeId, "primary_audio_in");
    (void)g.connect(kSource1NodeId, "audio_out", kMixNodeId, "secondary_audio_in");
    return g;
}

// ---------------------------------------------------------------------------
// Diagnostic AAudio-sink session over the two-source node-owned graph rig.
// The graph-side members mirror MultiSourceNodeOwnedPipelineSession exactly;
// this session adds a second SPSC ring (sinkRing) carrying only
// already-muted PCM to the AAudio data callback, the dlsym'd AAudio API
// table, the stream handle, and the callback-thread atomics. All non-atomic
// counters are owner-thread-private plain state.
// ---------------------------------------------------------------------------
struct AaudioNodeOwnedSinkSession {
    Graph                                       graphTopology;
    std::shared_ptr<AudioMixBusNode>            mixBus;
    std::shared_ptr<DecodedAudioPcmSourceNode>  sourceNode0;
    std::shared_ptr<DecodedAudioPcmSourceNode>  sourceNode1;
    AudioSpscAudioRingBuffer                    outputRing;
    // Muted PCM feed for the AAudio data callback: owner thread is the sole
    // producer (pump), the AAudio callback thread the sole consumer.
    AudioSpscAudioRingBuffer                    sinkRing;
    GraphAudioScheduler                         scheduler;
    AudioClock                                  clock;
    ClockedAudioTransportCoordinator            coordinator;
    std::thread::id                             ownerThreadId;

    int32_t sampleRate;
    int32_t channelCount;
    int64_t maxFramesPerMix;

    // Caller-supplied clock anchor from the last successful start/seek; the
    // tail-flush sysTimeNs clamp is derived from this pair only (never a
    // wall clock).
    int64_t anchorMediaPtsUs{0};
    int64_t anchorSysTimeNs{0};
    bool    started{false};

    // AAudio runtime loading + stream state (owner-thread-only mutation).
    void*     aaudioLib{nullptr};
    AaudioApi aaudio{};
    VgAAudioStream* stream{nullptr};
    bool aaudioRuntimeAvailable{false};
    bool aaudioSymbolsResolved{false};
    bool aaudioChannelCountSymbolFallback{false};
    bool aaudioStreamOpen{false};
    bool aaudioConfigVerified{false};
    bool aaudioStreamStarted{false};
    int32_t aaudioStreamSampleRate{0};
    int32_t aaudioStreamChannelCount{0};
    int32_t aaudioStreamFormat{0};
    int32_t deviceApiLevel{0};

    // AAudio-callback-thread counters. The callback only ever mutates these
    // atomics (plus the sink ring read index); an owner-thread snapshot
    // taken while the stream runs may observe requested ahead of
    // served+silence by at most one callback burst, so the coherent final
    // values are re-read after close in destroy.
    std::atomic<uint64_t> callbackInvocationCount{0};
    std::atomic<uint64_t> callbackFramesRequested{0};
    std::atomic<uint64_t> callbackFramesServed{0};
    std::atomic<uint64_t> callbackSilenceFrames{0};
    std::atomic<uint64_t> callbackShortReads{0};
    std::atomic<uint64_t> errorCallbackCount{0};
    std::atomic<int32_t>  lastErrorCallbackResult{0};

    uint64_t nativeAcceptedChecksum[2]{0, 0};
    int64_t  totalFramesAccepted[2]{0, 0};
    // Checksum over the REAL mixed PCM popped from the output ring, taken
    // BEFORE the owner-thread zero-scale.
    uint64_t nativeOutputDrainChecksum{0};
    int64_t  totalOutputFramesPumped{0};
    // Checksum over the zeroed frames actually pushed to the sink ring;
    // stays 0x0 while every pushed sample is zero (c = c*31 + 0).
    uint64_t mutedSinkChecksum{0};
    int64_t  totalMutedFramesPushed{0};
    // Latched false if any non-zero sample were ever about to enter the
    // sink ring (never expected: the pump memsets the scratch first).
    bool mutedOutputOk{true};
    // Latched true if the sink ring ever accepted fewer frames than the
    // pump popped (never expected: the pump clamps to sink write space).
    bool sinkPushShortfallSeen{false};

    AaudioNodeOwnedSinkSession(int32_t sampleRateIn,
                               int32_t channelCountIn,
                               int64_t expectedFrameCountIn,
                               int64_t sourceRingCapacityFrames,
                               int64_t outputRingCapacityFrames,
                               int64_t sinkRingCapacityFrames,
                               int64_t maxFramesPerMixIn)
        : graphTopology(),
          mixBus(std::make_shared<AudioMixBusNode>(
              kMixNodeId, sampleRateIn, channelCountIn, maxFramesPerMixIn)),
          sourceNode0(std::make_shared<DecodedAudioPcmSourceNode>(
              kSource0NodeId, sampleRateIn, channelCountIn, expectedFrameCountIn,
              /*timelineStartPtsUs=*/0, sourceRingCapacityFrames)),
          sourceNode1(std::make_shared<DecodedAudioPcmSourceNode>(
              kSource1NodeId, sampleRateIn, channelCountIn, expectedFrameCountIn,
              /*timelineStartPtsUs=*/0, sourceRingCapacityFrames)),
          outputRing(sampleRateIn, channelCountIn, outputRingCapacityFrames),
          sinkRing(sampleRateIn, channelCountIn, sinkRingCapacityFrames),
          scheduler(PrepareTopology(graphTopology, mixBus, sourceNode0, sourceNode1),
                    kMixNodeId, AutoDiscoverSourceProviders{}),
          clock(),
          coordinator(clock, scheduler, outputRing),
          ownerThreadId(std::this_thread::get_id()),
          sampleRate(sampleRateIn),
          channelCount(channelCountIn),
          maxFramesPerMix(maxFramesPerMixIn) {}

    // Owner-thread stop/close of the AAudio stream; also the destructor
    // backstop (destroy always closes before erasing, so the backstop is a
    // no-op on every normal path). Never called from any AAudio callback.
    void closeAaudioStream() {
        if (stream && aaudio.streamRequestStop && aaudio.streamGetState &&
            aaudio.streamWaitForStateChange && aaudio.streamClose) {
            (void)aaudio.streamRequestStop(stream);
            int32_t state = aaudio.streamGetState(stream);
            int guard = 0;
            while ((state == kAaudioStreamStateStarting ||
                    state == kAaudioStreamStateStarted ||
                    state == kAaudioStreamStateStopping) && guard++ < 3) {
                int32_t next = state;
                if (aaudio.streamWaitForStateChange(
                        stream, state, &next, kAaudioStateWaitTimeoutNs) != kAaudioOk) {
                    break;
                }
                state = next;
            }
            (void)aaudio.streamClose(stream);
        }
        stream = nullptr;
        aaudioStreamStarted = false;
        aaudioStreamOpen = false;
        if (aaudioLib) {
            (void)dlclose(aaudioLib);
            aaudioLib = nullptr;
        }
    }

    ~AaudioNodeOwnedSinkSession() { closeAaudioStream(); }

    std::shared_ptr<DecodedAudioPcmSourceNode>& sourceNodeAt(int t) {
        return t == 0 ? sourceNode0 : sourceNode1;
    }

    // The 7-arg session constructor always builds both nodes through the
    // 6-arg node constructor, so both node-owned triples are present after
    // a successful create (the create entry point fails closed on
    // !ownsRing() before registering the handle).
    AudioSpscAudioRingBuffer& sourceRingAt(int t) { return *sourceNodeAt(t)->ring(); }
    AudioDecoderRingWriter&   writerAt(int t)     { return *sourceNodeAt(t)->ringWriter(); }
    // The 6-arg constructor's owned provider is always a
    // RingBufferAudioSampleProvider, so this downcast of the node's
    // base-typed accessor is exact (diagnostics-only metric access).
    RingBufferAudioSampleProvider& providerAt(int t) {
        return *static_cast<RingBufferAudioSampleProvider*>(
            sourceNodeAt(t)->audioSampleProvider());
    }
};

// ---------------------------------------------------------------------------
// AAudio callbacks. EXCLUDED from the JNI owner-thread guard: they run on
// the AAudio-owned callback thread. The data callback performs no heap
// allocation, no mutex, no JNI, no logging, no stream lifecycle call, no
// file/network IO, and no sleep: it only pops already-muted PCM from the
// sink ring into audioData and zero-fills any shortfall, updating atomics.
// ---------------------------------------------------------------------------
int32_t AaudioSinkDataCallback(VgAAudioStream* /* stream */,
                               void* userData,
                               void* audioData,
                               int32_t numFrames) {
    auto* s = static_cast<AaudioNodeOwnedSinkSession*>(userData);
    s->callbackInvocationCount.fetch_add(1, std::memory_order_relaxed);
    if (numFrames <= 0) {
        return kAaudioCallbackResultContinue;
    }
    s->callbackFramesRequested.fetch_add(
        static_cast<uint64_t>(numFrames), std::memory_order_relaxed);
    auto* out = static_cast<int16_t*>(audioData);
    int64_t served = s->sinkRing.tryPopFrames(out, numFrames);
    if (served < 0) served = 0;
    if (served > 0) {
        s->callbackFramesServed.fetch_add(
            static_cast<uint64_t>(served), std::memory_order_relaxed);
    }
    if (served < numFrames) {
        const int64_t missing = numFrames - served;
        std::memset(out + served * s->channelCount, 0,
                    static_cast<size_t>(missing) * s->channelCount * sizeof(int16_t));
        s->callbackSilenceFrames.fetch_add(
            static_cast<uint64_t>(missing), std::memory_order_relaxed);
        s->callbackShortReads.fetch_add(1, std::memory_order_relaxed);
    }
    return kAaudioCallbackResultContinue;
}

// Error callback: only sets atomics; never stops/closes/reads the stream.
void AaudioSinkErrorCallback(VgAAudioStream* /* stream */,
                             void* userData,
                             int32_t error) {
    auto* s = static_cast<AaudioNodeOwnedSinkSession*>(userData);
    s->errorCallbackCount.fetch_add(1, std::memory_order_relaxed);
    s->lastErrorCallbackResult.store(error, std::memory_order_relaxed);
}

// Resolves the full AAudio API table from an already-dlopen'd libaaudio.
// On a missing symbol, writes the plain export name into
// missingNameOut/missingNameCap and returns false.
bool ResolveAaudioApi(void* lib, AaudioApi* api, char* missingNameOut, size_t missingNameCap) {
    struct Entry {
        const char* name;
        const char* fallbackName; // nullptr when there is no legacy alias
        void**      slot;
    };
    const Entry entries[] = {
        {"AAudio_createStreamBuilder", nullptr,
         reinterpret_cast<void**>(&api->createStreamBuilder)},
        {"AAudioStreamBuilder_setDirection", nullptr,
         reinterpret_cast<void**>(&api->builderSetDirection)},
        {"AAudioStreamBuilder_setSampleRate", nullptr,
         reinterpret_cast<void**>(&api->builderSetSampleRate)},
        // Renamed after API 26; the samples-per-frame export has the same
        // signature/behavior for interleaved PCM16.
        {"AAudioStreamBuilder_setChannelCount", "AAudioStreamBuilder_setSamplesPerFrame",
         reinterpret_cast<void**>(&api->builderSetChannelCount)},
        {"AAudioStreamBuilder_setFormat", nullptr,
         reinterpret_cast<void**>(&api->builderSetFormat)},
        {"AAudioStreamBuilder_setSharingMode", nullptr,
         reinterpret_cast<void**>(&api->builderSetSharingMode)},
        {"AAudioStreamBuilder_setPerformanceMode", nullptr,
         reinterpret_cast<void**>(&api->builderSetPerformanceMode)},
        {"AAudioStreamBuilder_setDataCallback", nullptr,
         reinterpret_cast<void**>(&api->builderSetDataCallback)},
        {"AAudioStreamBuilder_setErrorCallback", nullptr,
         reinterpret_cast<void**>(&api->builderSetErrorCallback)},
        {"AAudioStreamBuilder_openStream", nullptr,
         reinterpret_cast<void**>(&api->builderOpenStream)},
        {"AAudioStreamBuilder_delete", nullptr,
         reinterpret_cast<void**>(&api->builderDelete)},
        {"AAudioStream_requestStart", nullptr,
         reinterpret_cast<void**>(&api->streamRequestStart)},
        {"AAudioStream_requestStop", nullptr,
         reinterpret_cast<void**>(&api->streamRequestStop)},
        {"AAudioStream_waitForStateChange", nullptr,
         reinterpret_cast<void**>(&api->streamWaitForStateChange)},
        {"AAudioStream_close", nullptr,
         reinterpret_cast<void**>(&api->streamClose)},
        {"AAudioStream_getSampleRate", nullptr,
         reinterpret_cast<void**>(&api->streamGetSampleRate)},
        {"AAudioStream_getChannelCount", "AAudioStream_getSamplesPerFrame",
         reinterpret_cast<void**>(&api->streamGetChannelCount)},
        {"AAudioStream_getFormat", nullptr,
         reinterpret_cast<void**>(&api->streamGetFormat)},
        {"AAudioStream_getState", nullptr,
         reinterpret_cast<void**>(&api->streamGetState)},
    };
    for (const Entry& e : entries) {
        void* sym = dlsym(lib, e.name);
        if (!sym && e.fallbackName) {
            sym = dlsym(lib, e.fallbackName);
        }
        if (!sym) {
            std::snprintf(missingNameOut, missingNameCap, "%s", e.name);
            return false;
        }
        *e.slot = sym;
    }
    return true;
}

// ---------------------------------------------------------------------------
// Session registry. Private to this TU: its mutex guards only this lifecycle
// map (create/lookup/destroy), never the audio primitives or the AAudio
// callbacks, and its handle space is disjoint from every other diagnostic
// session registry.
// ---------------------------------------------------------------------------
std::mutex gAaudioSinkRegistryMutex;
std::unordered_map<int64_t, std::shared_ptr<AaudioNodeOwnedSinkSession>> gAaudioSinkSessions;
int64_t gNextAaudioSinkHandle = 1; // guarded by gAaudioSinkRegistryMutex

std::shared_ptr<AaudioNodeOwnedSinkSession> FindAaudioSinkSession(jlong handle) {
    std::lock_guard<std::mutex> lock(gAaudioSinkRegistryMutex);
    auto it = gAaudioSinkSessions.find(static_cast<int64_t>(handle));
    return it == gAaudioSinkSessions.end() ? nullptr : it->second;
}

} // namespace

// ---------------------------------------------------------------------------
// JNI: createAaudioNodeOwnedSinkSmokeSession
// Fail-closed construction validation for the GRAPH RIG ONLY (no AAudio
// touch: the runtime gate/dlopen/open all happen inside start, which can
// report string statuses). Returns 0 on any invalid input, when either
// source node does not own its transport, when the auto-discovered
// two-track route did not resolve exactly, or when the live-session cap is
// reached.
// ---------------------------------------------------------------------------
extern "C" JNIEXPORT jlong JNICALL
Java_com_connects_vanguard_1media_1engine_bridge_VanguardNativeBridge_00024Companion_createAaudioNodeOwnedSinkSmokeSession(
    JNIEnv* /* env */,
    jobject /* companion */,
    jint sampleRate,
    jint channelCount,
    jint expectedFrameCount,
    jint sourceRingCapacityFrames,
    jint outputRingCapacityFrames,
    jint sinkRingCapacityFrames,
    jint maxFramesPerMix) {

    const int64_t expFrames = static_cast<int64_t>(expectedFrameCount);
    const int64_t srcCap    = static_cast<int64_t>(sourceRingCapacityFrames);
    const int64_t outCap    = static_cast<int64_t>(outputRingCapacityFrames);
    const int64_t sinkCap   = static_cast<int64_t>(sinkRingCapacityFrames);
    const int64_t mfpm      = static_cast<int64_t>(maxFramesPerMix);

    if (sampleRate < 8000 || sampleRate > 192000) return 0;
    if (channelCount != 1 && channelCount != 2) return 0;
    // Mirrors DecodedAudioPcmSourceNode's own (0, 10*sampleRate] bound so an
    // out-of-range expected frame count fails closed as handle=0 here.
    if (expFrames < 1 || expFrames > 10ll * static_cast<int64_t>(sampleRate)) return 0;
    if (mfpm < 1 || mfpm > 8192) return 0;
    if (!IsPowerOfTwoInRingRange(srcCap)) return 0;
    if (!IsPowerOfTwoInRingRange(outCap)) return 0;
    if (!IsPowerOfTwoInRingRange(sinkCap)) return 0;
    if (outCap < mfpm) return 0;
    if (sinkCap < mfpm) return 0;
    if (srcCap < 2 * mfpm) return 0;

    std::shared_ptr<AaudioNodeOwnedSinkSession> session;
    try {
        session = std::make_shared<AaudioNodeOwnedSinkSession>(
            static_cast<int32_t>(sampleRate),
            static_cast<int32_t>(channelCount),
            expFrames, srcCap, outCap, sinkCap, mfpm);
    } catch (...) {
        return 0;
    }

    // Fail closed unless BOTH nodes own their transport AND the
    // auto-discovery route resolved to exactly the two intended node-owned
    // source tracks in the intended edge order.
    if (!session->sourceNode0->ownsRing() ||
        !session->sourceNode1->ownsRing() ||
        !session->scheduler.targetValid() ||
        session->scheduler.routedSourceCount() != 2 ||
        session->scheduler.routedSourceIdAt(0) != kSource0NodeId ||
        session->scheduler.routedSourceIdAt(1) != kSource1NodeId) {
        return 0;
    }

    std::lock_guard<std::mutex> lock(gAaudioSinkRegistryMutex);
    if (gAaudioSinkSessions.size() >= kMaxLiveSessions) return 0;
    const int64_t handle = gNextAaudioSinkHandle++;
    gAaudioSinkSessions[handle] = std::move(session);
    return static_cast<jlong>(handle);
}

// ---------------------------------------------------------------------------
// JNI: ingestAaudioNodeOwnedSinkPcm16
// Owner-thread-only producer side for one track, writing through that
// track's NODE-OWNED sourceNode->ringWriter(). Identical semantics to the
// multi-source node-owned ingest seam.
// ---------------------------------------------------------------------------
extern "C" JNIEXPORT jstring JNICALL
Java_com_connects_vanguard_1media_1engine_bridge_VanguardNativeBridge_00024Companion_ingestAaudioNodeOwnedSinkPcm16(
    JNIEnv* env,
    jobject /* companion */,
    jlong sessionHandle,
    jint trackIndex,
    jobject pcmBufferJ,
    jint frameCount) {

    char status[896];

    auto replyReject = [&](const char* token) -> jstring {
        std::snprintf(status, sizeof(status),
            "status=%s;trackIndex=%d;framesRequested=%d;framesAccepted=0",
            token, static_cast<int>(trackIndex), static_cast<int>(frameCount));
        return env->NewStringUTF(status);
    };

    const std::shared_ptr<AaudioNodeOwnedSinkSession> session =
        FindAaudioSinkSession(sessionHandle);
    if (!session) {
        return replyReject("not_found");
    }
    if (std::this_thread::get_id() != session->ownerThreadId) {
        return replyReject("wrong_owner_thread");
    }
    if (trackIndex != 0 && trackIndex != 1) {
        return replyReject("invalid_track_index");
    }
    if (frameCount <= 0) {
        return replyReject("invalid_frame_count");
    }
    if (!pcmBufferJ) {
        return replyReject("null_pcm_buffer");
    }

    const jlong bufferCapacityBytes = env->GetDirectBufferCapacity(pcmBufferJ);
    if (bufferCapacityBytes < 0) {
        return replyReject("non_direct_buffer");
    }
    void* rawAddr = env->GetDirectBufferAddress(pcmBufferJ);
    if (!rawAddr) {
        return replyReject("direct_buffer_address_unavailable");
    }

    const int64_t bytesPerFrame = 2ll * session->channelCount;
    const int64_t capacityFramesFromBuffer = static_cast<int64_t>(bufferCapacityBytes) / bytesPerFrame;
    if (capacityFramesFromBuffer <= 0) {
        return replyReject("insufficient_buffer_capacity");
    }

    const int     track = static_cast<int>(trackIndex);
    const int64_t framesToWrite = std::min<int64_t>(
        {static_cast<int64_t>(frameCount), kMaxIngestFramesPerCall, capacityFramesFromBuffer});

    AaudioNodeOwnedSinkSession& s = *session;
    const int16_t* pcm = static_cast<const int16_t*>(rawAddr);
    int64_t framesAccepted = 0;
    const WriterStatus writerStatus = s.writerAt(track).write(
        pcm, framesToWrite, s.sampleRate, s.channelCount, &framesAccepted);

    if (framesAccepted > 0) {
        s.nativeAcceptedChecksum[track] = AccumulateChecksum(
            s.nativeAcceptedChecksum[track], pcm, framesAccepted * s.channelCount);
        s.totalFramesAccepted[track] += framesAccepted;
    }

    const AudioDecoderRingWriter::Metrics& m = s.writerAt(track).metrics();
    std::snprintf(status, sizeof(status),
        "status=ok;trackIndex=%d;framesRequested=%d;framesAccepted=%lld;writerStatus=%s;"
        "writerAvailableToWrite=%lld;sourceAvailableReadFrames=%lld;"
        "writerTotalFramesWritten=%llu;writerPartialWriteEvents=%llu;"
        "writerBackpressureRejects=%llu;"
        "nativeAcceptedChecksumHex=%016llx;totalFramesAccepted=%lld;"
        "totalFramesAcceptedTrack0=%lld;totalFramesAcceptedTrack1=%lld;"
        "sourceAvailableReadFramesTrack0=%lld;sourceAvailableReadFramesTrack1=%lld",
        track,
        static_cast<int>(frameCount),
        static_cast<long long>(framesAccepted),
        WriterStatusName(writerStatus),
        static_cast<long long>(s.sourceRingAt(track).availableWriteFrames()),
        static_cast<long long>(s.sourceRingAt(track).availableReadFrames()),
        static_cast<unsigned long long>(m.totalFramesWritten),
        static_cast<unsigned long long>(m.partialWriteEvents),
        static_cast<unsigned long long>(m.backpressureRejects),
        static_cast<unsigned long long>(s.nativeAcceptedChecksum[track]),
        static_cast<long long>(s.totalFramesAccepted[track]),
        static_cast<long long>(s.totalFramesAccepted[0]),
        static_cast<long long>(s.totalFramesAccepted[1]),
        static_cast<long long>(s.sourceRingAt(0).availableReadFrames()),
        static_cast<long long>(s.sourceRingAt(1).availableReadFrames()));
    return env->NewStringUTF(status);
}

// ---------------------------------------------------------------------------
// JNI: startAaudioNodeOwnedSink
// Owner-thread-only, at most once per session. Full staged AAudio bring-up
// BEFORE the transport clock starts, each stage failing closed with a
// distinct status and no partially-open stream left behind:
//   1. android_get_device_api_level() >= 26 -> aaudio_unavailable
//   2. dlopen("libaaudio.so")              -> aaudio_unavailable
//   3. dlsym table                          -> aaudio_symbol_missing:<name>
//   4. builder create/config/open (output, sampleRate, channelCount,
//      PCM_I16, SHARED, performance NONE, data+error callback)
//                                           -> aaudio_builder_create_failed /
//                                              aaudio_open_failed:<code>
//   5. verify actual sampleRate/channelCount/format -> aaudio_config_mismatch
//   6. coordinator.start (parks awaiting the output-ring seek ack; the
//      caller must pump that ack next)      -> start_failed
//   7. requestStart + bounded waitForStateChange to STARTED
//                                           -> aaudio_start_failed:<code> /
//                                              aaudio_start_state:<state>
// ---------------------------------------------------------------------------
extern "C" JNIEXPORT jstring JNICALL
Java_com_connects_vanguard_1media_1engine_bridge_VanguardNativeBridge_00024Companion_startAaudioNodeOwnedSink(
    JNIEnv* env,
    jobject /* companion */,
    jlong sessionHandle,
    jlong mediaPtsUs,
    jlong sysTimeNs) {

    char status[640];

    const std::shared_ptr<AaudioNodeOwnedSinkSession> session =
        FindAaudioSinkSession(sessionHandle);
    if (!session) {
        std::snprintf(status, sizeof(status), "status=not_found");
        return env->NewStringUTF(status);
    }
    if (std::this_thread::get_id() != session->ownerThreadId) {
        std::snprintf(status, sizeof(status), "status=wrong_owner_thread");
        return env->NewStringUTF(status);
    }
    AaudioNodeOwnedSinkSession& s = *session;
    if (s.started) {
        std::snprintf(status, sizeof(status), "status=already_started");
        return env->NewStringUTF(status);
    }

    s.deviceApiLevel = android_get_device_api_level();
    if (s.deviceApiLevel < kMinAaudioApiLevel) {
        std::snprintf(status, sizeof(status),
            "status=aaudio_unavailable;deviceApiLevel=%d", s.deviceApiLevel);
        return env->NewStringUTF(status);
    }
    s.aaudioLib = dlopen("libaaudio.so", RTLD_NOW | RTLD_LOCAL);
    if (!s.aaudioLib) {
        std::snprintf(status, sizeof(status),
            "status=aaudio_unavailable;deviceApiLevel=%d", s.deviceApiLevel);
        return env->NewStringUTF(status);
    }
    s.aaudioRuntimeAvailable = true;

    char missingName[80] = "";
    if (!ResolveAaudioApi(s.aaudioLib, &s.aaudio, missingName, sizeof(missingName))) {
        (void)dlclose(s.aaudioLib);
        s.aaudioLib = nullptr;
        s.aaudio = AaudioApi{};
        std::snprintf(status, sizeof(status),
            "status=aaudio_symbol_missing:%s", missingName);
        return env->NewStringUTF(status);
    }
    s.aaudioSymbolsResolved = true;
    s.aaudioChannelCountSymbolFallback =
        dlsym(s.aaudioLib, "AAudioStreamBuilder_setChannelCount") == nullptr ||
        dlsym(s.aaudioLib, "AAudioStream_getChannelCount") == nullptr;

    VgAAudioStreamBuilder* builder = nullptr;
    int32_t result = s.aaudio.createStreamBuilder(&builder);
    if (result != kAaudioOk || !builder) {
        std::snprintf(status, sizeof(status),
            "status=aaudio_builder_create_failed;result=%d", result);
        return env->NewStringUTF(status);
    }
    s.aaudio.builderSetDirection(builder, kAaudioDirectionOutput);
    s.aaudio.builderSetSampleRate(builder, s.sampleRate);
    s.aaudio.builderSetChannelCount(builder, s.channelCount);
    s.aaudio.builderSetFormat(builder, kAaudioFormatPcmI16);
    s.aaudio.builderSetSharingMode(builder, kAaudioSharingModeShared);
    s.aaudio.builderSetPerformanceMode(builder, kAaudioPerformanceModeNone);
    s.aaudio.builderSetDataCallback(builder, &AaudioSinkDataCallback, &s);
    s.aaudio.builderSetErrorCallback(builder, &AaudioSinkErrorCallback, &s);

    VgAAudioStream* stream = nullptr;
    result = s.aaudio.builderOpenStream(builder, &stream);
    (void)s.aaudio.builderDelete(builder);
    if (result != kAaudioOk || !stream) {
        std::snprintf(status, sizeof(status),
            "status=aaudio_open_failed:%d", result);
        return env->NewStringUTF(status);
    }
    s.stream = stream;
    s.aaudioStreamOpen = true;

    // Verify the opened stream matches the requested config exactly; a
    // mismatch closes the stream and fails closed (no resample/downmix
    // policy in this slice).
    s.aaudioStreamSampleRate   = s.aaudio.streamGetSampleRate(stream);
    s.aaudioStreamChannelCount = s.aaudio.streamGetChannelCount(stream);
    s.aaudioStreamFormat       = s.aaudio.streamGetFormat(stream);
    if (s.aaudioStreamSampleRate != s.sampleRate ||
        s.aaudioStreamChannelCount != s.channelCount ||
        s.aaudioStreamFormat != kAaudioFormatPcmI16) {
        std::snprintf(status, sizeof(status),
            "status=aaudio_config_mismatch;streamSampleRate=%d;streamChannelCount=%d;"
            "streamFormat=%d",
            s.aaudioStreamSampleRate, s.aaudioStreamChannelCount, s.aaudioStreamFormat);
        s.closeAaudioStream();
        return env->NewStringUTF(status);
    }
    s.aaudioConfigVerified = true;

    const Status startStatus = s.coordinator.start(
        static_cast<int64_t>(mediaPtsUs), static_cast<int64_t>(sysTimeNs));
    if (!startStatus.ok()) {
        s.closeAaudioStream();
        std::snprintf(status, sizeof(status), "status=start_failed");
        return env->NewStringUTF(status);
    }

    result = s.aaudio.streamRequestStart(stream);
    if (result != kAaudioOk) {
        s.closeAaudioStream();
        std::snprintf(status, sizeof(status),
            "status=aaudio_start_failed:%d", result);
        return env->NewStringUTF(status);
    }
    int32_t state = s.aaudio.streamGetState(stream);
    if (state == kAaudioStreamStateStarting) {
        (void)s.aaudio.streamWaitForStateChange(
            stream, kAaudioStreamStateStarting, &state, kAaudioStateWaitTimeoutNs);
    }
    if (state != kAaudioStreamStateStarted) {
        s.closeAaudioStream();
        std::snprintf(status, sizeof(status),
            "status=aaudio_start_state:%d", state);
        return env->NewStringUTF(status);
    }
    s.aaudioStreamStarted = true;

    s.anchorMediaPtsUs = static_cast<int64_t>(mediaPtsUs);
    s.anchorSysTimeNs  = static_cast<int64_t>(sysTimeNs);
    s.started          = true;

    const auto snap = s.coordinator.snapshot();
    std::snprintf(status, sizeof(status),
        "status=ok;deviceApiLevel=%d;aaudioRuntimeAvailable=true;aaudioSymbolsResolved=true;"
        "aaudioChannelCountSymbolFallback=%s;aaudioStreamOpen=true;aaudioConfigVerified=true;"
        "aaudioStreamStarted=true;streamSampleRate=%d;streamChannelCount=%d;streamFormat=%d;"
        "nextDispatchFrame=%lld;awaitingSeekAck=%s",
        s.deviceApiLevel,
        s.aaudioChannelCountSymbolFallback ? "true" : "false",
        s.aaudioStreamSampleRate,
        s.aaudioStreamChannelCount,
        s.aaudioStreamFormat,
        static_cast<long long>(snap.nextDispatchFrame),
        snap.awaitingSeekAck ? "true" : "false");
    return env->NewStringUTF(status);
}

// ---------------------------------------------------------------------------
// JNI: stepAaudioNodeOwnedSink
// Owner-thread-only. One bounded dispatch attempt at the caller-derived
// sysTimeNs tick with the exact multi-source node-owned semantics: joint
// underrun gate (flushTail=false), joint EOS tail flush with the
// anchor-derived tick clamp (flushTail=true), awaiting_seek_ack passthrough
// with no mutation.
// ---------------------------------------------------------------------------
extern "C" JNIEXPORT jstring JNICALL
Java_com_connects_vanguard_1media_1engine_bridge_VanguardNativeBridge_00024Companion_stepAaudioNodeOwnedSink(
    JNIEnv* env,
    jobject /* companion */,
    jlong sessionHandle,
    jlong sysTimeNs,
    jboolean flushTail) {

    char status[896];

    const std::shared_ptr<AaudioNodeOwnedSinkSession> session =
        FindAaudioSinkSession(sessionHandle);
    if (!session) {
        std::snprintf(status, sizeof(status),
            "status=not_found;framesRendered=0;"
            "sourceAvailableReadFramesTrack0=-1;sourceAvailableReadFramesTrack1=-1");
        return env->NewStringUTF(status);
    }
    if (std::this_thread::get_id() != session->ownerThreadId) {
        std::snprintf(status, sizeof(status),
            "status=wrong_owner_thread;framesRendered=0;"
            "sourceAvailableReadFramesTrack0=-1;sourceAvailableReadFramesTrack1=-1");
        return env->NewStringUTF(status);
    }

    AaudioNodeOwnedSinkSession& s = *session;
    const int64_t sourceAvail0 = s.sourceRingAt(0).availableReadFrames();
    const int64_t sourceAvail1 = s.sourceRingAt(1).availableReadFrames();
    const int64_t jointAvail   = std::min<int64_t>(sourceAvail0, sourceAvail1);

    auto replyNoDispatch = [&](const char* token) -> jstring {
        const auto snap = s.coordinator.snapshot();
        std::snprintf(status, sizeof(status),
            "status=%s;framesDue=0;framesRendered=0;framesPushed=0;"
            "nextDispatchFrame=%lld;"
            "sourceAvailableReadFramesTrack0=%lld;sourceAvailableReadFramesTrack1=%lld;"
            "outputAvailableReadFrames=%lld;dispatchCount=%llu;silenceCount=%llu;terminal=%s",
            token,
            static_cast<long long>(snap.nextDispatchFrame),
            static_cast<long long>(s.sourceRingAt(0).availableReadFrames()),
            static_cast<long long>(s.sourceRingAt(1).availableReadFrames()),
            static_cast<long long>(s.outputRing.availableReadFrames()),
            static_cast<unsigned long long>(snap.dispatchCount),
            static_cast<unsigned long long>(snap.silenceCount),
            snap.terminal ? "true" : "false");
        return env->NewStringUTF(status);
    };

    // Output-ring seek ack still pending: report without dispatching so the
    // step performs no clock/cursor/ring mutation at all.
    if (s.outputRing.seekRequest() != s.outputRing.seekAck()) {
        return replyNoDispatch("awaiting_seek_ack");
    }

    int64_t dispatchSysTimeNs = static_cast<int64_t>(sysTimeNs);
    bool    tailWindow        = false;

    if (flushTail == JNI_TRUE) {
        if (!s.writerAt(0).isEos() || !s.writerAt(1).isEos()) {
            return replyNoDispatch("tail_flush_requires_eos");
        }
        // Shared accepted-frame axis only: the joint tail is legal only when
        // both rings hold exactly the same residual frame count.
        if (sourceAvail0 != sourceAvail1) {
            return replyNoDispatch("tail_flush_track_length_mismatch");
        }
        if (sourceAvail0 <= 0) {
            return replyNoDispatch("tail_flush_complete");
        }
        const int64_t framesTarget = std::min<int64_t>(jointAvail, s.maxFramesPerMix);
        const int64_t targetFrame  = s.coordinator.snapshot().nextDispatchFrame + framesTarget;
        if (targetFrame > (kInt64Max - (kMicrosPerSecond - 1)) / kMicrosPerSecond) {
            return replyNoDispatch("tail_flush_overflow");
        }
        // Smallest ptsUs whose floor-frame is exactly targetFrame (valid for
        // sampleRate <= 1e6, enforced at construction).
        const int64_t targetPtsUs =
            (targetFrame * kMicrosPerSecond + s.sampleRate - 1) / s.sampleRate;
        if (targetPtsUs < s.anchorMediaPtsUs) {
            return replyNoDispatch("tail_flush_anchor_regression");
        }
        const int64_t deltaUs = targetPtsUs - s.anchorMediaPtsUs;
        if (deltaUs > (kInt64Max - s.anchorSysTimeNs) / 1000) {
            return replyNoDispatch("tail_flush_overflow");
        }
        const int64_t clampSysTimeNs = s.anchorSysTimeNs + deltaUs * 1000;
        dispatchSysTimeNs = std::min<int64_t>(dispatchSysTimeNs, clampSysTimeNs);
        tailWindow = true;
    } else {
        // Joint underrun gate: never dispatch a window either source ring
        // cannot fully satisfy; no clock/cursor/ring mutation on deferral.
        if (jointAvail < s.maxFramesPerMix) {
            return replyNoDispatch("deferred_insufficient_joint_source");
        }
    }

    DispatchOutput out;
    const DispatchResult result = s.coordinator.dispatchUntil(dispatchSysTimeNs, &out);

    const char* token = DispatchResultName(result);
    if (tailWindow && result == DispatchResult::kOk && out.framesRendered < s.maxFramesPerMix) {
        token = "tail_flush_partial_window";
    }

    const auto snap = s.coordinator.snapshot();
    std::snprintf(status, sizeof(status),
        "status=%s;framesDue=%lld;framesRendered=%lld;framesPushed=%lld;"
        "nextDispatchFrame=%lld;"
        "sourceAvailableReadFramesTrack0=%lld;sourceAvailableReadFramesTrack1=%lld;"
        "outputAvailableReadFrames=%lld;dispatchCount=%llu;silenceCount=%llu;terminal=%s",
        token,
        static_cast<long long>(out.framesDue),
        static_cast<long long>(out.framesRendered),
        static_cast<long long>(out.framesPushed),
        static_cast<long long>(snap.nextDispatchFrame),
        static_cast<long long>(s.sourceRingAt(0).availableReadFrames()),
        static_cast<long long>(s.sourceRingAt(1).availableReadFrames()),
        static_cast<long long>(s.outputRing.availableReadFrames()),
        static_cast<unsigned long long>(snap.dispatchCount),
        static_cast<unsigned long long>(snap.silenceCount),
        snap.terminal ? "true" : "false");
    return env->NewStringUTF(status);
}

// ---------------------------------------------------------------------------
// JNI: pumpAaudioNodeOwnedSink
// Owner-thread-only MUTED-SINK pump, the only output-ring reader in this
// slice. Consumes a pending output-ring seek ack first, then repeatedly:
//   pop REAL mixed PCM (clamped to sink-ring write space so no popped frame
//   is ever lost) -> accumulate nativeOutputDrainChecksum -> memset the
//   scratch to zero (the zero-scale) -> verify + checksum the muted frames
//   -> tryPushFrames into the sink ring feeding the AAudio callback.
// maxFrames == 0 is a legal ack-only call. No per-call heap allocation: a
// fixed stack scratch, strictly bounded iterations.
// ---------------------------------------------------------------------------
extern "C" JNIEXPORT jstring JNICALL
Java_com_connects_vanguard_1media_1engine_bridge_VanguardNativeBridge_00024Companion_pumpAaudioNodeOwnedSink(
    JNIEnv* env,
    jobject /* companion */,
    jlong sessionHandle,
    jint maxFrames) {

    char status[896];

    const std::shared_ptr<AaudioNodeOwnedSinkSession> session =
        FindAaudioSinkSession(sessionHandle);
    if (!session) {
        std::snprintf(status, sizeof(status),
            "status=not_found;framesRequested=%d;framesPumped=0", static_cast<int>(maxFrames));
        return env->NewStringUTF(status);
    }
    if (std::this_thread::get_id() != session->ownerThreadId) {
        std::snprintf(status, sizeof(status),
            "status=wrong_owner_thread;framesRequested=%d;framesPumped=0",
            static_cast<int>(maxFrames));
        return env->NewStringUTF(status);
    }
    if (maxFrames < 0) {
        std::snprintf(status, sizeof(status),
            "status=invalid_max_frames;framesRequested=%d;framesPumped=0",
            static_cast<int>(maxFrames));
        return env->NewStringUTF(status);
    }

    AaudioNodeOwnedSinkSession& s = *session;

    bool    seekAckConsumed       = false;
    int64_t discardedFramesOnSeek = 0;
    int64_t newStartFrame         = -1;
    {
        const int64_t unreadBeforeAck = s.outputRing.availableReadFrames();
        int64_t ackFrame = -1;
        if (s.outputRing.consumePendingSeekOnReaderThread(&ackFrame)) {
            seekAckConsumed       = true;
            discardedFramesOnSeek = unreadBeforeAck;
            newStartFrame         = ackFrame;
        }
    }

    // Stack-only scratch: kPumpChunkFrames frames at up to 2 channels.
    int16_t scratch[kPumpChunkFrames * 2];

    const int64_t framesToPump = std::min<int64_t>(
        static_cast<int64_t>(maxFrames), kMaxRingCapacityFrames);
    const int32_t channels = s.channelCount;

    int64_t framesPumped = 0;
    int64_t remaining    = framesToPump;
    bool    pushShortfallThisCall = false;
    for (int iter = 0; iter < kMaxPumpIterations && remaining > 0; ++iter) {
        // Clamp the pop to the sink ring's free space so a popped (and
        // checksummed) real frame is never dropped on the muted push.
        const int64_t want = std::min<int64_t>(
            {remaining, kPumpChunkFrames, s.sinkRing.availableWriteFrames()});
        if (want <= 0) break;
        const int64_t got = s.outputRing.tryPopFrames(scratch, want);
        if (got <= 0) break;
        s.nativeOutputDrainChecksum = AccumulateChecksum(
            s.nativeOutputDrainChecksum, scratch, got * channels);
        // The zero-scale: mute the whole popped chunk before it can enter
        // the callback sink ring. The verification scan latches
        // mutedOutputOk=false if any sample were somehow non-zero.
        std::memset(scratch, 0, static_cast<size_t>(got) * channels * sizeof(int16_t));
        for (int64_t i = 0; i < got * channels; ++i) {
            if (scratch[i] != 0) { s.mutedOutputOk = false; break; }
        }
        s.mutedSinkChecksum = AccumulateChecksum(s.mutedSinkChecksum, scratch, got * channels);
        const int64_t pushed = s.sinkRing.tryPushFrames(scratch, got);
        s.totalMutedFramesPushed += pushed;
        if (pushed < got) {
            // Never expected (the pop was clamped to sink write space);
            // latched and failed closed because real frames were lost.
            s.sinkPushShortfallSeen = true;
            pushShortfallThisCall = true;
            framesPumped += got;
            break;
        }
        framesPumped += got;
        remaining    -= got;
        if (got < want) break; // output ring empty mid-chunk
    }
    s.totalOutputFramesPumped += framesPumped;

    std::snprintf(status, sizeof(status),
        "status=%s;framesRequested=%d;framesPumped=%lld;outputAvailableReadFrames=%lld;"
        "sinkAvailableReadFrames=%lld;sinkAvailableWriteFrames=%lld;"
        "nativeOutputDrainChecksumHex=%016llx;totalOutputFramesPumped=%lld;"
        "mutedSinkChecksumHex=%016llx;totalMutedFramesPushed=%lld;mutedOutputOk=%s;"
        "callbackInvocationCount=%llu;callbackFramesRequested=%llu;"
        "callbackFramesServed=%llu;callbackSilenceFrames=%llu;callbackShortReads=%llu;"
        "errorCallbackCount=%llu;"
        "seekAckConsumed=%s;discardedFramesOnSeek=%lld;newStartFrame=%lld",
        pushShortfallThisCall ? "sink_push_shortfall" : "ok",
        static_cast<int>(maxFrames),
        static_cast<long long>(framesPumped),
        static_cast<long long>(s.outputRing.availableReadFrames()),
        static_cast<long long>(s.sinkRing.availableReadFrames()),
        static_cast<long long>(s.sinkRing.availableWriteFrames()),
        static_cast<unsigned long long>(s.nativeOutputDrainChecksum),
        static_cast<long long>(s.totalOutputFramesPumped),
        static_cast<unsigned long long>(s.mutedSinkChecksum),
        static_cast<long long>(s.totalMutedFramesPushed),
        s.mutedOutputOk ? "true" : "false",
        static_cast<unsigned long long>(s.callbackInvocationCount.load(std::memory_order_relaxed)),
        static_cast<unsigned long long>(s.callbackFramesRequested.load(std::memory_order_relaxed)),
        static_cast<unsigned long long>(s.callbackFramesServed.load(std::memory_order_relaxed)),
        static_cast<unsigned long long>(s.callbackSilenceFrames.load(std::memory_order_relaxed)),
        static_cast<unsigned long long>(s.callbackShortReads.load(std::memory_order_relaxed)),
        static_cast<unsigned long long>(s.errorCallbackCount.load(std::memory_order_relaxed)),
        seekAckConsumed ? "true" : "false",
        static_cast<long long>(discardedFramesOnSeek),
        static_cast<long long>(newStartFrame));
    return env->NewStringUTF(status);
}

// ---------------------------------------------------------------------------
// JNI: seekAaudioNodeOwnedSink
// Owner-thread-only. Forward-only joint seek with the exact multi-source
// node-owned semantics on the shared accepted-frame axis (the pumped total
// stands in for the drained total). The sink ring is NOT gated: it holds
// only already-muted zeros, which the callback keeps consuming untouched.
// ---------------------------------------------------------------------------
extern "C" JNIEXPORT jstring JNICALL
Java_com_connects_vanguard_1media_1engine_bridge_VanguardNativeBridge_00024Companion_seekAaudioNodeOwnedSink(
    JNIEnv* env,
    jobject /* companion */,
    jlong sessionHandle,
    jlong targetPtsUs,
    jlong sysTimeNs) {

    char status[768];

    const std::shared_ptr<AaudioNodeOwnedSinkSession> session =
        FindAaudioSinkSession(sessionHandle);
    if (!session) {
        std::snprintf(status, sizeof(status),
            "status=not_found;targetPtsUs=%lld;targetFrame=-1",
            static_cast<long long>(targetPtsUs));
        return env->NewStringUTF(status);
    }
    if (std::this_thread::get_id() != session->ownerThreadId) {
        std::snprintf(status, sizeof(status),
            "status=wrong_owner_thread;targetPtsUs=%lld;targetFrame=-1",
            static_cast<long long>(targetPtsUs));
        return env->NewStringUTF(status);
    }

    AaudioNodeOwnedSinkSession& s = *session;
    const int64_t targetFrame = ClockedAudioTransportCoordinator::frameOfPositionUs(
        static_cast<int64_t>(targetPtsUs), s.sampleRate);

    auto replySeek = [&](const char* token, int64_t discarded) -> jstring {
        std::snprintf(status, sizeof(status),
            "status=%s;targetPtsUs=%lld;targetFrame=%lld;discardedFramesOnSeek=%lld;"
            "providerExpectedNextFrameTrack0=%lld;providerExpectedNextFrameTrack1=%lld;"
            "writerNextWriteFrameTrack0=%lld;writerNextWriteFrameTrack1=%lld;"
            "sourceAvailableReadFramesTrack0=%lld;sourceAvailableReadFramesTrack1=%lld;"
            "outputAvailableReadFrames=%lld",
            token,
            static_cast<long long>(targetPtsUs),
            static_cast<long long>(targetFrame),
            static_cast<long long>(discarded),
            static_cast<long long>(s.providerAt(0).expectedNextFrame()),
            static_cast<long long>(s.providerAt(1).expectedNextFrame()),
            static_cast<long long>(s.writerAt(0).nextWriteFrame()),
            static_cast<long long>(s.writerAt(1).nextWriteFrame()),
            static_cast<long long>(s.sourceRingAt(0).availableReadFrames()),
            static_cast<long long>(s.sourceRingAt(1).availableReadFrames()),
            static_cast<long long>(s.outputRing.availableReadFrames()));
        return env->NewStringUTF(status);
    };

    if (s.outputRing.availableReadFrames() != 0) {
        return replySeek("output_ring_not_drained", 0);
    }
    if (s.sourceRingAt(0).availableReadFrames() != 0) {
        return replySeek("source_ring_not_empty_track0", 0);
    }
    if (s.sourceRingAt(1).availableReadFrames() != 0) {
        return replySeek("source_ring_not_empty_track1", 0);
    }
    // Shared frame axis check: both accepted totals, the pumped output
    // total, and the dispatch cursor must sit on the same accepted frame.
    const int64_t nextDispatchFrame = s.coordinator.snapshot().nextDispatchFrame;
    if (s.totalFramesAccepted[0] != s.totalFramesAccepted[1] ||
        s.totalFramesAccepted[0] != s.totalOutputFramesPumped ||
        s.totalFramesAccepted[0] != nextDispatchFrame) {
        return replySeek("track_frame_axis_divergence", 0);
    }
    if (targetFrame < s.providerAt(0).expectedNextFrame() ||
        targetFrame < s.providerAt(1).expectedNextFrame()) {
        return replySeek("seek_target_behind_provider_cursor", 0);
    }

    // Both tracks reanchor at the same accepted frame A = targetFrame; each
    // node-owned ring's ack is consumed immediately on this owner thread
    // and, because both rings were verified empty above, nothing may be
    // discarded.
    for (int track = 0; track < 2; ++track) {
        const WriterStatus writerSeekStatus = s.writerAt(track).requestSeek(targetFrame);
        if (writerSeekStatus != WriterStatus::kOk) {
            return replySeek(track == 0 ? "writer0_seek_rejected" : "writer1_seek_rejected", 0);
        }
        const int64_t unreadBeforeAck = s.sourceRingAt(track).availableReadFrames();
        int64_t sourceAckFrame = -1;
        if (!s.sourceRingAt(track).consumePendingSeekOnReaderThread(&sourceAckFrame)) {
            return replySeek(
                track == 0 ? "source0_seek_ack_not_consumed" : "source1_seek_ack_not_consumed", 0);
        }
        if (unreadBeforeAck != 0 || sourceAckFrame != targetFrame) {
            return replySeek(
                track == 0 ? "source0_seek_boundary_mismatch" : "source1_seek_boundary_mismatch",
                unreadBeforeAck);
        }
    }

    const Status coordinatorSeekStatus = s.coordinator.seek(
        static_cast<int64_t>(targetPtsUs), static_cast<int64_t>(sysTimeNs));
    if (!coordinatorSeekStatus.ok()) {
        return replySeek("coordinator_seek_failed", 0);
    }

    s.anchorMediaPtsUs = static_cast<int64_t>(targetPtsUs);
    s.anchorSysTimeNs  = static_cast<int64_t>(sysTimeNs);

    return replySeek("ok", 0);
}

// ---------------------------------------------------------------------------
// JNI: setAaudioNodeOwnedSinkEos
// Owner-thread-only JOINT writer-local EOS: one call sets BOTH node-owned
// writers EOS together (cleared by the next successful seek request inside
// each AudioDecoderRingWriter). No per-track EOS entry point in this slice.
// ---------------------------------------------------------------------------
extern "C" JNIEXPORT jstring JNICALL
Java_com_connects_vanguard_1media_1engine_bridge_VanguardNativeBridge_00024Companion_setAaudioNodeOwnedSinkEos(
    JNIEnv* env,
    jobject /* companion */,
    jlong sessionHandle) {

    char status[160];

    const std::shared_ptr<AaudioNodeOwnedSinkSession> session =
        FindAaudioSinkSession(sessionHandle);
    if (!session) {
        std::snprintf(status, sizeof(status),
            "status=not_found;eosTrack0=false;eosTrack1=false");
        return env->NewStringUTF(status);
    }
    if (std::this_thread::get_id() != session->ownerThreadId) {
        std::snprintf(status, sizeof(status),
            "status=wrong_owner_thread;eosTrack0=false;eosTrack1=false");
        return env->NewStringUTF(status);
    }

    session->writerAt(0).setEos();
    session->writerAt(1).setEos();
    std::snprintf(status, sizeof(status),
        "status=ok;eosTrack0=%s;eosTrack1=%s",
        session->writerAt(0).isEos() ? "true" : "false",
        session->writerAt(1).isEos() ? "true" : "false");
    return env->NewStringUTF(status);
}

// ---------------------------------------------------------------------------
// JNI: snapshotAaudioNodeOwnedSink
// Owner-thread-only. Full diagnostic snapshot: the two-track node-owned
// evidence and fixed-at-construction capacities (now including the sink
// ring) for the zero-steady-state-allocation lane, the AAudio bring-up
// facts, the callback atomics (a mid-run read may trail an in-flight
// callback burst; destroy reports the coherent finals), the muted-sink
// evidence, and the verbatim proof boundary.
// ---------------------------------------------------------------------------
extern "C" JNIEXPORT jstring JNICALL
Java_com_connects_vanguard_1media_1engine_bridge_VanguardNativeBridge_00024Companion_snapshotAaudioNodeOwnedSink(
    JNIEnv* env,
    jobject /* companion */,
    jlong sessionHandle) {

    char status[7168];

    const std::shared_ptr<AaudioNodeOwnedSinkSession> session =
        FindAaudioSinkSession(sessionHandle);
    if (!session) {
        std::snprintf(status, sizeof(status), "status=not_found");
        return env->NewStringUTF(status);
    }
    if (std::this_thread::get_id() != session->ownerThreadId) {
        std::snprintf(status, sizeof(status), "status=wrong_owner_thread");
        return env->NewStringUTF(status);
    }

    AaudioNodeOwnedSinkSession& s = *session;
    const auto snap = s.coordinator.snapshot();

    StatusAppender out(status, sizeof(status));
    out.appendf(
        "status=ok;"
        "routedSourceCount=%zu;routedSourceId0=%s;routedSourceId1=%s;"
        "nodeOwnsRingTrack0=%s;nodeOwnsRingTrack1=%s;"
        "lastDispatchResult=%s;nextDispatchFrame=%lld;lastMediaPositionUs=%lld;"
        "totalFramesRendered=%lld;totalFramesPushed=%lld;dispatchCount=%llu;"
        "okCount=%llu;silenceCount=%llu;backpressureCount=%llu;schedulerErrorCount=%llu;"
        "awaitingSeekAck=%s;terminal=%s;",
        s.scheduler.routedSourceCount(),
        s.scheduler.routedSourceCount() > 0 ? s.scheduler.routedSourceIdAt(0).c_str() : "",
        s.scheduler.routedSourceCount() > 1 ? s.scheduler.routedSourceIdAt(1).c_str() : "",
        s.sourceNode0->ownsRing() ? "true" : "false",
        s.sourceNode1->ownsRing() ? "true" : "false",
        DispatchResultName(snap.lastResult),
        static_cast<long long>(snap.nextDispatchFrame),
        static_cast<long long>(snap.lastMediaPositionUs),
        static_cast<long long>(snap.totalFramesRendered),
        static_cast<long long>(snap.totalFramesPushed),
        static_cast<unsigned long long>(snap.dispatchCount),
        static_cast<unsigned long long>(snap.okCount),
        static_cast<unsigned long long>(snap.silenceCount),
        static_cast<unsigned long long>(snap.backpressureCount),
        static_cast<unsigned long long>(snap.schedulerErrorCount),
        snap.awaitingSeekAck ? "true" : "false",
        snap.terminal ? "true" : "false");

    for (int track = 0; track < 2; ++track) {
        const AudioDecoderRingWriter::Metrics& wm = s.writerAt(track).metrics();
        out.appendf(
            "providerExpectedNextFrameTrack%d=%lld;providerUnderrunEventsTrack%d=%llu;"
            "providerFramesZeroFilledTrack%d=%llu;providerForwardSkipFramesTrack%d=%llu;"
            "providerRewindRejectsTrack%d=%llu;"
            "writerEosTrack%d=%s;writerNextWriteFrameTrack%d=%lld;"
            "writerPartialWriteEventsTrack%d=%llu;writerBackpressureRejectsTrack%d=%llu;"
            "writerSeekRequestsTrack%d=%llu;"
            "sourceAvailableReadFramesTrack%d=%lld;sourceAvailableWriteFramesTrack%d=%lld;"
            "sourceRingStorageCapacitySamplesTrack%d=%lld;"
            "nativeAcceptedChecksumHexTrack%d=%016llx;totalFramesAcceptedTrack%d=%lld;",
            track, static_cast<long long>(s.providerAt(track).expectedNextFrame()),
            track, static_cast<unsigned long long>(s.providerAt(track).underrunEvents()),
            track, static_cast<unsigned long long>(s.providerAt(track).framesZeroFilled()),
            track, static_cast<unsigned long long>(s.providerAt(track).forwardSkipFrames()),
            track, static_cast<unsigned long long>(s.providerAt(track).rewindRejects()),
            track, s.writerAt(track).isEos() ? "true" : "false",
            track, static_cast<long long>(s.writerAt(track).nextWriteFrame()),
            track, static_cast<unsigned long long>(wm.partialWriteEvents),
            track, static_cast<unsigned long long>(wm.backpressureRejects),
            track, static_cast<unsigned long long>(wm.seekRequests),
            track, static_cast<long long>(s.sourceRingAt(track).availableReadFrames()),
            track, static_cast<long long>(s.sourceRingAt(track).availableWriteFrames()),
            track, static_cast<long long>(s.sourceRingAt(track).storageCapacitySamples()),
            track, static_cast<unsigned long long>(s.nativeAcceptedChecksum[track]),
            track, static_cast<long long>(s.totalFramesAccepted[track]));
    }

    out.appendf(
        "outputAvailableReadFrames=%lld;outputRingStorageCapacitySamples=%lld;"
        "sinkAvailableReadFrames=%lld;sinkAvailableWriteFrames=%lld;"
        "sinkRingStorageCapacitySamples=%lld;"
        "schedulerTrackScratchCapacitySamples=%zu;schedulerTrackScratchCapacityTracks=%zu;"
        "schedulerRoutedSourceCount=%zu;"
        "nativeOutputDrainChecksumHex=%016llx;totalOutputFramesPumped=%lld;"
        "mutedSinkChecksumHex=%016llx;totalMutedFramesPushed=%lld;mutedOutputOk=%s;"
        "sinkPushShortfallSeen=%s;"
        "deviceApiLevel=%d;aaudioRuntimeAvailable=%s;aaudioSymbolsResolved=%s;"
        "aaudioChannelCountSymbolFallback=%s;aaudioStreamOpen=%s;aaudioConfigVerified=%s;"
        "aaudioStreamStarted=%s;streamSampleRate=%d;streamChannelCount=%d;streamFormat=%d;"
        "callbackInvocationCount=%llu;callbackFramesRequested=%llu;callbackFramesServed=%llu;"
        "callbackSilenceFrames=%llu;callbackShortReads=%llu;errorCallbackCount=%llu;"
        "lastErrorCallbackResult=%d;"
        "sampleRate=%d;channelCount=%d;maxFramesPerMix=%lld;"
        "proofBoundary=%s",
        static_cast<long long>(s.outputRing.availableReadFrames()),
        static_cast<long long>(s.outputRing.storageCapacitySamples()),
        static_cast<long long>(s.sinkRing.availableReadFrames()),
        static_cast<long long>(s.sinkRing.availableWriteFrames()),
        static_cast<long long>(s.sinkRing.storageCapacitySamples()),
        s.scheduler.trackScratchCapacitySamples(),
        s.scheduler.trackScratchCapacityTracks(),
        s.scheduler.routedSourceCount(),
        static_cast<unsigned long long>(s.nativeOutputDrainChecksum),
        static_cast<long long>(s.totalOutputFramesPumped),
        static_cast<unsigned long long>(s.mutedSinkChecksum),
        static_cast<long long>(s.totalMutedFramesPushed),
        s.mutedOutputOk ? "true" : "false",
        s.sinkPushShortfallSeen ? "true" : "false",
        s.deviceApiLevel,
        s.aaudioRuntimeAvailable ? "true" : "false",
        s.aaudioSymbolsResolved ? "true" : "false",
        s.aaudioChannelCountSymbolFallback ? "true" : "false",
        s.aaudioStreamOpen ? "true" : "false",
        s.aaudioConfigVerified ? "true" : "false",
        s.aaudioStreamStarted ? "true" : "false",
        s.aaudioStreamSampleRate,
        s.aaudioStreamChannelCount,
        s.aaudioStreamFormat,
        static_cast<unsigned long long>(s.callbackInvocationCount.load(std::memory_order_relaxed)),
        static_cast<unsigned long long>(s.callbackFramesRequested.load(std::memory_order_relaxed)),
        static_cast<unsigned long long>(s.callbackFramesServed.load(std::memory_order_relaxed)),
        static_cast<unsigned long long>(s.callbackSilenceFrames.load(std::memory_order_relaxed)),
        static_cast<unsigned long long>(s.callbackShortReads.load(std::memory_order_relaxed)),
        static_cast<unsigned long long>(s.errorCallbackCount.load(std::memory_order_relaxed)),
        s.lastErrorCallbackResult.load(std::memory_order_relaxed),
        static_cast<int>(s.sampleRate),
        static_cast<int>(s.channelCount),
        static_cast<long long>(s.maxFramesPerMix),
        kProofBoundary);

    if (out.overflowed()) {
        std::snprintf(status, sizeof(status), "status=snapshot_overflow");
    }
    return env->NewStringUTF(status);
}

// ---------------------------------------------------------------------------
// JNI: destroyAaudioNodeOwnedSinkSmokeSession
// OWNER-THREAD-ONLY in this slice (unlike the sibling pipeline TUs) because
// it performs the AAudio requestStop / bounded waitForStateChange / close
// sequence; a wrong-thread call fails closed with no mutation. After close
// the callback thread is quiescent, so the reply carries the COHERENT final
// callback counters for the accounting lane. Erase-once: a second call (or
// handle 0/unknown) returns status=not_found.
// ---------------------------------------------------------------------------
extern "C" JNIEXPORT jstring JNICALL
Java_com_connects_vanguard_1media_1engine_bridge_VanguardNativeBridge_00024Companion_destroyAaudioNodeOwnedSinkSmokeSession(
    JNIEnv* env,
    jobject /* companion */,
    jlong sessionHandle) {

    char status[512];

    const std::shared_ptr<AaudioNodeOwnedSinkSession> session =
        FindAaudioSinkSession(sessionHandle);
    if (!session) {
        std::snprintf(status, sizeof(status), "status=not_found");
        return env->NewStringUTF(status);
    }
    if (std::this_thread::get_id() != session->ownerThreadId) {
        std::snprintf(status, sizeof(status), "status=wrong_owner_thread");
        return env->NewStringUTF(status);
    }

    // Stop and close the stream first (owner thread, never from a
    // callback), then read the now-coherent callback finals, then erase.
    session->closeAaudioStream();

    const unsigned long long invocations =
        session->callbackInvocationCount.load(std::memory_order_relaxed);
    const unsigned long long requested =
        session->callbackFramesRequested.load(std::memory_order_relaxed);
    const unsigned long long served =
        session->callbackFramesServed.load(std::memory_order_relaxed);
    const unsigned long long silence =
        session->callbackSilenceFrames.load(std::memory_order_relaxed);
    const unsigned long long shortReads =
        session->callbackShortReads.load(std::memory_order_relaxed);
    const unsigned long long errorCallbacks =
        session->errorCallbackCount.load(std::memory_order_relaxed);

    std::snprintf(status, sizeof(status),
        "status=ok;callbackInvocationCount=%llu;callbackFramesRequested=%llu;"
        "callbackFramesServed=%llu;callbackSilenceFrames=%llu;callbackShortReads=%llu;"
        "errorCallbackCount=%llu;mutedSinkChecksumHex=%016llx;totalMutedFramesPushed=%lld;"
        "mutedOutputOk=%s;sinkPushShortfallSeen=%s",
        invocations, requested, served, silence, shortReads, errorCallbacks,
        static_cast<unsigned long long>(session->mutedSinkChecksum),
        static_cast<long long>(session->totalMutedFramesPushed),
        session->mutedOutputOk ? "true" : "false",
        session->sinkPushShortfallSeen ? "true" : "false");

    {
        std::lock_guard<std::mutex> lock(gAaudioSinkRegistryMutex);
        gAaudioSinkSessions.erase(static_cast<int64_t>(sessionHandle));
    }
    return env->NewStringUTF(status);
}
