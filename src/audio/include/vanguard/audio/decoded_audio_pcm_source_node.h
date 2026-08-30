#pragma once
#include "vanguard/graph/node.h"
#include <cstddef>
#include <cstdint>
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
class DecodedAudioPcmSourceNode : public vanguard::graph::Node {
public:
    DecodedAudioPcmSourceNode(std::string id,
                               int32_t sampleRate,
                               int32_t channelCount,
                               int64_t expectedFrameCount,
                               uint64_t timelineStartPtsUs);

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
};

} // namespace audio
} // namespace vanguard
