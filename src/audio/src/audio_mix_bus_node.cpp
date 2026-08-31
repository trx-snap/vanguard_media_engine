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
    inputPorts_.push_back({"audio_in_2", vanguard::graph::PortDataType::kAudioPacket});
    inputPorts_.push_back({"audio_in_3", vanguard::graph::PortDataType::kAudioPacket});
    inputPorts_.push_back({"audio_in_4", vanguard::graph::PortDataType::kAudioPacket});
    inputPorts_.push_back({"audio_in_5", vanguard::graph::PortDataType::kAudioPacket});
    inputPorts_.push_back({"audio_in_6", vanguard::graph::PortDataType::kAudioPacket});
    inputPorts_.push_back({"audio_in_7", vanguard::graph::PortDataType::kAudioPacket});
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
        if (track.envelope != nullptr) {
            if (track.envelopeStartPtsUs < 0) {
                return MixResult::kInvalidEnvelopeStartPts;
            }
            // Fail-before-output: pre-scan every frame this track will mix
            // (integer-microsecond floor PTS derivation) so an invalid
            // envelope gain rejects before the accumulator or output buffer
            // is touched. Cursor is call-local; no envelope state persists.
            const int64_t scanFrames =
                framesToMix < track.frameCount ? framesToMix : track.frameCount;
            size_t cursor = 0;
            for (int64_t f = 0; f < scanFrames; ++f) {
                const int64_t ptsUs = track.envelopeStartPtsUs +
                    (f * 1000000LL) / static_cast<int64_t>(sampleRate_);
                const double envelopeGain = track.envelope->evaluateCursor(ptsUs, &cursor);
                if (!std::isfinite(envelopeGain) || envelopeGain < 0.0 ||
                    envelopeGain > 1.0) {
                    return MixResult::kInvalidEnvelopeGain;
                }
            }
        }
    }

    for (int64_t i = 0; i < requiredOutputSamples; ++i) {
        accumulator_[static_cast<size_t>(i)] = 0;
    }

    bool    envelopeApplied     = false;
    bool    effectiveGainSeen   = false;
    double  minEffectiveGain    = 0.0;
    double  maxEffectiveGain    = 0.0;
    int64_t envelopeEvaluations = 0;

    for (size_t t = 0; t < trackCount; ++t) {
        const MixTrack& track = tracks[t];
        // Per-track, per-call envelope cursor: reset here so repeated mix()
        // calls are stateless and bit-reproducible.
        size_t envelopeCursor = 0;
        for (int64_t f = 0; f < framesToMix; ++f) {
            if (f >= track.frameCount) {
                continue; // Track has run out of frames; contributes silence.
            }
            // Single quantization: the sample (or integer-downmixed value)
            // is multiplied by the one effective gain and truncated to the
            // int32 accumulator exactly once; the only clamp happens at the
            // final output stage below. A null envelope leaves
            // effectiveGain == track.gain, bit-identical to the previous
            // static-gain behaviour.
            double effectiveGain = track.gain;
            if (track.envelope != nullptr) {
                const int64_t ptsUs = track.envelopeStartPtsUs +
                    (f * 1000000LL) / static_cast<int64_t>(sampleRate_);
                effectiveGain =
                    track.gain * track.envelope->evaluateCursor(ptsUs, &envelopeCursor);
                ++envelopeEvaluations;
                envelopeApplied = true;
                if (!effectiveGainSeen || effectiveGain < minEffectiveGain) {
                    minEffectiveGain = effectiveGain;
                }
                if (!effectiveGainSeen || effectiveGain > maxEffectiveGain) {
                    maxEffectiveGain = effectiveGain;
                }
                effectiveGainSeen = true;
            }
            if (track.channelCount == channelCount_) {
                for (int32_t ch = 0; ch < channelCount_; ++ch) {
                    const int16_t sample = track.pcm[f * channelCount_ + ch];
                    const int32_t scaled =
                        static_cast<int32_t>(static_cast<double>(sample) * effectiveGain);
                    accumulator_[static_cast<size_t>(f * channelCount_ + ch)] += scaled;
                }
            } else if (track.channelCount == 1 && channelCount_ == 2) {
                const int16_t mono = track.pcm[f];
                const int32_t scaled =
                    static_cast<int32_t>(static_cast<double>(mono) * effectiveGain);
                accumulator_[static_cast<size_t>(f * 2 + 0)] += scaled;
                accumulator_[static_cast<size_t>(f * 2 + 1)] += scaled;
            } else { // track.channelCount == 2 && channelCount_ == 1
                const int16_t l = track.pcm[f * 2 + 0];
                const int16_t r = track.pcm[f * 2 + 1];
                const int32_t downmixed =
                    (static_cast<int32_t>(l) + static_cast<int32_t>(r)) / 2;
                const int32_t scaled =
                    static_cast<int32_t>(static_cast<double>(downmixed) * effectiveGain);
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
        outResult->framesMixed         = framesToMix;
        outResult->checksum            = checksum;
        outResult->clipped             = clipped;
        outResult->maxAccumulatorAbs   = maxAccumulatorAbs;
        outResult->envelopeApplied     = envelopeApplied;
        outResult->minEffectiveGain    = minEffectiveGain;
        outResult->maxEffectiveGain    = maxEffectiveGain;
        outResult->envelopeEvaluations = envelopeEvaluations;
    }

    return MixResult::kOk;
}

} // namespace audio
} // namespace vanguard
