#include "vanguard/audio/audio_decoder_ring_writer.h"

#include <stdexcept>

namespace vanguard {
namespace audio {

AudioDecoderRingWriter::AudioDecoderRingWriter(AudioSpscAudioRingBuffer* ringBuffer,
                                                 int32_t expectedSampleRate,
                                                 int32_t expectedChannelCount)
    : ring_(ringBuffer),
      expectedSampleRate_(expectedSampleRate),
      expectedChannelCount_(expectedChannelCount) {
    if (ring_ == nullptr) {
        throw std::invalid_argument("null_ring");
    }
    if (expectedSampleRate_ <= 0) {
        throw std::invalid_argument("invalid_sample_rate");
    }
    if (expectedChannelCount_ <= 0) {
        throw std::invalid_argument("invalid_channel_count");
    }
    if (expectedSampleRate_ != ring_->sampleRate() || expectedChannelCount_ != ring_->channelCount()) {
        throw std::invalid_argument("format_mismatch");
    }
}

AudioDecoderRingWriter::Status AudioDecoderRingWriter::write(const int16_t* pcm,
                                                                int64_t frames,
                                                                int32_t sampleRate,
                                                                int32_t channelCount,
                                                                int64_t* outFramesWritten) noexcept {
    if (outFramesWritten != nullptr) {
        *outFramesWritten = 0;
    }

    if (pcm == nullptr || frames <= 0 || frames > kMaxWriteFrames) {
        ++metrics_.invalidArgumentRejects;
        return Status::kInvalidArgument;
    }

    if (sampleRate != expectedSampleRate_ || channelCount != expectedChannelCount_) {
        ++metrics_.formatMismatches;
        return Status::kFormatMismatch;
    }

    if (eos_) {
        return Status::kAlreadyEos;
    }

    if (ring_->seekAck() != ring_->seekRequest()) {
        ++metrics_.awaitingSeekAckRejects;
        return Status::kAwaitingSeekAck;
    }

    const int64_t accepted = ring_->tryPushFrames(pcm, frames);
    if (outFramesWritten != nullptr) {
        *outFramesWritten = accepted;
    }

    if (accepted == frames) {
        nextWriteFrame_ += accepted;
        metrics_.totalFramesWritten += static_cast<uint64_t>(accepted);
        return Status::kOk;
    }

    if (accepted > 0) {
        nextWriteFrame_ += accepted;
        metrics_.totalFramesWritten += static_cast<uint64_t>(accepted);
        ++metrics_.partialWriteEvents;
        return Status::kPartialWrite;
    }

    ++metrics_.backpressureRejects;
    return Status::kRingFull;
}

void AudioDecoderRingWriter::setEos() noexcept {
    if (eos_) {
        return;
    }
    eos_ = true;
    ++metrics_.eosEvents;
}

AudioDecoderRingWriter::Status AudioDecoderRingWriter::requestSeek(int64_t targetFrame) noexcept {
    if (targetFrame < 0) {
        return Status::kInvalidArgument;
    }

    if (!ring_->requestSeek(targetFrame)) {
        return Status::kInvalidArgument;
    }

    ++metrics_.seekRequests;
    nextWriteFrame_ = targetFrame;
    eos_ = false;
    return Status::kOk;
}

} // namespace audio
} // namespace vanguard
