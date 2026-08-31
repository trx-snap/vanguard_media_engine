#pragma once
#include "vanguard/core/status.h"
#include <cstdint>

namespace vanguard {
namespace audio {

// P4-AUDIO-GRAPH-TRANSPORT-CLOCK (sub-slice A): non-owning, non-realtime,
// synchronous pull-model audio window contracts. Frame cursor is
// authoritative; `timelinePtsUs` is derived by the caller only for
// graph/timeline gating and carries no independent authority over which
// frames are requested.
struct AudioWindowRequest {
    int64_t  startFrame{0};
    int64_t  frameCount{0};
    int32_t  sampleRate{0};
    int32_t  channelCount{0};
    uint64_t timelinePtsUs{0};
};

// Caller-owned output window. `pcm` must point to at least
// `capacitySamples` interleaved int16_t samples and must outlive the
// provide() call; implementations never retain the pointer.
struct AudioWindowBuffer {
    int16_t* pcm{nullptr};
    int64_t  capacitySamples{0};
    int64_t  framesWritten{0};
    bool     silent{false};
};

// Synchronous, non-realtime, non-owning PCM window provider contract.
//
// Non-claims: this is not realtime clock ownership. provide() is called
// synchronously on the caller's own thread; this base class itself uses no
// threads, file IO, or Android audio APIs (AudioTrack/AAudio/OpenSL/Oboe/
// MediaCodec/MediaExtractor). Implementations differ in their own
// contracts and must document which of these they are:
//   - Bounded, diagnostic-only, replayable implementations (see
//     VectorAudioSampleProvider) may allocate/retain state freely, since
//     they are not production/realtime and support rewind via provide().
//   - Diagnostic-only, stateful/sequential implementations backed by a
//     lock-free ring buffer (see RingBufferAudioSampleProvider) are
//     destructive FIFO: rewind via provide() fails closed, and
//     repositioning is only available through an explicit seek-epoch
//     handshake on the underlying ring buffer, not through provide()
//     itself.
// Any provide() implementation intended for a future realtime pull path
// must not block, must not allocate, and must not acquire a lock inside
// provide().
class AudioSampleProvider {
public:
    virtual ~AudioSampleProvider() = default;

    virtual int32_t sampleRate()   const = 0;
    virtual int32_t channelCount() const = 0;

    // Fills `outBuffer.pcm` with exactly `request.frameCount` frames (when
    // status is ok) starting at `request.startFrame` in this provider's own
    // frame-cursor space, and sets `outBuffer.framesWritten`/`silent`.
    // Never throws.
    virtual core::Status provide(const AudioWindowRequest& request,
                                 AudioWindowBuffer& outBuffer) noexcept = 0;
};

} // namespace audio
} // namespace vanguard
