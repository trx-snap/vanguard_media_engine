#pragma once
#include "vanguard/audio/audio_mix_bus_node.h"
#include "vanguard/audio/audio_sample_provider.h"
#include "vanguard/core/status.h"
#include "vanguard/graph/graph.h"
#include <cstdint>
#include <memory>
#include <string>
#include <unordered_map>
#include <vector>

namespace vanguard {
namespace audio {

// P4-AUDIO-GRAPH-TRANSPORT-CLOCK sub-slice A: synchronous, pull-model,
// graph-edge-routed audio window scheduler proof.
//
// This is NOT a queue and does NOT own a realtime clock. GraphAudioScheduler
// owns no Graph, no Node, and no AudioSampleProvider: it holds a non-owning
// `const Graph&`, a non-owning provider registry keyed by source node id,
// and a snapshot of the graph's generation id taken at construction. It
// does not mutate Node, does not add upstream pointers to Node, and does
// not retain PCM inside DecodedAudioPcmSourceNode.
//
// Provider/edge routing is resolved once, at construction, via
// Graph::inputConnections(targetMixNodeId) (deterministic edge-insertion
// order): only edges whose source node has a registered provider and whose
// target port is a kAudioPacket input on the target AudioMixBusNode are
// routed. If the graph is mutated after construction, the snapshotted
// generation id goes stale and every renderWindow() call fails closed with
// kStaleGeneration, producing no partial output — mirroring how
// Graph::evaluatePlayhead treats a mismatched generation. Similarly, when
// routing resolves zero providers, or every routed provider reports a
// silent buffer for the requested window, renderWindow() reports kSilence
// (zero output, no mix() call) rather than an error, mirroring how
// evaluatePlayhead::kNoActiveNodes is a "nothing active" outcome rather than
// a corruption outcome, whenever the target mix node itself is valid.
// Providers whose buffer is not silent are the only ones passed to
// AudioMixBusNode::mix() as MixTrack entries.
//
// All scratch (per-track PCM windows, MixTrack descriptors) is preallocated
// in the constructor from the target AudioMixBusNode's maxFramesPerMix(),
// channelCount(), and the fixed AudioMixBusNode::kMaxTrackCount bound.
// renderWindow() never allocates.
class GraphAudioScheduler {
public:
    enum class SchedulerResult {
        kOk,                    // mixed successfully; output written
        kSilence,                // zero routed provider tracks, or every routed provider
                                 // reported a silent buffer for this window; output zeroed,
                                 // no mix() call
        kStaleGeneration,        // graph mutated since construction; output untouched
        kInvalidTarget,          // target node missing or not an AudioMixBusNode; output untouched
        kInvalidFrameCount,      // frameCount <= 0 or > target maxFramesPerMix; output untouched
        kInsufficientCapacity,   // outCapacitySamples too small or outPcm null; output untouched
        kSampleRateMismatch,     // a routed provider's format doesn't match the target bus; no resampling
        kProviderMissing,        // a resolved route has no live provider pointer
        kProviderError,          // a routed provider's provide() returned a non-ok Status
        kMixFailure,             // AudioMixBusNode::mix() returned a non-kOk MixResult
    };

    struct SchedulerOutput {
        int64_t  framesRendered{0};
        uint64_t checksum{0};
        size_t   routedTrackCount{0};
        bool     mixCalled{false};
        bool     silence{false};
    };

    // `graph` and every provider pointer in `providers` must outlive this
    // scheduler. `providers` maps a source node id to a non-owning
    // AudioSampleProvider*; scheduler never takes ownership.
    GraphAudioScheduler(const graph::Graph& graph,
                        std::string targetMixNodeId,
                        const std::unordered_map<std::string, AudioSampleProvider*>& providers);

    // Derives the graph/timeline-gating pts for a frame cursor position:
    // ptsUs = floor(startFrame * 1000000 / sampleRate), computed purely with
    // uint64/int64 integer math (no float/double timebase). The frame
    // cursor remains authoritative; this value is informational only.
    static uint64_t ComputeWindowPtsUs(int64_t startFrame, int32_t sampleRate) noexcept;

    SchedulerResult renderWindow(int64_t startFrame,
                                 int64_t frameCount,
                                 int16_t* outPcm,
                                 int64_t outCapacitySamples,
                                 SchedulerOutput* outResult) noexcept;

    // Diagnostics (test/JNI visible only; no production semantics).
    bool     targetValid()        const { return targetValid_; }
    uint64_t snapshotGeneration() const { return snapshotGeneration_; }
    int32_t  sampleRate()         const { return sampleRate_; }
    int32_t  channelCount()       const { return channelCount_; }
    int64_t  maxFramesPerMix()    const { return maxFramesPerMix_; }

    size_t routedSourceCount() const { return routedSources_.size(); }
    const std::string& routedSourceIdAt(size_t index) const;

    // Constant across the scheduler's lifetime (sized once in the
    // constructor); used to prove renderWindow() performs no per-window
    // heap allocation by comparing this value before/after repeated calls.
    size_t trackScratchCapacitySamples() const { return trackScratch_.capacity(); }
    size_t trackScratchCapacityTracks()  const { return kMaxRoutedTracks; }

private:
    struct RoutedSource {
        std::string           nodeId;
        AudioSampleProvider*  provider{nullptr};
    };

    static constexpr size_t kMaxRoutedTracks = AudioMixBusNode::kMaxTrackCount;

    const graph::Graph&              graph_;
    std::string                      targetMixNodeId_;
    uint64_t                         snapshotGeneration_{0};
    std::shared_ptr<AudioMixBusNode> mixBus_;
    bool                             targetValid_{false};

    int32_t sampleRate_{0};
    int32_t channelCount_{0};
    int64_t maxFramesPerMix_{0};
    int64_t perTrackStrideSamples_{0};

    std::vector<RoutedSource> routedSources_;

    // Preallocated scratch: one contiguous PCM16 window per potential
    // routed track (kMaxRoutedTracks * maxFramesPerMix_ * channelCount_
    // samples), plus a fixed-capacity MixTrack descriptor array.
    std::vector<int16_t>                   trackScratch_;
    std::vector<AudioMixBusNode::MixTrack> mixTracksScratch_;

    static const std::string kEmptySourceId;
};

} // namespace audio
} // namespace vanguard
