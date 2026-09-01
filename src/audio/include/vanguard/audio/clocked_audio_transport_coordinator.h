#pragma once
#include "vanguard/audio/audio_clock.h"
#include "vanguard/audio/audio_ring_buffer.h"
#include "vanguard/audio/graph_audio_scheduler.h"
#include "vanguard/core/status.h"

#include <cstdint>
#include <vector>

namespace vanguard {
namespace audio {

// P4-AUDIO-GRAPH-TRANSPORT-CLOCK sub-slice D: single-threaded coordinator
// that drives a GraphAudioScheduler window-by-window off an AudioClock and
// pushes the rendered PCM16 into an output AudioSpscAudioRingBuffer.
//
// Non-claims: not a thread, not a callback, not an OS audio path (no
// AudioTrack/AAudio/OpenSL/Oboe), never reads a wall clock itself (every
// method takes an explicit caller-supplied sysTimeNs), performs no
// floating-point math, no resampling, and never seeks the underlying
// source ring(s) directly -- source repositioning is the scheduler's
// routed providers' concern. This coordinator holds non-owning references
// to an AudioClock, a GraphAudioScheduler, and an output
// AudioSpscAudioRingBuffer; all three must outlive it. It is the ring
// producer role only: it calls tryPushFrames()/requestSeek() but never
// consumePendingSeekOnReaderThread(), which belongs to the ring's reader
// thread.
class ClockedAudioTransportCoordinator {
public:
    enum class DispatchResult {
        kOk,                 // rendered and pushed a mixed window
        kSilence,             // rendered and pushed a silent window
        kNoFramesDue,         // clock position has not advanced past nextDispatchFrame; no mutation
        kBackpressure,        // output ring lacks capacity for the due window; clock/cursor unchanged
        kAwaitingSeekAck,     // outputRing.seekAck() != seekRequest(); no dispatch
        kNotStarted,          // AudioClock is kStopped
        kPaused,              // AudioClock is kPaused
        kNonMonotonicTime,    // caller supplied a sysTimeNs that regressed
        kNonUnitySpeed,       // AudioClock speed ratio is not 1/1
        kSchedulerError,      // GraphAudioScheduler::renderWindow() returned a non-ok/non-silence result
        kRingPushShortfall,   // tryPushFrames() copied fewer frames than preflight promised (terminal)
        kClockError,          // start/pause/resume/seek AudioClock call failed
        kInvalidConfiguration,// scheduler/ring sample rate or channel mismatch, or non-positive sizing
    };

    struct DispatchOutput {
        int64_t  framesDue{0};
        int64_t  framesRendered{0};
        int64_t  framesPushed{0};
        int64_t  nextDispatchFrame{0};
        uint64_t checksum{0};
        bool     silence{false};
        // P4-AUDIO-ASYNC-RUNTIME-QUEUE-MULTI-SOURCE-DYNAMIC-GAIN-ENVELOPE:
        // GraphAudioScheduler::SchedulerOutput envelope metrics propagated
        // verbatim from the dispatched window's renderWindow() call; all
        // zero/false when no envelope-bearing track was mixed (including
        // every unit-gain/no-envelope configuration).
        bool     envelopeApplied{false};
        double   minEffectiveGain{0.0};
        double   maxEffectiveGain{0.0};
        int64_t  envelopeEvaluations{0};
    };

    struct Snapshot {
        DispatchResult lastResult{DispatchResult::kNotStarted};
        int64_t  nextDispatchFrame{0};
        int64_t  lastMediaPositionUs{0};
        int64_t  totalFramesRendered{0};
        int64_t  totalFramesPushed{0};
        uint64_t dispatchCount{0};
        uint64_t okCount{0};
        uint64_t silenceCount{0};
        uint64_t backpressureCount{0};
        uint64_t schedulerErrorCount{0};
        bool     awaitingSeekAck{false};
        bool     terminal{false};
    };

