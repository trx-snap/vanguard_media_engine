#pragma once
#include "vanguard/audio/audio_ring_buffer.h"
#include "vanguard/audio/audio_sample_provider.h"
#include "vanguard/core/status.h"
#include <cstdint>

namespace vanguard {
namespace audio {

// P4-AUDIO-GRAPH-TRANSPORT-CLOCK sub-slice B: diagnostic-only,
// stateful/sequential AudioSampleProvider adapter over a single
// AudioSpscAudioRingBuffer.
//
// Unlike VectorAudioSampleProvider, this provider is destructive FIFO, not
// replayable: repeated calls to provide() must ask for a monotonically
// non-decreasing `request.startFrame`. A rewind (request.startFrame less
// than this reader's own expected next frame) fails closed with a non-ok
// Status and leaves the reader cursor untouched; the only supported way to
// reposition is the ring buffer's explicit seek-epoch handshake
// (AudioSpscAudioRingBuffer::requestSeek /
// consumePendingSeekOnReaderThread), which this adapter checks at the top
// of every provide() call. This adapter holds a non-owning
// AudioSpscAudioRingBuffer* and must be used from the ring's single
// consumer thread only; it is not a production/realtime provider.
class RingBufferAudioSampleProvider : public AudioSampleProvider {
public:
    // `ring` must outlive this provider and must not be null.
    // `startFrame` seeds this reader's initial expected next frame.
    RingBufferAudioSampleProvider(AudioSpscAudioRingBuffer* ring, int64_t startFrame);

    int32_t sampleRate()   const override { return sampleRate_; }
    int32_t channelCount() const override { return channelCount_; }

    core::Status provide(const AudioWindowRequest& request,
                         AudioWindowBuffer& outBuffer) noexcept override;

    // Diagnostics (test/JNI visible only; no production semantics).
    int64_t  expectedNextFrame() const { return expectedNextFrame_; }
    uint64_t underrunEvents()    const { return underrunEvents_; }
    uint64_t framesZeroFilled()  const { return framesZeroFilled_; }
    uint64_t forwardSkipFrames() const { return forwardSkipFrames_; }
    uint64_t rewindRejects()     const { return rewindRejects_; }

private:
    AudioSpscAudioRingBuffer* ring_;
    int32_t sampleRate_;
    int32_t channelCount_;
    int64_t expectedNextFrame_;

    uint64_t underrunEvents_{0};
    uint64_t framesZeroFilled_{0};
    uint64_t forwardSkipFrames_{0};
    uint64_t rewindRejects_{0};
};

} // namespace audio
} // namespace vanguard
