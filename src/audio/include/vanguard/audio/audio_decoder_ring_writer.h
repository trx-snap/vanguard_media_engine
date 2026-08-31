#pragma once
#include "vanguard/audio/audio_ring_buffer.h"

#include <cstdint>

namespace vanguard {
namespace audio {

// P4-AUDIO-GRAPH-TRANSPORT-CLOCK sub-slice E: standalone producer-side
// helper that hands decoded PCM16 frames to an AudioSpscAudioRingBuffer.
//
// Non-claims: not a decoder, not a thread, not an OS audio callback, spawns
// no threads, takes no locks, performs no file IO, does not touch
// MediaCodec/MediaExtractor/AudioTrack/AAudio/OpenSL/Oboe, does not read a
// wall clock, and never plays the ring's reader role -- this writer only
// ever calls tryPushFrames()/requestSeek() on the ring, never
// consumePendingSeekOnReaderThread(). Holds a non-owning raw pointer to an
// AudioSpscAudioRingBuffer that must outlive it. All metrics are
// producer-thread-private plain counters (no atomics); this class assumes
// a single caller thread drives it exclusively, matching the ring's
// producer-role contract.
class AudioDecoderRingWriter {
public:
    enum class Status {
        kOk,               // full write accepted
        kPartialWrite,     // 0 < accepted < frames
        kRingFull,         // 0 frames accepted; ring had no free space
        kFormatMismatch,   // sampleRate/channelCount != expected
        kInvalidArgument,  // null pcm, frames <= 0, or frames > kMaxWriteFrames
        kAlreadyEos,       // setEos() was already called
        kAwaitingSeekAck,  // ring->seekAck() != ring->seekRequest()
    };

    struct Metrics {
        uint64_t totalFramesWritten{0};
        uint64_t partialWriteEvents{0};
        uint64_t backpressureRejects{0};
        uint64_t formatMismatches{0};
        uint64_t invalidArgumentRejects{0};
        uint64_t awaitingSeekAckRejects{0};
        uint64_t eosEvents{0};
        uint64_t seekRequests{0};
    };

    static constexpr int64_t kMaxWriteFrames = 8192;

    // `ringBuffer` must be non-null and must outlive this writer.
    // expectedSampleRate/expectedChannelCount must be positive and must
    // match ringBuffer->sampleRate()/channelCount() exactly. Throws
    // std::invalid_argument with token "null_ring", "invalid_sample_rate",
    // "invalid_channel_count", or "format_mismatch" respectively.
    AudioDecoderRingWriter(AudioSpscAudioRingBuffer* ringBuffer,
                            int32_t expectedSampleRate,
                            int32_t expectedChannelCount);
    ~AudioDecoderRingWriter() = default;

    AudioDecoderRingWriter(const AudioDecoderRingWriter&)            = delete;
    AudioDecoderRingWriter& operator=(const AudioDecoderRingWriter&) = delete;
    AudioDecoderRingWriter(AudioDecoderRingWriter&&)                 = delete;
    AudioDecoderRingWriter& operator=(AudioDecoderRingWriter&&)      = delete;

    // Precedence, checked in this exact order:
    //   1. invalid argument (pcm == nullptr, frames <= 0, or
    //      frames > kMaxWriteFrames) -> kInvalidArgument
    //   2. sampleRate/channelCount mismatch -> kFormatMismatch
    //   3. already EOS -> kAlreadyEos
    //   4. awaiting seek ack (ring->seekAck() != ring->seekRequest())
    //      -> kAwaitingSeekAck
    //   5. otherwise push via ring->tryPushFrames().
    // `outFramesWritten`, when non-null, is always set: to the accepted
    // frame count on a push, or to 0 on any reject. Never blocks, never
    // allocates, never throws.
    Status write(const int16_t* pcm,
                 int64_t frames,
                 int32_t sampleRate,
                 int32_t channelCount,
                 int64_t* outFramesWritten) noexcept;

    // Marks local writer EOS. Idempotent: only the first call increments
    // eosEvents; subsequent calls are no-ops. Once set, write() returns
    // kAlreadyEos until the next successful requestSeek() clears it.
    void setEos() noexcept;

    // Rejects negative targetFrame with kInvalidArgument (no ring mutation,
    // no metric bump). Otherwise forwards to ring->requestSeek(), which
    // only publishes the request -- this call never consumes an ack.
    // On success: increments seekRequests, sets nextWriteFrame_ to
    // targetFrame, and clears local EOS.
    Status requestSeek(int64_t targetFrame) noexcept;

    bool isEos() const noexcept { return eos_; }
    int64_t nextWriteFrame() const noexcept { return nextWriteFrame_; }
    const Metrics& metrics() const noexcept { return metrics_; }
    int32_t expectedSampleRate() const noexcept { return expectedSampleRate_; }
    int32_t expectedChannelCount() const noexcept { return expectedChannelCount_; }

private:
    AudioSpscAudioRingBuffer* ring_;
    int32_t expectedSampleRate_;
    int32_t expectedChannelCount_;

    int64_t nextWriteFrame_{0};
    bool    eos_{false};

    Metrics metrics_;
};

} // namespace audio
} // namespace vanguard