    // `clock`, `scheduler`, and `outputRing` must outlive this coordinator.
    // Preallocates the render scratch window
    // (scheduler.maxFramesPerMix() * scheduler.channelCount() samples) once
    // here; dispatchUntil() never allocates. If scheduler.sampleRate() !=
    // outputRing.sampleRate(), or scheduler.channelCount() !=
    // outputRing.channelCount(), or maxFramesPerMix() <= 0, or
    // outputRing.capacityFrames() < maxFramesPerMix(), or the scratch
    // sample count (maxFramesPerMix() * channelCount()) would overflow
    // int64_t/size_t, the coordinator is permanently invalid, scratch_
    // stays empty, and every method returns kInvalidConfiguration / a
    // failing Status without touching `clock` or `outputRing`.
    ClockedAudioTransportCoordinator(AudioClock& clock,
                                      GraphAudioScheduler& scheduler,
                                      AudioSpscAudioRingBuffer& outputRing);

    ClockedAudioTransportCoordinator(const ClockedAudioTransportCoordinator&)            = delete;
    ClockedAudioTransportCoordinator& operator=(const ClockedAudioTransportCoordinator&) = delete;
    ClockedAudioTransportCoordinator(ClockedAudioTransportCoordinator&&)                 = delete;
    ClockedAudioTransportCoordinator& operator=(ClockedAudioTransportCoordinator&&)      = delete;

    // Starts the clock at (sysTimeNs, mediaPtsUs), then requests a seek on
    // the output ring to frameOfPositionUs(mediaPtsUs, sampleRate) and
    // parks the dispatch cursor there awaiting the ring's seek ack.
    core::Status start(int64_t mediaPtsUs, int64_t sysTimeNs) noexcept;

    core::Status pause(int64_t sysTimeNs) noexcept;
    core::Status resume(int64_t sysTimeNs) noexcept;

    // Seeks the clock to targetPtsUs, then requests a seek on the output
    // ring to frameOfPositionUs(targetPtsUs, sampleRate) and parks the
    // dispatch cursor there awaiting the ring's seek ack.
    core::Status seek(int64_t targetPtsUs, int64_t sysTimeNs) noexcept;

    // Renders and pushes at most one maxFramesPerMix() window of frames
    // due by sysTimeNs (per AudioClock::currentPositionUs). Never blocks,
    // never allocates. `outResult` is zero-initialized on entry regardless
    // of outcome.
    DispatchResult dispatchUntil(int64_t sysTimeNs, DispatchOutput* outResult) noexcept;

    Snapshot snapshot() const noexcept;

    // Converts a media position (microseconds) to a frame index at
    // `sampleRate`, via integer decomposition (whole seconds + remainder
    // microseconds) so no intermediate term needs double-width math.
    // Saturates to INT64_MAX rather than overflowing; a non-positive
    // mediaPtsUs or sampleRate yields 0.
    static int64_t frameOfPositionUs(int64_t mediaPtsUs, int32_t sampleRate) noexcept;

private:
    DispatchResult failClosed(DispatchResult result, DispatchOutput* outResult) const noexcept;

    AudioClock&               clock_;
    GraphAudioScheduler&       scheduler_;
    AudioSpscAudioRingBuffer&  ring_;

    bool    configOk_{false};
    int32_t sampleRate_{0};
    int32_t channelCount_{0};
    int64_t maxFramesPerMix_{0};

    std::vector<int16_t> scratch_;

    int64_t nextDispatchFrame_{0};
    int64_t lastDispatchSysTimeNs_{INT64_MIN};
    bool    terminal_{false};

    DispatchResult lastResult_{DispatchResult::kNotStarted};
    int64_t  lastMediaPositionUs_{0};
    int64_t  totalFramesRendered_{0};
    int64_t  totalFramesPushed_{0};
    uint64_t dispatchCount_{0};
    uint64_t okCount_{0};
    uint64_t silenceCount_{0};
    uint64_t backpressureCount_{0};
    uint64_t schedulerErrorCount_{0};
};

} // namespace audio
} // namespace vanguard
