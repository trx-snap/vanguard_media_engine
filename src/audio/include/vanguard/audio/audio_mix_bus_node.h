#pragma once
#include "vanguard/graph/node.h"
#include <cstddef>
#include <cstdint>
#include <string>
#include <vector>

namespace vanguard {
namespace audio {

// P4-AUDIO-MIXBUS: bounded native PCM16 mix-bus foundation. Platform-neutral
// C++ only: no JNI/Android APIs, no threads, no file IO. Mixes up to two
// already-decoded interleaved PCM16 tracks into one output buffer using pure
// in-memory integer/double math. Kotlin remains the sole owner of
// MediaExtractor/MediaCodec/AudioTrack; this node never touches those APIs.
class AudioMixBusNode : public vanguard::graph::Node {
public:
    AudioMixBusNode(std::string id,
                     int32_t sampleRate,
                     int32_t channelCount,
                     int64_t maxFramesPerMix);

    const std::string&                                  id()          const override;
    vanguard::graph::NodeKind                           kind()        const override;
    vanguard::graph::NodeType                           type()        const override;
    const std::vector<vanguard::graph::PortDescriptor>& inputPorts()  const override;
    const std::vector<vanguard::graph::PortDescriptor>& outputPorts() const override;

    int32_t sampleRate()      const;
    int32_t channelCount()    const;
    int64_t maxFramesPerMix() const;

    enum class MixResult {
        kOk,
        kInvalidGain,
        kInvalidTrackCount,
        kInvalidChannelCount,
        kSampleRateMismatch,
        kInvalidFrameCount,
        kNullBuffer,
        kInsufficientOutputCapacity,
    };

    // One input track for a single mix() call. `pcm` must contain at least
    // `frameCount * channelCount` interleaved int16_t samples and must
    // outlive the mix() call; this node never retains the pointer.
    //
    // NOTE: Kotlin's AndroidAudioVolumeEnvelope.fromStatic can emit an
    // effective gain > 1.0 today (unclamped `track.volume` feeding
    // `volume * mixGain`); production integration must clamp or explicitly
    // decide to widen the accepted range later. This diagnostic bus rejects
    // any gain outside [0,1] via kInvalidGain.
    struct MixTrack {
        const int16_t* pcm;
        int64_t        frameCount;
        int32_t        sampleRate;
        int32_t        channelCount;
        double         gain;
    };

    // Result metrics for a single mix() call, populated only when the call
    // returns MixResult::kOk (mix() also zero-initializes *outResult before
    // validating, so a failing call leaves it at its zero value).
    struct MixOutput {
        int64_t  framesMixed{0};
        uint64_t checksum{0};
        bool     clipped{false};
        int32_t  maxAccumulatorAbs{0};
    };

    // Mixes `trackCount` tracks (1..inputPorts().size()) into `out`,
    // interleaved PCM16, `framesToMix * channelCount()` samples. A track
    // shorter than `framesToMix` contributes silence past its own
    // frameCount; a track longer than `framesToMix` contributes only its
    // first `framesToMix` frames. Never throws; all failure modes are
    // reported via the returned MixResult.
    MixResult mix(const MixTrack* tracks,
                  size_t          trackCount,
                  int64_t         framesToMix,
                  int16_t*        out,
                  int64_t         outCapacitySamples,
                  MixOutput*      outResult) noexcept;

    static constexpr int32_t kMinSampleRate      = 8000;
    static constexpr int32_t kMaxSampleRate      = 192000;
    static constexpr int32_t kMinChannelCount    = 1;
    static constexpr int32_t kMaxChannelCount    = 2;
    static constexpr int64_t kMinMaxFramesPerMix = 1;
    static constexpr int64_t kMaxMaxFramesPerMix = 8192;
    static constexpr size_t  kMaxTrackCount      = 2;

private:
    std::string id_;
    int32_t     sampleRate_;
    int32_t     channelCount_;
    int64_t     maxFramesPerMix_;

    std::vector<vanguard::graph::PortDescriptor> inputPorts_;
    std::vector<vanguard::graph::PortDescriptor> outputPorts_;

    // Reusable scratch accumulator sized maxFramesPerMix_ * channelCount_ in
    // the constructor; mix() clears and reuses only the samples it needs for
    // the current call.
    std::vector<int32_t> accumulator_;
};

} // namespace audio
} // namespace vanguard
