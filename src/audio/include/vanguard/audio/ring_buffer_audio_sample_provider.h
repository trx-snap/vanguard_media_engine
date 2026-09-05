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
// Status and leaves the reader cursor untouched. Repositioning is supported
// on exactly two narrow paths, both driven by the ring buffer's explicit
// seek-epoch handshake (AudioSpscAudioRingBuffer::requestSeek /
// consumePendingSeekOnReaderThread):
//   1. The in-band path: provide() checks the handshake at the top of every
//      call and, when it consumes a pending ack itself, adopts the ack frame
//      as the expected next frame.
//   2. The external path (P4-AUDIO-SEEK-PROVIDER-COORDINATOR-REANCHOR):
//      reanchorAfterExternalSeek(). When the SAME ring consumer thread has
//      already consumed this ring's seek ack for a target frame outside of
//      provide() (an owning transport worker that validates both tracks'
//      acks before letting its coordinator seek), provide() can never see
//      that ack and would otherwise keep expecting the pre-seek frame,
//      forward-skipping / zero-filling the first post-seek window. The
//      caller therefore tells the provider the already-acked target
//      explicitly. This is a cursor re-anchor only: it does not touch the
//      ring, does not consume or publish any handshake, and must be called
//      with the exact frame the consumed ack carried.
// This adapter holds a non-owning AudioSpscAudioRingBuffer* and must be
// used from the ring's single consumer thread only; it is not a
// production/realtime provider.
class RingBufferAudioSampleProvider : public AudioSampleProvider {
public:
    // `ring` must outlive this provider and must not be null.
    // `startFrame` seeds this reader's initial expected next frame.
    RingBufferAudioSampleProvider(AudioSpscAudioRingBuffer* ring, int64_t startFrame);

    int32_t sampleRate()   const override { return sampleRate_; }
    int32_t channelCount() const override { return channelCount_; }

    core::Status provide(const AudioWindowRequest& request,
                         AudioWindowBuffer& outBuffer) noexcept override;

    // External re-anchor (class comment, path 2). Ring consumer thread
    // only, after that thread consumed this ring's seek ack for exactly
    // `targetFrame`. No allocation, no lock, no ring mutation: sets only the
    // expected next frame and the two diagnostics below. A negative
    // `targetFrame` fails closed with a non-ok Status and changes nothing.
    core::Status reanchorAfterExternalSeek(int64_t targetFrame) noexcept;

    // Diagnostics (test/JNI visible only; no production semantics).
    int64_t  expectedNextFrame() const { return expectedNextFrame_; }
    uint64_t underrunEvents()    const { return underrunEvents_; }
    uint64_t framesZeroFilled()  const { return framesZeroFilled_; }
    uint64_t forwardSkipFrames() const { return forwardSkipFrames_; }
    uint64_t rewindRejects()     const { return rewindRejects_; }
    // Number of successful reanchorAfterExternalSeek() calls and the frame
    // the most recent one set (-1 until the first success).
    uint64_t externalReanchorCount()    const { return externalReanchorCount_; }
    int64_t  lastExternalReanchorFrame() const { return lastExternalReanchorFrame_; }

private:
    AudioSpscAudioRingBuffer* ring_;
    int32_t sampleRate_;
    int32_t channelCount_;
    int64_t expectedNextFrame_;

    uint64_t underrunEvents_{0};
    uint64_t framesZeroFilled_{0};
    uint64_t forwardSkipFrames_{0};
    uint64_t rewindRejects_{0};
    uint64_t externalReanchorCount_{0};
    int64_t  lastExternalReanchorFrame_{-1};
};

} // namespace audio
} // namespace vanguard
