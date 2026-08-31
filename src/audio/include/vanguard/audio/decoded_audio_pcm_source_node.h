#pragma once
#include "vanguard/audio/audio_decoder_ring_writer.h"
#include "vanguard/audio/audio_ring_buffer.h"
#include "vanguard/audio/audio_sample_provider.h"
#include "vanguard/audio/ring_buffer_audio_sample_provider.h"
#include "vanguard/graph/node.h"
#include <cstddef>
#include <cstdint>
#include <memory>
#include <string>
#include <vector>

namespace vanguard {
namespace audio {

// P2-AUDIO-DEC-BRIDGE: bounded DAG audio-source boundary for decoded PCM.
//
// Kotlin remains the sole owner of MediaExtractor/MediaCodec OS audio
// decoding; this node only receives already-decoded 16-bit interleaved PCM
// chunks handed across the JNI boundary and validates/accumulates them as a
// DAG source, so future native C++ audio nodes have a well-defined ingest
// contract. No file IO, no Android APIs, no threads.
//
// P4-AUDIO-DECODER-SOURCE-NODE-WIRING: the 6-arg constructor additionally
// makes the node own (by composition, not inheritance) one
// AudioSpscAudioRingBuffer + AudioDecoderRingWriter +
// RingBufferAudioSampleProvider triple, so a graph-topology walk can
// discover the node's transport endpoints instead of an external provider
// registry. The legacy 5-arg constructor owns none of these (all three
// accessors return null / ownsRing() is false) and keeps its exact
// pre-existing behavior. The node never wires the two roles together
// itself: the caller's producer thread drives ringWriter() and the ring's
// single consumer thread drives audioSampleProvider(), exactly per the
// underlying primitives' SPSC contracts.
class DecodedAudioPcmSourceNode : public vanguard::graph::Node {
public:
    DecodedAudioPcmSourceNode(std::string id,
                               int32_t sampleRate,
                               int32_t channelCount,
                               int64_t expectedFrameCount,
                               uint64_t timelineStartPtsUs);

    // Node-owned transport construction. Validates the 5 legacy args
    // identically to the legacy constructor, then validates
    // ringCapacityFrames through AudioSpscAudioRingBuffer construction
    // (std::invalid_argument tokens "invalid_capacity_frames" /
    // "capacity_frames_not_power_of_two" propagate unchanged). The owned
    // provider's reader cursor is seeded at frame 0.
    DecodedAudioPcmSourceNode(std::string id,
                               int32_t sampleRate,
                               int32_t channelCount,
                               int64_t expectedFrameCount,
                               uint64_t timelineStartPtsUs,
                               int64_t ringCapacityFrames);

    const std::string&                                  id()          const override;
    vanguard::graph::NodeKind                           kind()        const override;
    vanguard::graph::NodeType                           type()        const override;
    const std::vector<vanguard::graph::PortDescriptor>& inputPorts()  const override;
    const std::vector<vanguard::graph::PortDescriptor>& outputPorts() const override;

    bool     isActiveAt(uint64_t timelinePtsUs) const override;
    uint64_t mapTimelineToLocalPts(uint64_t timelinePtsUs) const override;

    int32_t  sampleRate()          const;
    int32_t  channelCount()        const;
    int64_t  expectedFrameCount()  const;
    uint64_t timelineStartPtsUs()  const;

    int64_t  ingestedFrameCount()  const;
    bool     isEndOfStream()       const;
    int64_t  lastBufferPtsUs()     const;
    int64_t  chunkCount()          const;
    bool     hasNonZeroSamples()   const;
    int32_t  peakAbs()             const;
    uint64_t checksum()            const;

    // Result of a single ingest call.
    enum class IngestResult {
        kOk,
        kAlreadyEndOfStream,
        kInvalidFrameCount,
        kSampleCountMismatch,
        kNonMonotonicPts,
        kExceedsExpectedFrames,
        kNullBuffer,
    };

    // Ingests one PCM16 chunk of interleaved samples. `pcm` must contain at
    // least `frameCount * channelCount()` int16_t samples.
    IngestResult ingestChunk(const int16_t* pcm,
                              int64_t frameCount,
                              int64_t bufferPtsUs,
                              bool isEndOfStream);

    // True only once EOS has been observed and the exact expected frame
    // count has been ingested.
    bool validateComplete() const;

    // Node-owned transport accessors. All return null (ownsRing() false)
    // when the node was built with the legacy 5-arg constructor.
    bool ownsRing() const noexcept { return ring_ != nullptr; }
    AudioSampleProvider* audioSampleProvider() noexcept { return provider_.get(); }
    AudioDecoderRingWriter* ringWriter() noexcept { return ringWriter_.get(); }
    AudioSpscAudioRingBuffer* ring() noexcept { return ring_.get(); }
    const AudioSpscAudioRingBuffer* ring() const noexcept { return ring_.get(); }

    static constexpr int64_t kMaxChunkFrames = 8192;
    static constexpr int32_t kMinSampleRate  = 8000;
    static constexpr int32_t kMaxSampleRate  = 192000;
    static constexpr int32_t kMinChannelCount = 1;
    static constexpr int32_t kMaxChannelCount = 2;

private:
    std::string id_;
    int32_t     sampleRate_;
    int32_t     channelCount_;
    int64_t     expectedFrameCount_;
    uint64_t    timelineStartPtsUs_;

    std::vector<vanguard::graph::PortDescriptor> inputPorts_;
    std::vector<vanguard::graph::PortDescriptor> outputPorts_;

    int64_t  ingestedFrameCount_{0};
    bool     eos_{false};
    bool     hasLastBufferPts_{false};
    int64_t  lastBufferPtsUs_{0};
    int64_t  chunkCount_{0};
    bool     hasNonZeroSamples_{false};
    int32_t  peakAbs_{0};
    uint64_t checksum_{0};

    // Optional node-owned transport (6-arg constructor only). Declaration
    // order is construction order: the writer and provider both hold
    // non-owning pointers into ring_, so ring_ must be built first and
    // destroyed last (members destroy in reverse declaration order).
    std::unique_ptr<AudioSpscAudioRingBuffer>      ring_;
    std::unique_ptr<AudioDecoderRingWriter>        ringWriter_;
    std::unique_ptr<RingBufferAudioSampleProvider> provider_;
};

} // namespace audio
} // namespace vanguard
