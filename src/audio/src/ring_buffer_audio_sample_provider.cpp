#include "vanguard/audio/ring_buffer_audio_sample_provider.h"

#include <stdexcept>

namespace vanguard {
namespace audio {

RingBufferAudioSampleProvider::RingBufferAudioSampleProvider(AudioSpscAudioRingBuffer* ring,
                                                               int64_t startFrame)
    : ring_(ring),
      sampleRate_(ring != nullptr ? ring->sampleRate() : 0),
      channelCount_(ring != nullptr ? ring->channelCount() : 0),
      expectedNextFrame_(startFrame) {
    if (ring_ == nullptr) {
        throw std::invalid_argument("null_ring");
    }
    if (startFrame < 0) {
        throw std::invalid_argument("invalid_start_frame");
    }
}

core::Status RingBufferAudioSampleProvider::provide(const AudioWindowRequest& request,
                                                      AudioWindowBuffer& outBuffer) noexcept {
    outBuffer.framesWritten = 0;
    outBuffer.silent        = true;

    int64_t seekTargetFrame = 0;
    if (ring_->consumePendingSeekOnReaderThread(&seekTargetFrame)) {
        expectedNextFrame_ = seekTargetFrame;
    }

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

    // Destructive FIFO: rewind fails closed, cursor left untouched.
    if (request.startFrame < expectedNextFrame_) {
        ++rewindRejects_;
        return core::Status(core::StatusCode::kError, "provide: rewind_rejected");
    }

    if (request.startFrame > expectedNextFrame_) {
        int64_t remaining = request.startFrame - expectedNextFrame_;
        while (remaining > 0) {
            const int64_t discarded = ring_->discardFrames(remaining);
            if (discarded <= 0) {
                break;
            }
            forwardSkipFrames_ += static_cast<uint64_t>(discarded);
            remaining -= discarded;
        }
        expectedNextFrame_ = request.startFrame;
    }

    const int64_t popped = ring_->tryPopFrames(outBuffer.pcm, request.frameCount);
    if (popped < request.frameCount) {
        const int64_t missingFrames  = request.frameCount - popped;
        const int64_t missingSamples = missingFrames * static_cast<int64_t>(channelCount_);
        int16_t* zeroStart = outBuffer.pcm + popped * static_cast<int64_t>(channelCount_);
        for (int64_t i = 0; i < missingSamples; ++i) {
            zeroStart[i] = 0;
        }
        ++underrunEvents_;
        framesZeroFilled_ += static_cast<uint64_t>(missingFrames);
    }

    expectedNextFrame_ += request.frameCount;
    outBuffer.framesWritten = request.frameCount;
    outBuffer.silent        = (popped == 0);
    return core::Status::OK();
}

core::Status RingBufferAudioSampleProvider::reanchorAfterExternalSeek(
    int64_t targetFrame) noexcept {
    if (targetFrame < 0) {
        return core::Status(core::StatusCode::kError,
                            "reanchorAfterExternalSeek: negative target frame");
    }
    // Cursor-only: the caller already consumed this ring's seek ack for
    // exactly this frame on this (consumer) thread; the ring is not touched.
    expectedNextFrame_         = targetFrame;
    lastExternalReanchorFrame_ = targetFrame;
    ++externalReanchorCount_;
    return core::Status::OK();
}

} // namespace audio
} // namespace vanguard
