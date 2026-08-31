#include "vanguard/audio/audio_clock.h"

#include <cstdlib>
#include <limits>

#if defined(__SIZEOF_INT128__)
#define VANGUARD_AUDIO_CLOCK_HAS_INT128 1
#else
#define VANGUARD_AUDIO_CLOCK_HAS_INT128 0
#endif

namespace vanguard {
namespace audio {

namespace {

constexpr int32_t kMinSpeedTerm = 1;
constexpr int32_t kMaxSpeedTerm = 1000;
constexpr int kMaxSeqlockReadAttempts = 8;

int32_t GcdInt32(int32_t a, int32_t b) {
    while (b != 0) {
        const int32_t t = b;
        b = a % b;
        a = t;
    }
    return a;
}

} // namespace

AudioClock::AudioClock() = default;

void AudioClock::beginWrite() noexcept {
    // Publish an odd sequence before touching any field so concurrent
    // readers observing the odd value know to retry.
    sequence_.fetch_add(1, std::memory_order_release);
}

void AudioClock::endWrite() noexcept {
    // Publish an even sequence after all field writes are visible.
    sequence_.fetch_add(1, std::memory_order_release);
}

AudioClock::CoreFields AudioClock::readCoreFieldsForWriter() const noexcept {
    // Writer-thread-only: the single control thread never races itself, so
    // a plain relaxed read of the last-published values is consistent.
    CoreFields out{};
    out.state = static_cast<State>(state_.load(std::memory_order_relaxed));
    out.anchorSystemTimeNs = anchorSystemTimeNs_.load(std::memory_order_relaxed);
    out.anchorMediaPtsUs = anchorMediaPtsUs_.load(std::memory_order_relaxed);
    out.speedNumerator = speedNumerator_.load(std::memory_order_relaxed);
    out.speedDenominator = speedDenominator_.load(std::memory_order_relaxed);
    return out;
}

AudioClock::CoreFields AudioClock::readCoreFieldsSeqlocked() const noexcept {
    CoreFields out{};
    for (int attempt = 0; attempt < kMaxSeqlockReadAttempts; ++attempt) {
        const uint64_t seqBefore = sequence_.load(std::memory_order_acquire);
        if ((seqBefore & 1u) != 0u) {
            continue; // Writer in progress; bounded retry.
        }
        out.state = static_cast<State>(state_.load(std::memory_order_relaxed));
        out.anchorSystemTimeNs = anchorSystemTimeNs_.load(std::memory_order_relaxed);
        out.anchorMediaPtsUs = anchorMediaPtsUs_.load(std::memory_order_relaxed);
        out.speedNumerator = speedNumerator_.load(std::memory_order_relaxed);
        out.speedDenominator = speedDenominator_.load(std::memory_order_relaxed);
        const uint64_t seqAfter = sequence_.load(std::memory_order_acquire);
        if (seqBefore == seqAfter) {
            return out;
        }
    }
    // Bounded fallback: single-writer contract makes sustained contention
    // across kMaxSeqlockReadAttempts unreachable in practice; take one
    // final unguarded read rather than looping unboundedly.
    out.state = static_cast<State>(state_.load(std::memory_order_relaxed));
    out.anchorSystemTimeNs = anchorSystemTimeNs_.load(std::memory_order_relaxed);
    out.anchorMediaPtsUs = anchorMediaPtsUs_.load(std::memory_order_relaxed);
    out.speedNumerator = speedNumerator_.load(std::memory_order_relaxed);
    out.speedDenominator = speedDenominator_.load(std::memory_order_relaxed);
    return out;
}

AudioClock::Snapshot AudioClock::readSnapshotSeqlocked() const noexcept {
    Snapshot out{};
    for (int attempt = 0; attempt < kMaxSeqlockReadAttempts; ++attempt) {
        const uint64_t seqBefore = sequence_.load(std::memory_order_acquire);
        if ((seqBefore & 1u) != 0u) {
            continue;
        }
        out.state = static_cast<State>(state_.load(std::memory_order_relaxed));
        out.anchorSystemTimeNs = anchorSystemTimeNs_.load(std::memory_order_relaxed);
        out.anchorMediaPtsUs = anchorMediaPtsUs_.load(std::memory_order_relaxed);
        out.speedNumerator = speedNumerator_.load(std::memory_order_relaxed);
        out.speedDenominator = speedDenominator_.load(std::memory_order_relaxed);
        out.driftSampleCount = driftSampleCount_.load(std::memory_order_relaxed);
        out.lastDriftExpectedPtsUs = lastDriftExpectedPtsUs_.load(std::memory_order_relaxed);
        out.lastDriftReportedPtsUs = lastDriftReportedPtsUs_.load(std::memory_order_relaxed);
        out.lastDriftDeltaUs = lastDriftDeltaUs_.load(std::memory_order_relaxed);
        const uint64_t seqAfter = sequence_.load(std::memory_order_acquire);
        if (seqBefore == seqAfter) {
            return out;
        }
    }
    out.state = static_cast<State>(state_.load(std::memory_order_relaxed));
    out.anchorSystemTimeNs = anchorSystemTimeNs_.load(std::memory_order_relaxed);
    out.anchorMediaPtsUs = anchorMediaPtsUs_.load(std::memory_order_relaxed);
    out.speedNumerator = speedNumerator_.load(std::memory_order_relaxed);
    out.speedDenominator = speedDenominator_.load(std::memory_order_relaxed);
    out.driftSampleCount = driftSampleCount_.load(std::memory_order_relaxed);
    out.lastDriftExpectedPtsUs = lastDriftExpectedPtsUs_.load(std::memory_order_relaxed);
    out.lastDriftReportedPtsUs = lastDriftReportedPtsUs_.load(std::memory_order_relaxed);
    out.lastDriftDeltaUs = lastDriftDeltaUs_.load(std::memory_order_relaxed);
    return out;
}

int64_t AudioClock::SaturatingAddNonNegative(int64_t a, int64_t b) noexcept {
    // Both inputs are always >= 0 at call sites (anchor pts and a
    // non-negative scaled elapsed duration), so only positive overflow is
    // possible.
    if (a > std::numeric_limits<int64_t>::max() - b) {
        return std::numeric_limits<int64_t>::max();
    }
    return a + b;
}

int64_t AudioClock::PositionFromCore(const CoreFields& core, int64_t sysTimeNs) noexcept {
    int64_t positionUs = 0;
    if (core.state == State::kPlaying) {
        int64_t deltaNs = sysTimeNs - core.anchorSystemTimeNs;
        if (deltaNs < 0) {
            deltaNs = 0;
        }
        const int64_t elapsedUs =
            ScaleNanosToMicros(deltaNs, core.speedNumerator, core.speedDenominator);
        positionUs = SaturatingAddNonNegative(core.anchorMediaPtsUs, elapsedUs);
    } else if (core.state == State::kPaused) {
        positionUs = core.anchorMediaPtsUs;
    }
    // kStopped falls through with positionUs == 0.
    // Defensive floor: every caller-observable position is guaranteed
    // nonnegative regardless of state or anchor provenance.
    return positionUs < 0 ? 0 : positionUs;
}

int64_t AudioClock::SaturatingSubtract(int64_t a, int64_t b) noexcept {
#if VANGUARD_AUDIO_CLOCK_HAS_INT128
    const __int128 result = static_cast<__int128>(a) - static_cast<__int128>(b);
    if (result > static_cast<__int128>(std::numeric_limits<int64_t>::max())) {
        return std::numeric_limits<int64_t>::max();
    }
    if (result < static_cast<__int128>(std::numeric_limits<int64_t>::min())) {
        return std::numeric_limits<int64_t>::min();
    }
    return static_cast<int64_t>(result);
#else
    // Widen through the unsigned domain (wraparound there is well-defined),
    // then detect signed over/underflow via the standard sign-bit idiom:
    // a - b overflows iff the operands' signs differ and the result's sign
    // differs from a's sign.
    const auto ua = static_cast<uint64_t>(a);
    const auto ub = static_cast<uint64_t>(b);
    const uint64_t rawResult = ua - ub;
    const auto result = static_cast<int64_t>(rawResult);
    const bool operandsSignsDiffer = ((ua ^ ub) >> 63) != 0;
    const bool resultSignDiffersFromA = ((ua ^ rawResult) >> 63) != 0;
    if (operandsSignsDiffer && resultSignDiffersFromA) {
        return (a < 0) ? std::numeric_limits<int64_t>::min() : std::numeric_limits<int64_t>::max();
    }
    return result;
#endif
}

int64_t AudioClock::ScaleNanosToMicros(int64_t deltaNs, int32_t numerator,
                                        int32_t denominator) noexcept {
    if (deltaNs <= 0 || numerator <= 0 || denominator <= 0) {
        return 0;
    }

#if VANGUARD_AUDIO_CLOCK_HAS_INT128
    const __int128 product = static_cast<__int128>(deltaNs) * static_cast<__int128>(numerator);
    const __int128 divisor = static_cast<__int128>(denominator) * static_cast<__int128>(1000);
    const __int128 result = product / divisor;
    if (result > static_cast<__int128>(std::numeric_limits<int64_t>::max())) {
        return std::numeric_limits<int64_t>::max();
    }
    return static_cast<int64_t>(result);
#else
    // Quotient/remainder decomposition bounds every intermediate multiply
    // well within int64 range without ever forming the full-width product.
    const int64_t divisor = static_cast<int64_t>(denominator) * 1000;
    const int64_t q = deltaNs / divisor;
    const int64_t r = deltaNs % divisor; // 0 <= r < divisor <= 1,000,000

    if (q > (std::numeric_limits<int64_t>::max() / numerator)) {
        return std::numeric_limits<int64_t>::max();
    }
    const int64_t qPart = q * numerator;
    const int64_t rPart = (r * numerator) / divisor; // r*numerator <= 1e9, safe.

    if (qPart > std::numeric_limits<int64_t>::max() - rPart) {
        return std::numeric_limits<int64_t>::max();
    }
    return qPart + rPart;
#endif
}

bool AudioClock::atomicSequenceLockFree() noexcept {
    return std::atomic<uint64_t>::is_always_lock_free;
}

core::Status AudioClock::start(int64_t sysTimeNs, int64_t mediaPtsUs) noexcept {
    const CoreFields current = readCoreFieldsForWriter();
    if (current.state != State::kStopped) {
        return core::Status(core::StatusCode::kError, "start: not stopped");
    }
    if (mediaPtsUs < 0) {
        return core::Status(core::StatusCode::kError, "start: negative mediaPtsUs");
    }

    beginWrite();
    state_.store(static_cast<int32_t>(State::kPlaying), std::memory_order_relaxed);
    anchorSystemTimeNs_.store(sysTimeNs, std::memory_order_relaxed);
    anchorMediaPtsUs_.store(mediaPtsUs, std::memory_order_relaxed);
    speedNumerator_.store(1, std::memory_order_relaxed);
    speedDenominator_.store(1, std::memory_order_relaxed);
    endWrite();
    return core::Status::OK();
}

core::Status AudioClock::pause(int64_t sysTimeNs) noexcept {
    const CoreFields current = readCoreFieldsForWriter();
    if (current.state == State::kPaused) {
        return core::Status::OK(); // No-op success.
    }
    if (current.state == State::kStopped) {
        return core::Status(core::StatusCode::kError, "pause: not active");
    }

    if (sysTimeNs < current.anchorSystemTimeNs) {
        return core::Status(core::StatusCode::kError, "pause: sysTimeNs regressed");
    }

    const int64_t frozenPositionUs = PositionFromCore(current, sysTimeNs);

    beginWrite();
    state_.store(static_cast<int32_t>(State::kPaused), std::memory_order_relaxed);
    anchorSystemTimeNs_.store(sysTimeNs, std::memory_order_relaxed);
    anchorMediaPtsUs_.store(frozenPositionUs, std::memory_order_relaxed);
    endWrite();
    return core::Status::OK();
}

core::Status AudioClock::resume(int64_t sysTimeNs) noexcept {
    const CoreFields current = readCoreFieldsForWriter();
    if (current.state == State::kPlaying) {
        return core::Status::OK(); // No-op success.
    }
    if (current.state == State::kStopped) {
        return core::Status(core::StatusCode::kError, "resume: not started");
    }

    if (sysTimeNs < current.anchorSystemTimeNs) {
        return core::Status(core::StatusCode::kError, "resume: sysTimeNs regressed");
    }

    beginWrite();
    state_.store(static_cast<int32_t>(State::kPlaying), std::memory_order_relaxed);
    anchorSystemTimeNs_.store(sysTimeNs, std::memory_order_relaxed);
    // anchorMediaPtsUs_ unchanged: position was frozen while paused.
    endWrite();
    return core::Status::OK();
}

core::Status AudioClock::seek(int64_t targetPtsUs, int64_t sysTimeNs) noexcept {
    if (targetPtsUs < 0) {
        return core::Status(core::StatusCode::kError, "seek: negative target");
    }

    const CoreFields current = readCoreFieldsForWriter();
    if (current.state == State::kStopped) {
        return core::Status(core::StatusCode::kError, "seek: not started");
    }
    if (current.state == State::kPlaying && sysTimeNs < current.anchorSystemTimeNs) {
        return core::Status(core::StatusCode::kError, "seek: sysTimeNs regressed");
    }

    // seek() is the only operation permitted to move the media pts backward,
    // but it is not backward-only: any nonnegative target is accepted here,
    // whether ahead of or behind the position computed at sysTimeNs.
    beginWrite();
    anchorSystemTimeNs_.store(sysTimeNs, std::memory_order_relaxed);
    anchorMediaPtsUs_.store(targetPtsUs, std::memory_order_relaxed);
    // state_ unchanged: seek preserves kPlaying/kPaused.
    endWrite();
    return core::Status::OK();
}

core::Status AudioClock::setSpeed(int32_t numerator, int32_t denominator,
                                   int64_t sysTimeNs) noexcept {
    if (numerator < kMinSpeedTerm || numerator > kMaxSpeedTerm || denominator < kMinSpeedTerm ||
        denominator > kMaxSpeedTerm) {
        return core::Status(core::StatusCode::kError, "setSpeed: ratio out of range");
    }

    const int32_t g = GcdInt32(numerator, denominator);
    const int32_t normalizedNumerator = numerator / g;
    const int32_t normalizedDenominator = denominator / g;

    const CoreFields current = readCoreFieldsForWriter();

    if (current.state == State::kPlaying) {
        if (sysTimeNs < current.anchorSystemTimeNs) {
            return core::Status(core::StatusCode::kError, "setSpeed: sysTimeNs regressed");
        }
        const int64_t reanchoredPositionUs = PositionFromCore(current, sysTimeNs);

        beginWrite();
        anchorSystemTimeNs_.store(sysTimeNs, std::memory_order_relaxed);
        anchorMediaPtsUs_.store(reanchoredPositionUs, std::memory_order_relaxed);
        speedNumerator_.store(normalizedNumerator, std::memory_order_relaxed);
        speedDenominator_.store(normalizedDenominator, std::memory_order_relaxed);
        endWrite();
        return core::Status::OK();
    }

    beginWrite();
    speedNumerator_.store(normalizedNumerator, std::memory_order_relaxed);
    speedDenominator_.store(normalizedDenominator, std::memory_order_relaxed);
    endWrite();
    return core::Status::OK();
}

int64_t AudioClock::currentPositionUs(int64_t sysTimeNs) const noexcept {
    const CoreFields core = readCoreFieldsSeqlocked();
    return PositionFromCore(core, sysTimeNs);
}

core::Status AudioClock::recordDriftSample(int64_t expectedPtsUs, int64_t reportedPtsUs,
                                            int64_t /* sysTimeNs */) noexcept {
    const int64_t deltaUs = SaturatingSubtract(reportedPtsUs, expectedPtsUs);

    beginWrite();
    driftSampleCount_.fetch_add(1, std::memory_order_relaxed);
    lastDriftExpectedPtsUs_.store(expectedPtsUs, std::memory_order_relaxed);
    lastDriftReportedPtsUs_.store(reportedPtsUs, std::memory_order_relaxed);
    lastDriftDeltaUs_.store(deltaUs, std::memory_order_relaxed);
    endWrite();
    return core::Status::OK();
}

AudioClock::Snapshot AudioClock::snapshot() const noexcept {
    return readSnapshotSeqlocked();
}

} // namespace audio
} // namespace vanguard
