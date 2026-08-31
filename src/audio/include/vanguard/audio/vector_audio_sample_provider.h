#pragma once
#include "vanguard/audio/audio_sample_provider.h"
#include <cstdint>
#include <stdexcept>
#include <utility>
#include <vector>

namespace vanguard {
namespace audio {

// P4-AUDIO-GRAPH-TRANSPORT-CLOCK (sub-slice A): bounded, diagnostic-only,
// vector-backed AudioSampleProvider. Retains a small caller-supplied PCM16
// vector in memory and serves synchronous window pulls against it, gated by
// a fixed timeline start expressed in frames (derived once at construction
// from timelineStartPtsUs and sampleRate via integer floor math; the frame
// cursor, not the derived pts, is what every subsequent provide() call
// compares against).
//
// This is explicitly NOT a production or realtime provider: it exists only
// to give GraphAudioScheduler proof tests a controllable, non-owning-
// compatible PCM source. No threads, no queues, no Android APIs.
class VectorAudioSampleProvider : public AudioSampleProvider {
public:
    static constexpr int64_t kMaxFrames  = 8192;
    static constexpr int64_t kMaxSamples = 16384;

    VectorAudioSampleProvider(int32_t sampleRate,
                               int32_t channelCount,
                               uint64_t timelineStartPtsUs,
                               std::vector<int16_t> pcm)
        : sampleRate_(sampleRate),
          channelCount_(channelCount),
          pcm_(std::move(pcm)) {
        if (sampleRate_ <= 0) {
            throw std::invalid_argument("invalid_sample_rate");
        }
        if (channelCount_ != 1 && channelCount_ != 2) {
            throw std::invalid_argument("invalid_channel_count");
        }
        if (pcm_.size() > static_cast<size_t>(kMaxSamples)) {
            throw std::invalid_argument("pcm_too_large");
        }
        if (pcm_.size() % static_cast<size_t>(channelCount_) != 0) {
            throw std::invalid_argument("pcm_not_frame_aligned");
        }
        frameCount_ = static_cast<int64_t>(pcm_.size()) / channelCount_;
        if (frameCount_ > kMaxFrames) {
            throw std::invalid_argument("frame_count_too_large");
        }
        // Frame cursor is authoritative: convert the timeline start once,
        // here, via integer floor math and never recompute it per window.
        timelineStartFrame_ = static_cast<int64_t>(
            (static_cast<uint64_t>(timelineStartPtsUs) *
             static_cast<uint64_t>(sampleRate_)) / 1000000ULL);
    }

    int32_t sampleRate()   const override { return sampleRate_; }
    int32_t channelCount() const override { return channelCount_; }

    int64_t timelineStartFrame() const { return timelineStartFrame_; }
    int64_t frameCount()         const { return frameCount_; }

    core::Status provide(const AudioWindowRequest& request,
                         AudioWindowBuffer& outBuffer) noexcept override {
        outBuffer.framesWritten = 0;
        outBuffer.silent        = true;

        if (outBuffer.pcm == nullptr) {
            return core::Status(core::StatusCode::kError, "provide: null output buffer");
        }
        if (request.frameCount <= 0 ||
            request.sampleRate != sampleRate_ ||
            request.channelCount != channelCount_) {
            return core::Status(core::StatusCode::kError, "provide: invalid request");
        }
        const int64_t requiredSamples = request.frameCount * static_cast<int64_t>(channelCount_);
        if (outBuffer.capacitySamples < requiredSamples) {
            return core::Status(core::StatusCode::kError, "provide: insufficient capacity");
        }

        for (int64_t i = 0; i < requiredSamples; ++i) {
            outBuffer.pcm[i] = 0;
        }

        const int64_t windowStart = request.startFrame;
        const int64_t windowEnd   = request.startFrame + request.frameCount; // exclusive
        const int64_t sourceStart = timelineStartFrame_;
        const int64_t sourceEnd   = timelineStartFrame_ + frameCount_;       // exclusive

        const int64_t overlapStart = windowStart > sourceStart ? windowStart : sourceStart;
        const int64_t overlapEnd   = windowEnd   < sourceEnd   ? windowEnd   : sourceEnd;

        bool wroteAny = false;
        if (overlapStart < overlapEnd) {
            for (int64_t f = overlapStart; f < overlapEnd; ++f) {
                const int64_t destFrame = f - windowStart;
                const int64_t srcFrame  = f - sourceStart;
                for (int32_t ch = 0; ch < channelCount_; ++ch) {
                    outBuffer.pcm[destFrame * channelCount_ + ch] =
                        pcm_[static_cast<size_t>(srcFrame * channelCount_ + ch)];
                }
            }
            wroteAny = true;
        }

        outBuffer.framesWritten = request.frameCount;
        outBuffer.silent        = !wroteAny;
        return core::Status::OK();
    }

private:
    int32_t               sampleRate_;
    int32_t               channelCount_;
    std::vector<int16_t>  pcm_;
    int64_t               frameCount_{0};
    int64_t               timelineStartFrame_{0};
};

} // namespace audio
} // namespace vanguard
