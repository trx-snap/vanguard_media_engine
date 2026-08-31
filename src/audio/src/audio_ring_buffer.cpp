#include "vanguard/audio/audio_ring_buffer.h"

#include <stdexcept>

namespace vanguard {
namespace audio {

AudioSpscAudioRingBuffer::AudioSpscAudioRingBuffer(int32_t sampleRate,
                                                     int32_t channelCount,
                                                     int64_t capacityFrames)
    : sampleRate_(sampleRate),
      channelCount_(channelCount),
      capacityFrames_(capacityFrames) {
    if (sampleRate_ <= 0) {
        throw std::invalid_argument("invalid_sample_rate");
    }
    if (channelCount_ != 1 && channelCount_ != 2) {
        throw std::invalid_argument("invalid_channel_count");
    }
    if (capacityFrames_ <= 0 || capacityFrames_ > kMaxCapacityFrames) {
        throw std::invalid_argument("invalid_capacity_frames");
    }
    if ((capacityFrames_ & (capacityFrames_ - 1)) != 0) {
        throw std::invalid_argument("capacity_frames_not_power_of_two");
    }

    indexMask_ = static_cast<uint32_t>(capacityFrames_ - 1);
    storage_.assign(static_cast<size_t>(capacityFrames_) * static_cast<size_t>(channelCount_), 0);
}

int64_t AudioSpscAudioRingBuffer::tryPushFrames(const int16_t* pcm, int64_t frames) noexcept {
    if (pcm == nullptr || frames <= 0) {
        return 0;
    }

    const uint32_t writeIdx = writeIndex_.load(std::memory_order_relaxed);
    const uint32_t readIdx  = readIndex_.load(std::memory_order_acquire);
    const uint32_t used     = writeIdx - readIdx; // wrap-safe unsigned subtraction
    const uint32_t free     = static_cast<uint32_t>(capacityFrames_) - used;

    int64_t acceptable = frames;
    if (static_cast<uint64_t>(acceptable) > static_cast<uint64_t>(free)) {
        acceptable = static_cast<int64_t>(free);
    }
    if (acceptable < frames) {
        overrunEvents_.fetch_add(1, std::memory_order_relaxed);
        framesRejected_.fetch_add(static_cast<uint64_t>(frames - acceptable), std::memory_order_relaxed);
    }
    if (acceptable <= 0) {
        return 0;
    }

    for (int64_t f = 0; f < acceptable; ++f) {
        const uint32_t slot = (writeIdx + static_cast<uint32_t>(f)) & indexMask_;
        for (int32_t ch = 0; ch < channelCount_; ++ch) {
            storage_[static_cast<size_t>(slot) * static_cast<size_t>(channelCount_) + static_cast<size_t>(ch)] =
                pcm[f * channelCount_ + ch];
        }
    }

    writeIndex_.store(writeIdx + static_cast<uint32_t>(acceptable), std::memory_order_release);
    return acceptable;
}

int64_t AudioSpscAudioRingBuffer::tryPopFrames(int16_t* out, int64_t frames) noexcept {
    if (out == nullptr || frames <= 0) {
        return 0;
    }

    const uint32_t readIdx   = readIndex_.load(std::memory_order_relaxed);
    const uint32_t writeIdx  = writeIndex_.load(std::memory_order_acquire);
    const uint32_t available = writeIdx - readIdx; // wrap-safe unsigned subtraction

    int64_t poppable = frames;
    if (static_cast<uint64_t>(poppable) > static_cast<uint64_t>(available)) {
        poppable = static_cast<int64_t>(available);
    }
    if (poppable <= 0) {
        return 0;
    }

    for (int64_t f = 0; f < poppable; ++f) {
        const uint32_t slot = (readIdx + static_cast<uint32_t>(f)) & indexMask_;
        for (int32_t ch = 0; ch < channelCount_; ++ch) {
            out[f * channelCount_ + ch] =
                storage_[static_cast<size_t>(slot) * static_cast<size_t>(channelCount_) + static_cast<size_t>(ch)];
        }
    }

    readIndex_.store(readIdx + static_cast<uint32_t>(poppable), std::memory_order_release);
    return poppable;
}

int64_t AudioSpscAudioRingBuffer::discardFrames(int64_t frames) noexcept {
    if (frames <= 0) {
        return 0;
    }

    const uint32_t readIdx   = readIndex_.load(std::memory_order_relaxed);
    const uint32_t writeIdx  = writeIndex_.load(std::memory_order_acquire);
    const uint32_t available = writeIdx - readIdx;

    int64_t discardable = frames;
    if (static_cast<uint64_t>(discardable) > static_cast<uint64_t>(available)) {
        discardable = static_cast<int64_t>(available);
    }
    if (discardable <= 0) {
        return 0;
    }

    readIndex_.store(readIdx + static_cast<uint32_t>(discardable), std::memory_order_release);
    return discardable;
}

void AudioSpscAudioRingBuffer::discardAllOnReaderThread() noexcept {
    const uint32_t writeIdx = writeIndex_.load(std::memory_order_acquire);
    readIndex_.store(writeIdx, std::memory_order_release);
}

bool AudioSpscAudioRingBuffer::requestSeek(int64_t newStartFrame) noexcept {
    if (newStartFrame < 0) {
        return false;
    }

    const uint64_t target = static_cast<uint64_t>(newStartFrame);
    seekTargetLow_.store(static_cast<uint32_t>(target & 0xFFFFFFFFu), std::memory_order_relaxed);
    seekTargetHigh_.store(static_cast<uint32_t>((target >> 32) & 0xFFFFFFFFu), std::memory_order_relaxed);
    flushRequest_.fetch_add(1, std::memory_order_release);
    return true;
}

bool AudioSpscAudioRingBuffer::consumePendingSeekOnReaderThread(int64_t* outNewStartFrame) noexcept {
    const uint32_t request = flushRequest_.load(std::memory_order_acquire);
    if (request == lastConsumedSeekRequest_) {
        return false;
    }

    const uint32_t low    = seekTargetLow_.load(std::memory_order_relaxed);
    const uint32_t high   = seekTargetHigh_.load(std::memory_order_relaxed);
    const uint64_t target = (static_cast<uint64_t>(high) << 32) | static_cast<uint64_t>(low);

    discardAllOnReaderThread();
    lastConsumedSeekRequest_ = request;
    flushAck_.store(request, std::memory_order_release);

    if (outNewStartFrame != nullptr) {
        *outNewStartFrame = static_cast<int64_t>(target);
    }
    return true;
}

int64_t AudioSpscAudioRingBuffer::availableReadFrames() const noexcept {
    const uint32_t writeIdx = writeIndex_.load(std::memory_order_acquire);
    const uint32_t readIdx  = readIndex_.load(std::memory_order_acquire);
    return static_cast<int64_t>(writeIdx - readIdx);
}

int64_t AudioSpscAudioRingBuffer::availableWriteFrames() const noexcept {
    return capacityFrames_ - availableReadFrames();
}

} // namespace audio
} // namespace vanguard
