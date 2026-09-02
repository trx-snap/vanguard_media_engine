// P4-AUDIO-REALTIME-PLAYBACK-TRANSPORT-CORE (Y1) / EXTERNAL-INGEST-SEAM (Y5a):
// header-only, allocation-free helpers for
// android_phase4_realtime_playback_graph_session_jni.cpp.
//
// Extracted verbatim from the session TU (Y5a) purely to keep that TU
// under its size cap. Everything here is a pure function, a plain enum, or
// a plain data record: no JNI, no threads, no ring/graph ownership, no
// lifecycle. The session TU is the only intended includer; this header is
// not a public API and is not registered anywhere (no CMake entry needed,
// it is found through the TU's own directory).
#pragma once

#include <array>
#include <chrono>
#include <cstdarg>
#include <cstdint>
#include <cstdio>
#include <memory>
#include <string>
#include <vector>

#include "vanguard/audio/audio_mix_bus_node.h"
#include "vanguard/audio/decoded_audio_pcm_source_node.h"
#include "vanguard/graph/graph.h"

namespace vanguard {
namespace platform {
namespace android {
namespace realtime_playback_detail {

constexpr int64_t kMicrosPerSecond = 1'000'000LL;

constexpr const char* kMixNodeId        = "rt_playback_mix";
constexpr const char* kSourceNodePrefix = "rt_playback_src";

// AudioMixBusNode input port ids in track order (see audio_mix_bus_node.cpp).
inline const std::array<std::string, 8>& MixInputPorts() {
    static const std::array<std::string, 8> ports = {
        "primary_audio_in", "secondary_audio_in", "audio_in_2", "audio_in_3",
        "audio_in_4", "audio_in_5", "audio_in_6", "audio_in_7"};
    return ports;
}

inline std::string SourceNodeId(int track) {
    return std::string(kSourceNodePrefix) + std::to_string(track);
}

enum class NativeState : int32_t {
    kIdle = 0,
    kPrepared,
    kPlaying,
    kPaused,
    kStopped,
    kFailed,
};

inline const char* NativeStateToken(NativeState s) {
    switch (s) {
        case NativeState::kIdle:     return "idle";
        case NativeState::kPrepared: return "prepared";
        case NativeState::kPlaying:  return "playing";
        case NativeState::kPaused:   return "paused";
        case NativeState::kStopped:  return "stopped";
        case NativeState::kFailed:   return "failed";
    }
    return "unknown";
}

enum class CommandType : int32_t {
    kPrepare = 1,
    kStart   = 2,
    kPause   = 3,
    kResume  = 4,
    kSeek    = 5, // arg = targetFrame
    kStop    = 6,
};

// Shared owner-precheck / worker-revalidation predicate. Kotlin mirrors
// the same table authoritatively; a mismatch surfaces as invalid_state.
inline bool CommandAllowed(CommandType type, NativeState state) {
    switch (type) {
        case CommandType::kPrepare:
            return state == NativeState::kIdle || state == NativeState::kPrepared ||
                   state == NativeState::kStopped;
        case CommandType::kStart:
            return state == NativeState::kPrepared || state == NativeState::kStopped;
        case CommandType::kPause:
            return state == NativeState::kPlaying;
        case CommandType::kResume:
            return state == NativeState::kPaused;
        case CommandType::kSeek:
            return state == NativeState::kPrepared || state == NativeState::kPlaying ||
                   state == NativeState::kPaused || state == NativeState::kStopped;
        case CommandType::kStop:
            return state != NativeState::kIdle;
    }
    return false;
}

// checksum = checksum * 31 + uint16(sample), the shape shared by the sibling
// audio seams so a harness can reproduce it in Kotlin.
inline uint64_t AccumulateChecksum(uint64_t checksum, const int16_t* samples, int64_t count) {
    for (int64_t i = 0; i < count; ++i) {
        checksum = checksum * 31u + static_cast<uint64_t>(static_cast<uint16_t>(samples[i]));
    }
    return checksum;
}

// Deterministic synthetic reference identity. Pure integer math so the
// Kotlin wrapper reproduces it bit-exactly:
//   sample(track, frame, channel) =
//       (((frame * (2*track + 3) + channel * 97) mod 2001) - 1000) * 4
// Per-track amplitude <= 4000, so eight unit-gain tracks sum to <= 32000
// and the mix bus never clips.
inline int16_t SyntheticSample(int track, int64_t frame, int channel) {
    const int64_t phase = frame * static_cast<int64_t>(2 * track + 3) +
                          static_cast<int64_t>(channel) * 97;
    return static_cast<int16_t>(((phase % 2001) - 1000) * 4);
}

inline void GenerateSyntheticPcm(int track, int64_t startFrame, int64_t frames,
                                 int32_t channelCount, int16_t* out) {
    int64_t i = 0;
    for (int64_t f = 0; f < frames; ++f) {
        for (int32_t c = 0; c < channelCount; ++c) {
            out[i++] = SyntheticSample(track, startFrame + f, c);
        }
    }
}

// Smallest ptsUs whose frameOfPositionUs floor lands exactly on `frame`
// (valid because sampleRate <= 192000 < 1e6).
inline int64_t CeilPtsUsOfFrame(int64_t frame, int32_t sampleRate) {
    if (frame <= 0) return 0;
    return (frame * kMicrosPerSecond + sampleRate - 1) / sampleRate;
}

inline int64_t PowerOfTwoCeil(int64_t v) {
    int64_t p = 1;
    while (p < v) p <<= 1;
    return p;
}

inline int64_t SteadyNowNs() {
    return std::chrono::duration_cast<std::chrono::nanoseconds>(
               std::chrono::steady_clock::now().time_since_epoch())
        .count();
}

// Bounded stack-buffer appender; overflow latches and the reply fails
// closed with status=reply_overflow instead of silently truncating.
class ReplyBuilder {
public:
    ReplyBuilder(char* buf, size_t cap) : buf_(buf), cap_(cap) {
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

struct Command {
    CommandType type{CommandType::kPrepare};
    int64_t     arg{0};
    uint64_t    seq{0};
};

// Worker-published mirror (guarded by Session::mutex_). All tokens are
// string literals so publishing never allocates.
struct PublishedState {
    NativeState state{NativeState::kIdle};
    bool        workerStarted{false};
    bool        workerExited{false};
    bool        eosPushed{false};
    int64_t     renderedFrames{0};
    int64_t     pushedFrames{0};
    int64_t     positionFrame{0};
    uint64_t    dispatchCount{0};
    uint64_t    backpressureCount{0};
    uint64_t    commandsProcessed{0};
    uint64_t    commandErrors{0};
    uint64_t    ackedSeq{0};
    // Y5a: dispatch-loop iterations paused because an external-ingest
    // track had fewer readable frames than the due window. Nonterminal.
    uint64_t    underrunCount{0};
    const char* lastCommandResult{"none"};
    const char* lastError{"none"};
    uint64_t    pushedChecksum{0};
};

inline std::vector<std::shared_ptr<vanguard::audio::DecodedAudioPcmSourceNode>> MakeSources(
    int32_t trackCount, int32_t sampleRate, int32_t channelCount,
    int64_t declaredFrames, int64_t sourceRingCapacityFrames) {
    std::vector<std::shared_ptr<vanguard::audio::DecodedAudioPcmSourceNode>> sources;
    sources.reserve(static_cast<size_t>(trackCount));
    for (int32_t t = 0; t < trackCount; ++t) {
        sources.push_back(std::make_shared<vanguard::audio::DecodedAudioPcmSourceNode>(
            SourceNodeId(t), sampleRate, channelCount, declaredFrames,
            /*timelineStartPtsUs=*/0, sourceRingCapacityFrames));
    }
    return sources;
}

// Populates the mix topology before the scheduler member snapshots it;
// called from the member initializer list only. Edge-insertion order is
// the auto-discovery routed order (track 0 first).
inline const vanguard::graph::Graph& PrepareTopology(
    vanguard::graph::Graph& g,
    const std::shared_ptr<vanguard::audio::AudioMixBusNode>& mixBus,
    const std::vector<std::shared_ptr<vanguard::audio::DecodedAudioPcmSourceNode>>& sources) {
    (void)g.addNode(mixBus);
    for (size_t t = 0; t < sources.size(); ++t) {
        (void)g.addNode(sources[t]);
        (void)g.connect(sources[t]->id(), "audio_out", kMixNodeId, MixInputPorts()[t]);
    }
    return g;
}

} // namespace realtime_playback_detail
} // namespace android
} // namespace platform
} // namespace vanguard
