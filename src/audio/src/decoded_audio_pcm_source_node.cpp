#include "vanguard/audio/decoded_audio_pcm_source_node.h"

#include <limits>
#include <stdexcept>
#include <utility>

namespace vanguard {
namespace audio {

DecodedAudioPcmSourceNode::DecodedAudioPcmSourceNode(std::string id,
                                                      int32_t sampleRate,
                                                      int32_t channelCount,
                                                      int64_t expectedFrameCount,
                                                      uint64_t timelineStartPtsUs)
    : id_(std::move(id)),
      sampleRate_(sampleRate),
      channelCount_(channelCount),
      expectedFrameCount_(expectedFrameCount),
      timelineStartPtsUs_(timelineStartPtsUs) {
    if (id_.empty()) {
        throw std::invalid_argument("empty_id");
    }
    if (sampleRate_ < kMinSampleRate || sampleRate_ > kMaxSampleRate) {
        throw std::invalid_argument("invalid_sample_rate");
    }
    if (channelCount_ < kMinChannelCount || channelCount_ > kMaxChannelCount) {
        throw std::invalid_argument("invalid_channel_count");
    }
    if (expectedFrameCount_ <= 0 ||
        expectedFrameCount_ > static_cast<int64_t>(sampleRate_) * 10) {
        throw std::invalid_argument("invalid_expected_frame_count");
    }

    outputPorts_.push_back({"audio_out", vanguard::graph::PortDataType::kAudioPacket});
}

const std::string& DecodedAudioPcmSourceNode::id() const {
    return id_;
}

vanguard::graph::NodeKind DecodedAudioPcmSourceNode::kind() const {
    return vanguard::graph::NodeKind::kSource;
}

vanguard::graph::NodeType DecodedAudioPcmSourceNode::type() const {
    return vanguard::graph::NodeType::kAudioSource;
}

const std::vector<vanguard::graph::PortDescriptor>& DecodedAudioPcmSourceNode::inputPorts() const {
    return inputPorts_;
}

const std::vector<vanguard::graph::PortDescriptor>& DecodedAudioPcmSourceNode::outputPorts() const {
    return outputPorts_;
}

int32_t DecodedAudioPcmSourceNode::sampleRate() const {
    return sampleRate_;
}

int32_t DecodedAudioPcmSourceNode::channelCount() const {
    return channelCount_;
}

int64_t DecodedAudioPcmSourceNode::expectedFrameCount() const {
    return expectedFrameCount_;
}

uint64_t DecodedAudioPcmSourceNode::timelineStartPtsUs() const {
    return timelineStartPtsUs_;
}

bool DecodedAudioPcmSourceNode::isActiveAt(uint64_t timelinePtsUs) const {
    const uint64_t durationUs =
        (static_cast<uint64_t>(expectedFrameCount_) * 1000000ULL) / static_cast<uint64_t>(sampleRate_);
    const uint64_t endPtsUs =
        (std::numeric_limits<uint64_t>::max() - timelineStartPtsUs_ < durationUs)
            ? std::numeric_limits<uint64_t>::max()
            : timelineStartPtsUs_ + durationUs;

    return timelinePtsUs >= timelineStartPtsUs_ && timelinePtsUs < endPtsUs;
}

uint64_t DecodedAudioPcmSourceNode::mapTimelineToLocalPts(uint64_t timelinePtsUs) const {
    const uint64_t durationUs =
        (static_cast<uint64_t>(expectedFrameCount_) * 1000000ULL) / static_cast<uint64_t>(sampleRate_);

    if (timelinePtsUs < timelineStartPtsUs_) {
        return 0;
    }

    const uint64_t elapsedUs = timelinePtsUs - timelineStartPtsUs_;
    return elapsedUs < durationUs ? elapsedUs : durationUs;
}

int64_t DecodedAudioPcmSourceNode::ingestedFrameCount() const {
    return ingestedFrameCount_;
}

bool DecodedAudioPcmSourceNode::isEndOfStream() const {
    return eos_;
}

int64_t DecodedAudioPcmSourceNode::lastBufferPtsUs() const {
    return lastBufferPtsUs_;
}

int64_t DecodedAudioPcmSourceNode::chunkCount() const {
    return chunkCount_;
}

bool DecodedAudioPcmSourceNode::hasNonZeroSamples() const {
    return hasNonZeroSamples_;
}

int32_t DecodedAudioPcmSourceNode::peakAbs() const {
    return peakAbs_;
}

uint64_t DecodedAudioPcmSourceNode::checksum() const {
    return checksum_;
}

DecodedAudioPcmSourceNode::IngestResult DecodedAudioPcmSourceNode::ingestChunk(
    const int16_t* pcm,
    int64_t frameCount,
    int64_t bufferPtsUs,
    bool isEndOfStream) {
    if (eos_) {
        return IngestResult::kAlreadyEndOfStream;
    }
    if (frameCount <= 0 || frameCount > kMaxChunkFrames) {
        return IngestResult::kInvalidFrameCount;
    }
    if (pcm == nullptr) {
        return IngestResult::kNullBuffer;
    }
    if (hasLastBufferPts_ && bufferPtsUs < lastBufferPtsUs_) {
        return IngestResult::kNonMonotonicPts;
    }
    if (ingestedFrameCount_ + frameCount > expectedFrameCount_) {
        return IngestResult::kExceedsExpectedFrames;
    }

    const int64_t sampleCount = frameCount * static_cast<int64_t>(channelCount_);
    for (int64_t i = 0; i < sampleCount; ++i) {
        const int16_t sample = pcm[i];
        if (sample != 0) {
            hasNonZeroSamples_ = true;
        }
        const int32_t absSample = (sample == INT16_MIN)
            ? static_cast<int32_t>(INT16_MAX) + 1
            : static_cast<int32_t>(sample < 0 ? -sample : sample);
        if (absSample > peakAbs_) {
            peakAbs_ = absSample;
        }
        checksum_ = checksum_ * 31u + static_cast<uint64_t>(static_cast<uint16_t>(sample));
    }

    ingestedFrameCount_ += frameCount;
    lastBufferPtsUs_ = bufferPtsUs;
    hasLastBufferPts_ = true;
    chunkCount_ += 1;
    eos_ = isEndOfStream;

    return IngestResult::kOk;
}

bool DecodedAudioPcmSourceNode::validateComplete() const {
    return eos_ && ingestedFrameCount_ == expectedFrameCount_;
}

} // namespace audio
} // namespace vanguard
