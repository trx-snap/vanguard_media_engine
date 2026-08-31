#pragma once
#include <cstddef>
#include <cstdint>

namespace vanguard {
namespace audio {

// P4-AUDIO-MIXBUS-TIMELINE-OWNERSHIP: platform-neutral timeline gain
// envelope owned by the native audio graph. C++ parity port of the Kotlin
// AndroidAudioVolumeEnvelope normalisation/static-fade/evaluation rules
// (which themselves mirror the iOS VGAudioExportMuxer Phase 8.15A keyframe
// path), moved onto an integer-microsecond time axis:
//   - mixGain outside [0,1] resets to 1.0; keyframe gains are clamped to
//     [0,1] and then multiplied by mixGain.
//   - Keyframes outside [trackStartUs, trackEndUs] (inclusive) are
//     discarded.
//   - Keyframes are stably sorted by time ascending.
//   - Adjacent keyframes closer than 1 ms are merged keeping the later one.
//   - A silent start keyframe is synthesised at trackStartUs when the first
//     keyframe is later than trackStartUs + 1 ms.
//   - A terminal keyframe holding the last gain is synthesised at
//     trackEndUs when the last keyframe is earlier than trackEndUs - 1 ms.
//   - Evaluation holds the first gain before the first keyframe, holds the
//     last gain after the last keyframe, linearly interpolates between
//     keyframes, and holds the earlier gain across a sub-millisecond span
//     (defensive: the builders never emit sub-millisecond spans).
//   - The empty envelope evaluates to 0.0.
//
// Unlike the Kotlin `normalize` helper (which receives a pre-normalised
// mixGain from `forTrack`), every builder here normalises mixGain itself so
// the observable ForTrack-level behaviour matches Kotlin regardless of the
// entry point.
//
// The time axis is integer microseconds only; double is used solely for
// gain values and interpolation fractions. Fixed-capacity value type: no
// heap allocation in construction, evaluation, or the mix path. Only
// linear interpolation is supported; any other interpolation enum value is
// rejected explicitly at build time.
class AudioGainEnvelope {
public:
    enum class Interpolation : int32_t { kLinear = 0 };

    struct Keyframe {
        int64_t       timeUs{0};
        double        gain{0.0};
        Interpolation interpolation{Interpolation::kLinear};
    };

    enum class BuildResult {
        kOk,
        kTooManyKeyframes,
        kNonFiniteGain,
        kUnsupportedInterpolation,
        kInvalidRange,
        kNullOutput,
        kEmptyAfterNormalize,
    };

    static constexpr size_t  kMaxKeyframes    = 512;
    // Raw input cap leaves room for the synthesised head/tail keyframes.
    static constexpr size_t  kMaxRawKeyframes = kMaxKeyframes - 2;
    static constexpr int64_t kMergeEpsilonUs  = 1000;

    // Applies the keyframe normalisation rules above into *outEnvelope.
    // Fails before mutating *outEnvelope; kEmptyAfterNormalize when no
    // keyframe survives (the ForTrack caller falls back to the static
    // path, matching the Kotlin forTrack fall-through).
    static BuildResult Normalize(const Keyframe*   rawKeyframes,
                                 size_t            rawCount,
                                 int64_t           trackStartUs,
                                 int64_t           trackEndUs,
                                 double            mixGain,
                                 AudioGainEnvelope* outEnvelope) noexcept;

    // Static volume/fade path expressed as keyframes: ramp 0 -> v over the
    // fade-in, hold v, ramp v -> 0 over the fade-out, with
    // v = volume * normalizedMixGain. Fades are clamped to the track
    // duration and, when they overlap, scaled proportionally
    // (integer-microsecond floor division on the time axis). Kotlin parity:
    // `volume` is not clamped here, so an out-of-range volume produces an
    // out-of-range envelope gain that the mix bus rejects.
    static BuildResult FromStatic(double            volume,
                                  double            mixGain,
                                  int64_t           fadeInUs,
                                  int64_t           fadeOutUs,
                                  int64_t           trackStartUs,
                                  int64_t           trackEndUs,
                                  AudioGainEnvelope* outEnvelope) noexcept;

    // Kotlin forTrack parity: uses the keyframe path when raw keyframes
    // survive normalisation, otherwise falls back to the static
    // volume/fade path. Hard build failures (cap, non-finite, unsupported
    // interpolation, invalid range) propagate instead of falling back.
    static BuildResult ForTrack(const Keyframe*   rawKeyframes,
                                size_t            rawCount,
                                double            volume,
                                double            mixGain,
                                int64_t           fadeInUs,
                                int64_t           fadeOutUs,
                                int64_t           trackStartUs,
                                int64_t           trackEndUs,
                                AudioGainEnvelope* outEnvelope) noexcept;

    // Evaluates the linear gain at timeUs (see semantics above). O(n) scan.
    double evaluate(int64_t timeUs) const noexcept;

    // Cursor-assisted evaluation for per-frame monotonic time sweeps:
    // identical results to evaluate(), amortised O(1) when timeUs is
    // non-decreasing across calls sharing *ioCursor. The cursor never moves
    // backward; a non-monotonic timeUs is answered via a full scan without
    // touching the cursor. ioCursor == nullptr degrades to evaluate().
    // Callers own cursor lifetime; the envelope holds no evaluation state.
    double evaluateCursor(int64_t timeUs, size_t* ioCursor) const noexcept;

    size_t keyframeCount() const noexcept { return count_; }

    // Out-of-range index returns a static all-zero keyframe.
    const Keyframe& keyframeAt(size_t index) const noexcept;

    bool empty() const noexcept { return count_ == 0; }

private:
    double evaluateSegment(size_t index, int64_t timeUs) const noexcept;

    Keyframe kf_[kMaxKeyframes];
    size_t   count_{0};
};

} // namespace audio
} // namespace vanguard
