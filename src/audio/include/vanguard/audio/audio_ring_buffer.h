#pragma once
#include <atomic>
#include <cstdint>
#include <vector>

namespace vanguard {
namespace audio {

// P4-AUDIO-GRAPH-TRANSPORT-CLOCK sub-slice B: lock-free single-producer/
// single-consumer PCM16 ring-buffer transport primitive.
//
// Diagnostic-only: this is not a production or realtime audio path. It has
// no AudioTrack/AAudio/OpenSL/Oboe dependency, spawns no threads itself,
// and performs no file IO. Exactly one producer thread may call
// tryPushFrames()/requestSeek() and exactly one (possibly different)
// consumer thread may call tryPopFrames()/discardFrames()/
// discardAllOnReaderThread()/consumePendingSeekOnReaderThread(); mixing
// callers across those two roles is undefined. Storage is a single
// std::vector<int16_t> allocated once in the constructor at a fixed
// power-of-two frame capacity and never resized afterward. All indices are
// frame-granular; a push/pop/discard never splits a frame across its
// interleaved channel samples.
class AudioSpscAudioRingBuffer {
public:
    static constexpr int64_t kMaxCapacityFrames = 65536;

    AudioSpscAudioRingBuffer(int32_t sampleRate, int32_t channelCount, int64_t capacityFrames);
    ~AudioSpscAudioRingBuffer() = default;

    AudioSpscAudioRingBuffer(const AudioSpscAudioRingBuffer&)            = delete;
    AudioSpscAudioRingBuffer& operator=(const AudioSpscAudioRingBuffer&) = delete;
    AudioSpscAudioRingBuffer(AudioSpscAudioRingBuffer&&)                 = delete;
    AudioSpscAudioRingBuffer& operator=(AudioSpscAudioRingBuffer&&)      = delete;

    static_assert(std::atomic<uint32_t>::is_always_lock_free,
                  "AudioSpscAudioRingBuffer requires lock-free 32-bit atomics");

    int32_t sampleRate()   const { return sampleRate_; }
    int32_t channelCount() const { return channelCount_; }

    // Producer-thread-only. Never blocks, never allocates. Drop-newest /
    // fail-closed: if `frames` does not fully fit in the currently free
    // space, only the leading portion that fits is accepted (partial
    // accept is legal), unread data is never overwritten, and a request is
    // never split mid-frame. Returns the number of frames actually copied.
    int64_t tryPushFrames(const int16_t* pcm, int64_t frames) noexcept;

    // Consumer-thread-only. Never blocks, never allocates, never
    // zero-fills; returns the number of whole frames actually copied out.
    int64_t tryPopFrames(int16_t* out, int64_t frames) noexcept;

    // Consumer-thread-only. Discards up to `frames` unread frames without
    // copying them out. Returns the number of frames actually discarded.
    int64_t discardFrames(int64_t frames) noexcept;

    // Consumer-thread-only. Drains every currently unread frame by moving
    // readIndex_ up to a fresh writeIndex_ snapshot.
    void discardAllOnReaderThread() noexcept;

    // Seek-epoch handshake (diagnostic-only; no third-party flush). Rejects
    // negative frame targets and never touches readIndex_/writeIndex_
    // itself; the reader performs the actual drain.
    bool requestSeek(int64_t newStartFrame) noexcept;

    // Consumer-thread-only. If a seek request has not yet been observed by
    // this reader, drains all unread frames, records the new frame target
    // in `*outNewStartFrame`, publishes the ack, and returns true. Returns
    // false (leaving `*outNewStartFrame` untouched) when there is no new
    // pending request.
    bool consumePendingSeekOnReaderThread(int64_t* outNewStartFrame) noexcept;

    uint32_t seekRequest() const { return flushRequest_.load(std::memory_order_acquire); }
    uint32_t seekAck()     const { return flushAck_.load(std::memory_order_acquire); }

    int64_t capacityFrames()         const { return capacityFrames_; }
    int64_t capacitySamples()        const { return capacityFrames_ * static_cast<int64_t>(channelCount_); }
    int64_t storageCapacitySamples() const { return static_cast<int64_t>(storage_.capacity()); }
    int64_t availableReadFrames()    const noexcept;
    int64_t availableWriteFrames()   const noexcept;

    uint64_t overrunEvents()  const { return overrunEvents_.load(std::memory_order_relaxed); }
    uint64_t framesRejected() const { return framesRejected_.load(std::memory_order_relaxed); }

    static bool atomicIndicesLockFree() { return std::atomic<uint32_t>::is_always_lock_free; }

private:
    int32_t  sampleRate_;
    int32_t  channelCount_;
    int64_t  capacityFrames_;
    uint32_t indexMask_{0};

    std::vector<int16_t> storage_;

    alignas(64) std::atomic<uint32_t> writeIndex_{0};
    alignas(64) std::atomic<uint32_t> readIndex_{0};

    alignas(64) std::atomic<uint32_t> flushRequest_{0};
    std::atomic<uint32_t> flushAck_{0};
    std::atomic<uint32_t> seekTargetLow_{0};
    std::atomic<uint32_t> seekTargetHigh_{0};
    uint32_t lastConsumedSeekRequest_{0}; // reader-thread-private

    std::atomic<uint64_t> overrunEvents_{0};
    std::atomic<uint64_t> framesRejected_{0};
};

} // namespace audio
} // namespace vanguard
