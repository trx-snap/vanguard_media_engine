#pragma once
#include "vanguard/core/status.h"

#include <atomic>
#include <cstdint>

namespace vanguard {
namespace audio {

// P4-AUDIO-GRAPH-TRANSPORT-CLOCK sub-slice C: caller-clocked, lock-free
// monotonic media-position tracker.
//
// Non-claims: this is not an AudioTrack/AAudio/OpenSL/Oboe timebase, not a
// decoder or writer, and never reads a wall clock itself — every method
// takes the current system time in nanoseconds (`sysTimeNs`) as an explicit
// caller-injected argument. AudioClock owns no thread and spawns none.
//
// Concurrency contract: exactly one control thread may call the mutating
// methods (start/pause/resume/seek/setSpeed/recordDriftSample); they are
// not safe to call concurrently with each other. currentPositionUs() and
// snapshot() may be called concurrently from any number of other reader
// threads while the control thread mutates, via a seqlock built on
// `sequence_`: a bounded, non-blocking retry loop, never a mutex.
//
// Re-anchoring: state is always represented as an anchor (system time,
// media pts) pair plus a rational speed; currentPositionUs() extrapolates
// forward from the anchor for kPlaying and returns the frozen anchor pts
// directly for kPaused/kStopped. Every mutator that changes the anchor
// system time first requires `sysTimeNs >= anchorSystemTimeNs_` (the prior
// anchor), otherwise it fails closed with no mutation, preserving
// monotonic wall-clock usage even though AudioClock never reads the clock
// itself. seek() accepts any nonnegative target media pts, whether ahead of
// or behind the position computed at `sysTimeNs`: it is the only operation
// that may move the media pts backward (ordinary kPlaying extrapolation and
// every other mutator only ever hold or advance it), which is why it exists
// separately from the pause/resume/setSpeed re-anchoring methods.
class AudioClock {
public:
    enum class State { kStopped, kPlaying, kPaused };

    struct Snapshot {
        State state;
        int64_t anchorSystemTimeNs;
        int64_t anchorMediaPtsUs;
        int32_t speedNumerator;
        int32_t speedDenominator;
        uint64_t driftSampleCount;
        int64_t lastDriftExpectedPtsUs;
        int64_t lastDriftReportedPtsUs;
        int64_t lastDriftDeltaUs;
    };

    AudioClock();

    // Legal only from kStopped. Rejects a negative mediaPtsUs with no
    // mutation. Otherwise anchors at (sysTimeNs, mediaPtsUs) with unity
    // speed and transitions to kPlaying.
    core::Status start(int64_t sysTimeNs, int64_t mediaPtsUs) noexcept;

    // kPaused -> no-op success. kStopped -> error, no mutation. kPlaying ->
    // freezes the extrapolated position as the new anchor and transitions
    // to kPaused; fails closed with no mutation if sysTimeNs regresses
    // behind the current anchor.
    core::Status pause(int64_t sysTimeNs) noexcept;

    // kPlaying -> no-op success. kStopped -> error, no mutation. kPaused ->
    // re-anchors at sysTimeNs (position unchanged) and transitions to
    // kPlaying; fails closed with no mutation if sysTimeNs regresses
    // behind the current anchor.
    core::Status resume(int64_t sysTimeNs) noexcept;

    // Rejects a negative target outright. From kStopped, errors with no
    // mutation. From kPlaying or kPaused, accepts any nonnegative target
    // regardless of whether it is ahead of or behind the position computed
    // at sysTimeNs (seek is the only operation permitted to move media pts
    // backward); while kPlaying, still rejects a regressing sysTimeNs. On
    // success re-anchors at (sysTimeNs, targetPtsUs) without changing
    // state.
    core::Status seek(int64_t targetPtsUs, int64_t sysTimeNs) noexcept;

    // numerator/denominator must both be in [1,1000]; the stored ratio is
    // gcd-normalized. While kPlaying, first re-anchors the extrapolated
    // position at sysTimeNs (failing closed with no mutation if sysTimeNs
    // regresses behind the current anchor) before applying the new speed;
    // otherwise the ratio is updated in place.
    core::Status setSpeed(int32_t numerator, int32_t denominator, int64_t sysTimeNs) noexcept;

    // Never allocates, locks, logs, throws, or reads drift fields. kStopped
    // reads as 0; kPaused reads as the frozen anchor pts; kPlaying
    // extrapolates from the anchor via ScaleNanosToMicros. The result is
    // always clamped to >= 0 defensively, regardless of state.
    int64_t currentPositionUs(int64_t sysTimeNs) const noexcept;

    // Diagnostic-only: updates only the drift telemetry fields. Never
    // observed by currentPositionUs(). The stored delta is
    // reportedPtsUs - expectedPtsUs computed via saturating subtraction, so
    // extreme inputs saturate to INT64_MIN/INT64_MAX instead of invoking
    // signed-overflow undefined behavior.
    core::Status recordDriftSample(int64_t expectedPtsUs, int64_t reportedPtsUs,
                                    int64_t sysTimeNs) noexcept;

    Snapshot snapshot() const noexcept;

    // Computes floor(deltaNs * numerator / (denominator * 1000)) without
    // overflow UB, saturating to INT64_MAX; a non-positive input or an
    // invalid ratio yields 0.
    static int64_t ScaleNanosToMicros(int64_t deltaNs, int32_t numerator,
                                       int32_t denominator) noexcept;

    static bool atomicSequenceLockFree() noexcept;

private:
    struct CoreFields {
        State state;
        int64_t anchorSystemTimeNs;
        int64_t anchorMediaPtsUs;
        int32_t speedNumerator;
        int32_t speedDenominator;
    };

    CoreFields readCoreFieldsForWriter() const noexcept;
    CoreFields readCoreFieldsSeqlocked() const noexcept;
    Snapshot readSnapshotSeqlocked() const noexcept;

    void beginWrite() noexcept;
    void endWrite() noexcept;

    static int64_t PositionFromCore(const CoreFields& core, int64_t sysTimeNs) noexcept;
    static int64_t SaturatingAddNonNegative(int64_t a, int64_t b) noexcept;
    static int64_t SaturatingSubtract(int64_t a, int64_t b) noexcept;

    alignas(64) std::atomic<uint64_t> sequence_{0};
    static_assert(std::atomic<uint64_t>::is_always_lock_free,
                  "AudioClock requires lock-free 64-bit atomics for its seqlock");

    std::atomic<int32_t> state_{static_cast<int32_t>(State::kStopped)};
    std::atomic<int64_t> anchorSystemTimeNs_{0};
    std::atomic<int64_t> anchorMediaPtsUs_{0};
    std::atomic<int32_t> speedNumerator_{1};
    std::atomic<int32_t> speedDenominator_{1};

    std::atomic<uint64_t> driftSampleCount_{0};
    std::atomic<int64_t> lastDriftExpectedPtsUs_{0};
    std::atomic<int64_t> lastDriftReportedPtsUs_{0};
    std::atomic<int64_t> lastDriftDeltaUs_{0};
};

} // namespace audio
} // namespace vanguard
