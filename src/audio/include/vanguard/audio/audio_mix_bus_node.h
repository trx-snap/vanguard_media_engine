#pragma once
#include "vanguard/audio/audio_gain_envelope.h"
#include "vanguard/graph/node.h"
#include <cstddef>
#include <cstdint>
#include <string>
#include <vector>

namespace vanguard {
namespace audio {

// P4-AUDIO-MIXBUS: bounded native PCM16 mix-bus foundation. Platform-neutral
// C++ only: no JNI/Android APIs, no threads, no file IO. Mixes up to eight
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
        // Appended (P4-AUDIO-MIXBUS-TIMELINE-OWNERSHIP); never reorder the
        // enumerators above.
        kInvalidEnvelopeStartPts,
        kInvalidEnvelopeGain,
    };

    // One input track for a single mix() call. `pcm` must contain at least
    // `frameCount * channelCount` interleaved int16_t samples and must
    // outlive the mix() call; this node never retains the pointer.
    //
    // NOTE: Native `MixTrack.gain` accepts only finite `[0,1]` (rejected via
    // kInvalidGain). Android production integration evaluates the volume
    // envelope and clamps before calling native, recording clamping via
    // `nativeGainClamped`. Any future widening is a separate policy decision.
    //
    // P4-AUDIO-MIXBUS-TIMELINE-OWNERSHIP: an optional caller-owned
    // AudioGainEnvelope moves per-frame timeline gain math into this node.
    // The node owns the gain math; the caller owns the window origin:
    // `envelopeStartPtsUs` is the timeline PTS of frame 0 of this mix()
    // window, and the per-frame envelope time is derived on the integer
    // microsecond axis with floor division:
    //   ptsUs(f) = envelopeStartPtsUs + (f * 1000000) / sampleRate().
    // The effective per-frame gain is `gain * envelope->evaluate(ptsUs(f))`,
    // with every effective envelope gain required to be finite [0,1]
    // (rejected via kInvalidEnvelopeGain before any output mutation; a
    // negative envelopeStartPtsUs rejects via kInvalidEnvelopeStartPts).
    // A null envelope is bit-identical to the previous static-gain-only
    // behaviour. The envelope must outlive the mix() call; the node never
    // retains the pointer and keeps no envelope state across calls.
    //
    // A value-initialized MixTrack{} is the static unity/null-envelope
    // track template: unit gain, no envelope.
    struct MixTrack {
        const int16_t*           pcm{nullptr};
        int64_t                  frameCount{0};
        int32_t                  sampleRate{0};
        int32_t                  channelCount{0};
        double                   gain{1.0};
        const AudioGainEnvelope* envelope{nullptr};
        int64_t                  envelopeStartPtsUs{0};
    };

    // Result metrics for a single mix() call, populated only when the call
    // returns MixResult::kOk (mix() also zero-initializes *outResult before
    // validating, so a failing call leaves it at its zero value).
    // `envelopeApplied` is true when at least one mixed track carried a
    // non-null envelope; `minEffectiveGain`/`maxEffectiveGain` span the
    // per-frame effective gains (gain * envelopeGain) applied for
    // envelope-bearing tracks only (0.0/0.0 when none), and
    // `envelopeEvaluations` counts the accumulation-phase per-frame
    // envelope evaluations (the fail-before-output validation pre-scan is
    // not counted).
    struct MixOutput {
        int64_t  framesMixed{0};
        uint64_t checksum{0};
        bool     clipped{false};
        int32_t  maxAccumulatorAbs{0};
        bool     envelopeApplied{false};
        double   minEffectiveGain{0.0};
        double   maxEffectiveGain{0.0};
        int64_t  envelopeEvaluations{0};
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
    static constexpr size_t  kMaxTrackCount      = 8;

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
