#include "vanguard/audio/audio_gain_envelope.h"

#include <cmath>
#include <cstdint>

namespace vanguard {
namespace audio {

namespace {

// Kotlin parity (AndroidAudioVolumeEnvelope.normalizeMixGain): mixGain
// outside [0,1] resets to unity. Callers reject non-finite mixGain first.
double NormalizeMixGain(double mixGain) {
    return (mixGain < 0.0 || mixGain > 1.0) ? 1.0 : mixGain;
}

// floor((a * b) / d) for non-negative a/b and positive d without __int128
// (rejected by the armeabi-v7a NDK target) and without floating point on
// the time axis. The 128-bit product is formed from 32-bit limbs and
// divided by restoring long division; the caller's b < d precondition
// guarantees the quotient fits, but the helper still fails closed (returns
// false, *out untouched) if the quotient cannot be represented.
bool MulDivFloorNonNegative(int64_t a, int64_t b, int64_t d, int64_t* out) {
    if (a < 0 || b < 0 || d <= 0 || out == nullptr) {
        return false;
    }
    const uint64_t ua = static_cast<uint64_t>(a);
    const uint64_t ub = static_cast<uint64_t>(b);
    const uint64_t ud = static_cast<uint64_t>(d);
    const uint64_t aLo = ua & 0xffffffffULL;
    const uint64_t aHi = ua >> 32;
    const uint64_t bLo = ub & 0xffffffffULL;
    const uint64_t bHi = ub >> 32;
    // mid = aLo*bHi + carry cannot wrap: (2^32-1)^2 + (2^32-1) < 2^64.
    const uint64_t p0  = aLo * bLo;
    uint64_t       mid = aLo * bHi + (p0 >> 32);
    const uint64_t p2  = aHi * bLo;
    mid += p2;
    const uint64_t midCarry = (mid < p2) ? 1ULL : 0ULL;
    const uint64_t hi = aHi * bHi + (mid >> 32) + (midCarry << 32);
    const uint64_t lo = (mid << 32) | (p0 & 0xffffffffULL);
    if (hi >= ud) {
        return false; // quotient would not fit in 64 bits
    }
    // Restoring 128/64 division: hi < d keeps the invariant remainder < d,
    // so a shifted-out top bit (overflowBit) always means "subtract".
    uint64_t quotient  = 0;
    uint64_t remainder = hi;
    for (int bit = 63; bit >= 0; --bit) {
        const uint64_t overflowBit = remainder >> 63;
        remainder = (remainder << 1) | ((lo >> bit) & 1ULL);
        if (overflowBit != 0 || remainder >= ud) {
            remainder -= ud;
            quotient |= (1ULL << bit);
        }
    }
    if (quotient > static_cast<uint64_t>(INT64_MAX)) {
        return false;
    }
    *out = static_cast<int64_t>(quotient);
    return true;
}

} // namespace

AudioGainEnvelope::BuildResult AudioGainEnvelope::Normalize(
    const Keyframe*    rawKeyframes,
    size_t             rawCount,
    int64_t            trackStartUs,
    int64_t            trackEndUs,
    double             mixGain,
    AudioGainEnvelope* outEnvelope) noexcept {
    if (outEnvelope == nullptr) {
        return BuildResult::kNullOutput;
    }
    if (rawCount > kMaxRawKeyframes) {
        return BuildResult::kTooManyKeyframes;
    }
    if (rawCount > 0 && rawKeyframes == nullptr) {
        return BuildResult::kNullOutput;
    }
    if (trackStartUs < 0 || trackEndUs < 0 || trackEndUs < trackStartUs) {
        return BuildResult::kInvalidRange;
    }
    if (!std::isfinite(mixGain)) {
        return BuildResult::kNonFiniteGain;
    }
    for (size_t i = 0; i < rawCount; ++i) {
        if (!std::isfinite(rawKeyframes[i].gain)) {
            return BuildResult::kNonFiniteGain;
        }
        if (rawKeyframes[i].interpolation != Interpolation::kLinear) {
            return BuildResult::kUnsupportedInterpolation;
        }
    }
    const double gainScale = NormalizeMixGain(mixGain);

    // Fixed scratch: nothing below allocates and *outEnvelope stays
    // untouched until the final commit.
    Keyframe tmp[kMaxKeyframes];
    size_t   n = 0;

    // 1+2. Clamp gain to [0,1], apply mixGain, discard out-of-range
    // (range is inclusive at both track boundaries).
    for (size_t i = 0; i < rawCount; ++i) {
        const int64_t t = rawKeyframes[i].timeUs;
        if (t < trackStartUs || t > trackEndUs) {
            continue;
        }
        double g = rawKeyframes[i].gain;
        if (g < 0.0) {
            g = 0.0;
        } else if (g > 1.0) {
            g = 1.0;
        }
        tmp[n].timeUs        = t;
        tmp[n].gain          = g * gainScale;
        tmp[n].interpolation = Interpolation::kLinear;
        ++n;
    }
    if (n == 0) {
        return BuildResult::kEmptyAfterNormalize;
    }

    // 3. Stable insertion sort ascending by time (equal times keep input
    // order, matching Kotlin's sortedBy).
    for (size_t i = 1; i < n; ++i) {
        const Keyframe key = tmp[i];
        size_t         j   = i;
        while (j > 0 && tmp[j - 1].timeUs > key.timeUs) {
            tmp[j] = tmp[j - 1];
            --j;
        }
        tmp[j] = key;
    }

    // 4. Merge sub-millisecond neighbours keeping the later keyframe
    // (chained merges compare against the surviving keyframe, matching
    // Kotlin mergeSubMillisecond).
    size_t m = 0;
    for (size_t i = 0; i < n; ++i) {
        if (m > 0 && (tmp[i].timeUs - tmp[m - 1].timeUs) < kMergeEpsilonUs) {
            tmp[m - 1] = tmp[i];
        } else {
            tmp[m++] = tmp[i];
        }
    }
    n = m;

    // 5+6. Commit with the synthesised silent head / holding tail. Capacity
    // holds by construction: n <= kMaxRawKeyframes and at most two
    // synthesised keyframes are added.
    size_t outN = 0;
    if (tmp[0].timeUs > trackStartUs + kMergeEpsilonUs) {
        outEnvelope->kf_[outN++] = Keyframe{trackStartUs, 0.0, Interpolation::kLinear};
    }
    for (size_t i = 0; i < n; ++i) {
        outEnvelope->kf_[outN++] = tmp[i];
    }
    if (outEnvelope->kf_[outN - 1].timeUs < trackEndUs - kMergeEpsilonUs) {
        outEnvelope->kf_[outN] =
            Keyframe{trackEndUs, outEnvelope->kf_[outN - 1].gain, Interpolation::kLinear};
        ++outN;
    }
    outEnvelope->count_ = outN;
    return BuildResult::kOk;
}

AudioGainEnvelope::BuildResult AudioGainEnvelope::FromStatic(
    double             volume,
    double             mixGain,
    int64_t            fadeInUs,
    int64_t            fadeOutUs,
    int64_t            trackStartUs,
    int64_t            trackEndUs,
    AudioGainEnvelope* outEnvelope) noexcept {
    if (outEnvelope == nullptr) {
        return BuildResult::kNullOutput;
    }
    if (trackStartUs < 0 || trackEndUs < 0 || trackEndUs < trackStartUs) {
        return BuildResult::kInvalidRange;
    }
    if (!std::isfinite(volume) || !std::isfinite(mixGain)) {
        return BuildResult::kNonFiniteGain;
    }

    const int64_t durationUs = trackEndUs - trackStartUs;
    const double  effectiveVolume = volume * NormalizeMixGain(mixGain);

    int64_t fadeIn = fadeInUs < 0 ? 0 : fadeInUs;
    if (fadeIn > durationUs) {
        fadeIn = durationUs;
    }
    int64_t fadeOut = fadeOutUs < 0 ? 0 : fadeOutUs;
    if (fadeOut > durationUs) {
        fadeOut = durationUs;
    }
    if (fadeIn + fadeOut > durationUs && fadeIn + fadeOut > 0) {
        // Proportional overlap scaling on the integer time axis (floor
        // division; the limb-based multiply/divide avoids overflow —
        // double is never used for the time axis).
        const int64_t total = fadeIn + fadeOut;
        int64_t scaledFadeIn  = 0;
        int64_t scaledFadeOut = 0;
        if (!MulDivFloorNonNegative(fadeIn, durationUs, total, &scaledFadeIn) ||
            !MulDivFloorNonNegative(fadeOut, durationUs, total, &scaledFadeOut)) {
            // Unreachable (durationUs < total bounds both quotients), but
            // fail closed rather than silently changing fade timing.
            return BuildResult::kInvalidRange;
        }
        fadeIn  = scaledFadeIn;
        fadeOut = scaledFadeOut;
    }

    // At most four keyframes before merging; already time-ascending because
    // fadeIn + fadeOut <= durationUs after clamping/scaling.
    Keyframe tmp[4];
    size_t   n = 0;
    if (fadeIn > 0) {
        tmp[n++] = Keyframe{trackStartUs, 0.0, Interpolation::kLinear};
        tmp[n++] = Keyframe{trackStartUs + fadeIn, effectiveVolume, Interpolation::kLinear};
    } else {
        tmp[n++] = Keyframe{trackStartUs, effectiveVolume, Interpolation::kLinear};
    }
    if (fadeOut > 0) {
        tmp[n++] = Keyframe{trackEndUs - fadeOut, effectiveVolume, Interpolation::kLinear};
        tmp[n++] = Keyframe{trackEndUs, 0.0, Interpolation::kLinear};
    } else {
        tmp[n++] = Keyframe{trackEndUs, effectiveVolume, Interpolation::kLinear};
    }

    // Merge sub-millisecond neighbours keeping the later keyframe.
    size_t m = 0;
    for (size_t i = 0; i < n; ++i) {
        if (m > 0 && (tmp[i].timeUs - tmp[m - 1].timeUs) < kMergeEpsilonUs) {
            tmp[m - 1] = tmp[i];
        } else {
            tmp[m++] = tmp[i];
        }
    }

    for (size_t i = 0; i < m; ++i) {
        outEnvelope->kf_[i] = tmp[i];
    }
    outEnvelope->count_ = m;
    return BuildResult::kOk;
}

AudioGainEnvelope::BuildResult AudioGainEnvelope::ForTrack(
    const Keyframe*    rawKeyframes,
    size_t             rawCount,
    double             volume,
    double             mixGain,
    int64_t            fadeInUs,
    int64_t            fadeOutUs,
    int64_t            trackStartUs,
    int64_t            trackEndUs,
    AudioGainEnvelope* outEnvelope) noexcept {
    if (rawCount > 0) {
        const BuildResult r = Normalize(
            rawKeyframes, rawCount, trackStartUs, trackEndUs, mixGain, outEnvelope);
        if (r != BuildResult::kEmptyAfterNormalize) {
            return r;
        }
        // All keyframes discarded — Kotlin forTrack falls through to the
        // static path.
    }
    return FromStatic(
        volume, mixGain, fadeInUs, fadeOutUs, trackStartUs, trackEndUs, outEnvelope);
}

double AudioGainEnvelope::evaluateSegment(size_t index, int64_t timeUs) const noexcept {
    const int64_t span = kf_[index + 1].timeUs - kf_[index].timeUs;
    if (span < kMergeEpsilonUs) {
        // Sub-millisecond span holds the earlier gain (defensive: the
        // builders never emit such spans).
        return kf_[index].gain;
    }
    const double fraction =
        static_cast<double>(timeUs - kf_[index].timeUs) / static_cast<double>(span);
    return kf_[index].gain + (kf_[index + 1].gain - kf_[index].gain) * fraction;
}

double AudioGainEnvelope::evaluate(int64_t timeUs) const noexcept {
    if (count_ == 0) {
        return 0.0;
    }
    if (timeUs <= kf_[0].timeUs) {
        return kf_[0].gain;
    }
    if (timeUs >= kf_[count_ - 1].timeUs) {
        return kf_[count_ - 1].gain;
    }
    for (size_t i = 0; i + 1 < count_; ++i) {
        if (timeUs >= kf_[i].timeUs && timeUs < kf_[i + 1].timeUs) {
            return evaluateSegment(i, timeUs);
        }
    }
    return kf_[count_ - 1].gain;
}

double AudioGainEnvelope::evaluateCursor(int64_t timeUs, size_t* ioCursor) const noexcept {
    if (ioCursor == nullptr) {
        return evaluate(timeUs);
    }
    if (count_ == 0) {
        return 0.0;
    }
    size_t cursor = *ioCursor;
    if (cursor >= count_) {
        cursor = count_ - 1;
    }
    if (timeUs < kf_[cursor].timeUs) {
        // Non-monotonic caller time: answer correctly without moving the
        // cursor backward.
        *ioCursor = cursor;
        return evaluate(timeUs);
    }
    while (cursor + 1 < count_ && timeUs >= kf_[cursor + 1].timeUs) {
        ++cursor;
    }
    *ioCursor = cursor;
    if (timeUs <= kf_[0].timeUs) {
        return kf_[0].gain;
    }
    if (cursor + 1 >= count_) {
        return kf_[count_ - 1].gain;
    }
    return evaluateSegment(cursor, timeUs);
}

const AudioGainEnvelope::Keyframe& AudioGainEnvelope::keyframeAt(size_t index) const noexcept {
    static constexpr Keyframe kZero{};
    if (index >= count_) {
        return kZero;
    }
    return kf_[index];
}

} // namespace audio
} // namespace vanguard
