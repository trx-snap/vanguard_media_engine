#include "vanguard/audio/audio_mix_bus_node.h"

#include <cmath>
#include <cstdlib>
#include <stdexcept>
#include <utility>

namespace vanguard {
namespace audio {

AudioMixBusNode::AudioMixBusNode(std::string id,
                                  int32_t sampleRate,
                                  int32_t channelCount,
                                  int64_t maxFramesPerMix)
    : id_(std::move(id)),
      sampleRate_(sampleRate),
      channelCount_(channelCount),
      maxFramesPerMix_(maxFramesPerMix) {
    if (id_.empty()) {
        throw std::invalid_argument("empty_id");
    }
    if (sampleRate_ < kMinSampleRate || sampleRate_ > kMaxSampleRate) {
        throw std::invalid_argument("invalid_sample_rate");
    }
    if (channelCount_ < kMinChannelCount || channelCount_ > kMaxChannelCount) {
        throw std::invalid_argument("invalid_channel_count");
    }
    if (maxFramesPerMix_ < kMinMaxFramesPerMix || maxFramesPerMix_ > kMaxMaxFramesPerMix) {
        throw std::invalid_argument("invalid_max_frames_per_mix");
    }

    inputPorts_.push_back({"primary_audio_in", vanguard::graph::PortDataType::kAudioPacket});
    inputPorts_.push_back({"secondary_audio_in", vanguard::graph::PortDataType::kAudioPacket});
    outputPorts_.push_back({"mixed_audio_out", vanguard::graph::PortDataType::kAudioPacket});

    accumulator_.assign(static_cast<size_t>(maxFramesPerMix_) * static_cast<size_t>(channelCount_), 0);
}

const std::string& AudioMixBusNode::id() const {
    return id_;
}

vanguard::graph::NodeKind AudioMixBusNode::kind() const {
    return vanguard::graph::NodeKind::kProcessing;
}

vanguard::graph::NodeType AudioMixBusNode::type() const {
    return vanguard::graph::NodeType::kAudioMixBus;
}

const std::vector<vanguard::graph::PortDescriptor>& AudioMixBusNode::inputPorts() const {
    return inputPorts_;
}

const std::vector<vanguard::graph::PortDescriptor>& AudioMixBusNode::outputPorts() const {
    return outputPorts_;
}

int32_t AudioMixBusNode::sampleRate() const {
    return sampleRate_;
}

int32_t AudioMixBusNode::channelCount() const {
    return channelCount_;
}

int64_t AudioMixBusNode::maxFramesPerMix() const {
    return maxFramesPerMix_;
}

AudioMixBusNode::MixResult AudioMixBusNode::mix(const MixTrack* tracks,
                                                 size_t          trackCount,
                                                 int64_t         framesToMix,
                                                 int16_t*        out,
                                                 int64_t         outCapacitySamples,
                                                 MixOutput*      outResult) noexcept {
    if (outResult != nullptr) {
        *outResult = MixOutput{};
    }

    if (trackCount < 1 || trackCount > kMaxTrackCount) {
        return MixResult::kInvalidTrackCount;
    }
    if (tracks == nullptr) {
        return MixResult::kNullBuffer;
    }
    if (framesToMix < 1 || framesToMix > maxFramesPerMix_) {
        return MixResult::kInvalidFrameCount;
    }
    if (out == nullptr) {
        return MixResult::kNullBuffer;
    }
    const int64_t requiredOutputSamples = framesToMix * static_cast<int64_t>(channelCount_);
    if (outCapacitySamples < requiredOutputSamples) {
        return MixResult::kInsufficientOutputCapacity;
    }

    for (size_t t = 0; t < trackCount; ++t) {
        const MixTrack& track = tracks[t];
        if (track.channelCount != 1 && track.channelCount != 2) {
            return MixResult::kInvalidChannelCount;
        }
        if (track.sampleRate != sampleRate_) {
            return MixResult::kSampleRateMismatch;
        }
        if (track.frameCount < 0) {
            return MixResult::kInvalidFrameCount;
        }
        if (track.pcm == nullptr && track.frameCount > 0) {
            return MixResult::kNullBuffer;
        }
        if (!std::isfinite(track.gain) || track.gain < 0.0 || track.gain > 1.0) {
            return MixResult::kInvalidGain;
        }
    }

    for (int64_t i = 0; i < requiredOutputSamples; ++i) {
        accumulator_[static_cast<size_t>(i)] = 0;
    }

    for (size_t t = 0; t < trackCount; ++t) {
        const MixTrack& track = tracks[t];
        for (int64_t f = 0; f < framesToMix; ++f) {
            if (f >= track.frameCount) {
                continue; // Track has run out of frames; contributes silence.
            }
            if (track.channelCount == channelCount_) {
                for (int32_t ch = 0; ch < channelCount_; ++ch) {
                    const int16_t sample = track.pcm[f * channelCount_ + ch];
                    const int32_t scaled =
                        static_cast<int32_t>(static_cast<double>(sample) * track.gain);
                    accumulator_[static_cast<size_t>(f * channelCount_ + ch)] += scaled;
                }
            } else if (track.channelCount == 1 && channelCount_ == 2) {
                const int16_t mono = track.pcm[f];
                const int32_t scaled =
                    static_cast<int32_t>(static_cast<double>(mono) * track.gain);
                accumulator_[static_cast<size_t>(f * 2 + 0)] += scaled;
                accumulator_[static_cast<size_t>(f * 2 + 1)] += scaled;
            } else { // track.channelCount == 2 && channelCount_ == 1
                const int16_t l = track.pcm[f * 2 + 0];
                const int16_t r = track.pcm[f * 2 + 1];
                const int32_t downmixed =
                    (static_cast<int32_t>(l) + static_cast<int32_t>(r)) / 2;
                const int32_t scaled =
                    static_cast<int32_t>(static_cast<double>(downmixed) * track.gain);
                accumulator_[static_cast<size_t>(f)] += scaled;
            }
        }
    }

    bool     clipped           = false;
    int32_t  maxAccumulatorAbs = 0;
    uint64_t checksum          = 0;

    for (int64_t i = 0; i < requiredOutputSamples; ++i) {
        const int32_t acc = accumulator_[static_cast<size_t>(i)];
        const int32_t absAcc = (acc == INT32_MIN) ? INT32_MAX : std::abs(acc);
        if (absAcc > maxAccumulatorAbs) {
            maxAccumulatorAbs = absAcc;
        }

        int32_t clamped = acc;
        if (clamped > 32767) {
            clamped = 32767;
            clipped = true;
        } else if (clamped < -32768) {
            clamped = -32768;
            clipped = true;
        }

        const int16_t sample = static_cast<int16_t>(clamped);
        out[i] = sample;
        checksum = checksum * 31u + static_cast<uint64_t>(static_cast<uint16_t>(sample));
    }

    if (outResult != nullptr) {
        outResult->framesMixed        = framesToMix;
        outResult->checksum           = checksum;
        outResult->clipped            = clipped;
        outResult->maxAccumulatorAbs  = maxAccumulatorAbs;
    }

    return MixResult::kOk;
}

} // namespace audio
} // namespace vanguard
