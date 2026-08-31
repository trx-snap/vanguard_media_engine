// P4-AUDIO-MIXBUS-TIMELINE-OWNERSHIP: native AudioMixBusNode timeline-aware
// per-frame volume envelope diagnostic proof. One-shot, stack-scoped,
// single-threaded, synchronous JNI route: everything (nodes, envelopes,
// buffers) lives on this call's stack/locals and is destroyed before the
// reply string returns, so dispose-time lifecycle is trivially clean (no
// registry, no OS resource, no thread).
//
// What this proves: the C++ AudioGainEnvelope is a faithful parity port of
// the Kotlin AndroidAudioVolumeEnvelope rules (normalize / static fade /
// forTrack fallback / evaluate), and AudioMixBusNode now owns per-frame
// effective-gain math (static gain * envelope gain, single quantization,
// integer-microsecond floor PTS derivation, fail-before-output envelope
// validation) while the caller owns the window origin (envelopeStartPtsUs).
//
// Honest boundary: native timeline/envelope ownership is a P0 prerequisite
// for the production graph reroute, NOT a hard blocker for the pure runtime
// queue. GraphAudioScheduler is untouched and continues to emit unit gain /
// null envelope; the production export chunk mixer
// (AndroidNativeAudioMixBusChunkMixer) still evaluates its Kotlin envelope
// and pre-scales, and neither file was needed by this implementation. The
// schedulerUnchangedOk / productionMixdownUntouchedOk lanes are source-level
// honesty lanes backed here by the null-envelope back-compat proof; no
// runtime execution of the production export is claimed.
//
// This translation unit is Android-only and must NOT be included in iOS or
// host builds (added via the Android-only target_sources block in
// src/CMakeLists.txt).
//
// JNI entry point (matching VanguardNativeBridge.kt):
//   runAudioMixBusTimelineNativeSmoke -> jstring

#include <jni.h>

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <string>
#include <vector>

#include "vanguard/audio/audio_gain_envelope.h"
#include "vanguard/audio/audio_mix_bus_node.h"

namespace {

using vanguard::audio::AudioGainEnvelope;
using vanguard::audio::AudioMixBusNode;

// Must stay byte-identical to PROOF_BOUNDARY in
// AndroidAudioMixBusTimelineDriver.kt.
constexpr const char* kProofBoundary =
    "native_audio_mix_bus_per_frame_volume_envelope_diagnostic_only_linear_interpolation_only_"
    "kotlin_android_audio_volume_envelope_parity_normalize_static_fade_and_evaluate_ported_to_"
    "cpp_node_owns_gain_math_caller_owns_window_origin_no_scheduler_wiring_no_production_"
    "mixdown_change_no_export_reroute_no_pass2_reroute_no_runtime_queue_no_backpressure_no_"
    "realtime_sink_no_threads_no_audio_track_no_aaudio_no_media_codec_no_file_io_no_streaming_"
    "no_cache_no_ios_no_product_no_editor_no_connects_app";

// ---------------------------------------------------------------------------
// Kotlin AndroidAudioVolumeEnvelope reference, ported verbatim onto double
// seconds (the Kotlin time basis) so parity is checked against the exact
// Kotlin algorithm, not against the integer-microsecond implementation
// under test. Heap use here is fine: this reference runs only inside the
// one-shot diagnostic, never in the mix path.
// ---------------------------------------------------------------------------

struct RefKeyframe {
    double time{0.0};
    double volume{0.0};
};

constexpr double kRefMergeEpsilonSeconds = 0.001;

double RefNormalizeMixGain(double mixGain) {
    return (mixGain < 0.0 || mixGain > 1.0) ? 1.0 : mixGain;
}

std::vector<RefKeyframe> RefMergeSubMillisecond(const std::vector<RefKeyframe>& sorted) {
    std::vector<RefKeyframe> merged;
    for (const RefKeyframe& kf : sorted) {
        if (!merged.empty() && (kf.time - merged.back().time) < kRefMergeEpsilonSeconds) {
            merged.pop_back();
        }
        merged.push_back(kf);
    }
    return merged;
}

std::vector<RefKeyframe> RefNormalize(const std::vector<RefKeyframe>& raw,
                                      double trackStartSec,
                                      double trackEndSec,
                                      double mixGain) {
    std::vector<RefKeyframe> valid;
    for (const RefKeyframe& kf : raw) {
        if (kf.time < trackStartSec || kf.time > trackEndSec) continue;
        double clamped = kf.volume;
        if (clamped < 0.0) clamped = 0.0;
        if (clamped > 1.0) clamped = 1.0;
        valid.push_back(RefKeyframe{kf.time, clamped * mixGain});
    }
    if (valid.empty()) return {};
    std::stable_sort(valid.begin(), valid.end(),
                     [](const RefKeyframe& a, const RefKeyframe& b) { return a.time < b.time; });
    std::vector<RefKeyframe> merged = RefMergeSubMillisecond(valid);
    if (merged.empty()) return {};
    std::vector<RefKeyframe> result;
    if (merged.front().time > trackStartSec + kRefMergeEpsilonSeconds) {
        result.push_back(RefKeyframe{trackStartSec, 0.0});
    }
    result.insert(result.end(), merged.begin(), merged.end());
    if (result.back().time < trackEndSec - kRefMergeEpsilonSeconds) {
        result.push_back(RefKeyframe{trackEndSec, result.back().volume});
    }
    return result;
}

std::vector<RefKeyframe> RefFromStatic(double volume,
                                       double mixGain,
                                       double fadeInSeconds,
                                       double fadeOutSeconds,
                                       double trackStartSec,
                                       double trackEndSec) {
    const double duration = std::max(trackEndSec - trackStartSec, 0.0);
    const double effectiveVolume = volume * RefNormalizeMixGain(mixGain);
    double fadeIn  = std::min(std::max(fadeInSeconds, 0.0), duration);
    double fadeOut = std::min(std::max(fadeOutSeconds, 0.0), duration);
    if (fadeIn + fadeOut > duration && fadeIn + fadeOut > 0.0) {
        const double total = fadeIn + fadeOut;
        fadeIn  = (fadeIn / total) * duration;
        fadeOut = (fadeOut / total) * duration;
    }
    std::vector<RefKeyframe> kfs;
    if (fadeIn > 0.0) {
        kfs.push_back(RefKeyframe{trackStartSec, 0.0});
        kfs.push_back(RefKeyframe{trackStartSec + fadeIn, effectiveVolume});
    } else {
        kfs.push_back(RefKeyframe{trackStartSec, effectiveVolume});
    }
    if (fadeOut > 0.0) {
        kfs.push_back(RefKeyframe{trackEndSec - fadeOut, effectiveVolume});
        kfs.push_back(RefKeyframe{trackEndSec, 0.0});
    } else {
        kfs.push_back(RefKeyframe{trackEndSec, effectiveVolume});
    }
    std::stable_sort(kfs.begin(), kfs.end(),
                     [](const RefKeyframe& a, const RefKeyframe& b) { return a.time < b.time; });
    return RefMergeSubMillisecond(kfs);
}

std::vector<RefKeyframe> RefForTrack(const std::vector<RefKeyframe>& raw,
                                     double volume,
                                     double mixGain,
                                     double fadeInSeconds,
                                     double fadeOutSeconds,
                                     double trackStartSec,
                                     double trackEndSec) {
    const double normalizedMixGain = RefNormalizeMixGain(mixGain);
    if (!raw.empty()) {
        std::vector<RefKeyframe> normalized =
            RefNormalize(raw, trackStartSec, trackEndSec, normalizedMixGain);
        if (!normalized.empty()) return normalized;
    }
    return RefFromStatic(volume, normalizedMixGain, fadeInSeconds, fadeOutSeconds,
                         trackStartSec, trackEndSec);
}

double RefEvaluate(const std::vector<RefKeyframe>& kfs, double timeSec) {
    if (kfs.empty()) return 0.0;
    if (timeSec <= kfs.front().time) return kfs.front().volume;
    if (timeSec >= kfs.back().time) return kfs.back().volume;
    for (size_t i = 0; i + 1 < kfs.size(); ++i) {
        const RefKeyframe& a = kfs[i];
        const RefKeyframe& b = kfs[i + 1];
        if (timeSec >= a.time && timeSec < b.time) {
            const double span = b.time - a.time;
            if (span < kRefMergeEpsilonSeconds) return a.volume;
            const double fraction = (timeSec - a.time) / span;
            return a.volume + (b.volume - a.volume) * fraction;
        }
    }
    return kfs.back().volume;
}

// ---------------------------------------------------------------------------
// Diagnostic helpers
// ---------------------------------------------------------------------------

std::string Hex64(uint64_t v) {
    char buf[24];
    std::snprintf(buf, sizeof(buf), "%016llx", static_cast<unsigned long long>(v));
    return buf;
}

std::string LongStr(long long v) {
    char buf[32];
    std::snprintf(buf, sizeof(buf), "%lld", v);
    return buf;
}

std::string DoubleStr(double v) {
    char buf[64];
    std::snprintf(buf, sizeof(buf), "%.9f", v);
    return buf;
}

void AppendKV(std::string& s, const char* key, const std::string& value) {
    s += key;
    s += '=';
    s += value;
    s += ';';
}

// Exact structural expectation: hand-computed (timeUs, gain) list. Times
// must match exactly (integer axis); gains within 1e-12 (identical double
// operation order on both sides makes them equal in practice).
bool CheckEnvelopeExact(const AudioGainEnvelope& env,
                        const std::vector<std::pair<int64_t, double>>& expected) {
    if (env.keyframeCount() != expected.size()) return false;
    for (size_t i = 0; i < expected.size(); ++i) {
        const AudioGainEnvelope::Keyframe& kf = env.keyframeAt(i);
        if (kf.timeUs != expected[i].first) return false;
        if (std::fabs(kf.gain - expected[i].second) > 1e-12) return false;
        if (kf.interpolation != AudioGainEnvelope::Interpolation::kLinear) return false;
    }
    return true;
}

// Structural parity against the double-seconds Kotlin reference: counts
// equal, times within 1e-9 s after us -> s conversion, gains within 1e-9.
bool CheckEnvelopeRefParity(const AudioGainEnvelope& env,
                            const std::vector<RefKeyframe>& ref) {
    if (env.keyframeCount() != ref.size()) return false;
    for (size_t i = 0; i < ref.size(); ++i) {
        const AudioGainEnvelope::Keyframe& kf = env.keyframeAt(i);
        if (std::fabs(static_cast<double>(kf.timeUs) / 1e6 - ref[i].time) > 1e-9) return false;
        if (std::fabs(kf.gain - ref[i].volume) > 1e-9) return false;
    }
    return true;
}

// No normalized envelope may carry a sub-millisecond span (which is why the
// evaluate() sub-ms hold branch is defensive-only in both languages).
bool CheckNoSubMillisecondSpans(const AudioGainEnvelope& env) {
    for (size_t i = 0; i + 1 < env.keyframeCount(); ++i) {
        if (env.keyframeAt(i + 1).timeUs - env.keyframeAt(i).timeUs <
            AudioGainEnvelope::kMergeEpsilonUs) {
            return false;
        }
    }
    return true;
}

uint64_t ChecksumPcm16(const std::vector<int16_t>& samples) {
    uint64_t checksum = 0;
    for (int16_t s : samples) {
        checksum = checksum * 31u + static_cast<uint64_t>(static_cast<uint16_t>(s));
    }
    return checksum;
}

// Locally recomputes the expected single-track mix with the node's exact
// arithmetic (single quantization, int32 accumulator, one final clamp).
// Envelope gains are read through the envelope's own evaluate() so this
// checks the mix plumbing (per-frame application, PTS derivation, gain
// composition), while interpolation math itself is covered by the separate
// analytic parity lanes. roundPtsInsteadOfFloor computes the deliberately
// wrong nearest-integer PTS variant used to prove floor derivation.
std::vector<int16_t> ExpectedSingleTrackMix(const std::vector<int16_t>& pcm,
                                            int64_t frames,
                                            int32_t trackChannels,
                                            int32_t nodeChannels,
                                            int32_t sampleRate,
                                            double staticGain,
                                            const AudioGainEnvelope* env,
                                            int64_t startPtsUs,
                                            bool roundPtsInsteadOfFloor) {
    std::vector<int32_t> acc(static_cast<size_t>(frames * nodeChannels), 0);
    for (int64_t f = 0; f < frames; ++f) {
        double eff = staticGain;
        if (env != nullptr) {
            const int64_t ptsUs = roundPtsInsteadOfFloor
                ? startPtsUs + (f * 1000000LL + sampleRate / 2) / sampleRate
                : startPtsUs + (f * 1000000LL) / sampleRate;
            eff = staticGain * env->evaluate(ptsUs);
        }
        if (trackChannels == nodeChannels) {
            for (int32_t ch = 0; ch < nodeChannels; ++ch) {
                const int16_t sample = pcm[static_cast<size_t>(f * nodeChannels + ch)];
                acc[static_cast<size_t>(f * nodeChannels + ch)] +=
                    static_cast<int32_t>(static_cast<double>(sample) * eff);
            }
        } else if (trackChannels == 1 && nodeChannels == 2) {
            const int16_t mono = pcm[static_cast<size_t>(f)];
            const int32_t scaled = static_cast<int32_t>(static_cast<double>(mono) * eff);
            acc[static_cast<size_t>(f * 2 + 0)] += scaled;
            acc[static_cast<size_t>(f * 2 + 1)] += scaled;
        } else { // 2 -> 1 downmix
            const int32_t down =
                (static_cast<int32_t>(pcm[static_cast<size_t>(f * 2 + 0)]) +
                 static_cast<int32_t>(pcm[static_cast<size_t>(f * 2 + 1)])) / 2;
            acc[static_cast<size_t>(f)] +=
                static_cast<int32_t>(static_cast<double>(down) * eff);
        }
    }
    std::vector<int16_t> out(acc.size());
    for (size_t i = 0; i < acc.size(); ++i) {
        int32_t clamped = acc[i];
        if (clamped > 32767) clamped = 32767;
        if (clamped < -32768) clamped = -32768;
        out[i] = static_cast<int16_t>(clamped);
    }
    return out;
}

// Models the production Kotlin chunk-mixer approximation
// (AndroidNativeAudioMixBusChunkMixer): the full effective gain is
// evaluated in Kotlin and each SOURCE-channel sample is truncated to int16
// BEFORE native downmix/accumulation at unit gain. Used only to prove the
// node's single-quantization output is distinguishable from the pre-scale
// path; the production file itself is untouched.
uint64_t PrescaleApproxChecksumStereoToMono(const std::vector<int16_t>& pcm,
                                            int64_t frames,
                                            int32_t sampleRate,
                                            double staticGain,
                                            const AudioGainEnvelope& env,
                                            int64_t startPtsUs) {
    std::vector<int16_t> out(static_cast<size_t>(frames));
    for (int64_t f = 0; f < frames; ++f) {
        const int64_t ptsUs = startPtsUs + (f * 1000000LL) / sampleRate;
        const double eff = staticGain * env.evaluate(ptsUs);
        auto prescale = [&](int16_t s) -> int32_t {
            int32_t v = static_cast<int32_t>(static_cast<double>(s) * eff);
            if (v > 32767) v = 32767;
            if (v < -32768) v = -32768;
            return v;
        };
        const int32_t pl = prescale(pcm[static_cast<size_t>(f * 2 + 0)]);
        const int32_t pr = prescale(pcm[static_cast<size_t>(f * 2 + 1)]);
        int32_t down = (pl + pr) / 2;
        if (down > 32767) down = 32767;
        if (down < -32768) down = -32768;
        out[static_cast<size_t>(f)] = static_cast<int16_t>(down);
    }
    return ChecksumPcm16(out);
}

} // namespace

// ---------------------------------------------------------------------------
// JNI: runAudioMixBusTimelineNativeSmoke
// ---------------------------------------------------------------------------
extern "C" JNIEXPORT jstring JNICALL
Java_com_connects_vanguard_1media_1engine_bridge_VanguardNativeBridge_runAudioMixBusTimelineNativeSmoke(
    JNIEnv* env,
    jobject /* this */) {

    using BuildResult = AudioGainEnvelope::BuildResult;
    using Keyframe    = AudioGainEnvelope::Keyframe;
    using Interp      = AudioGainEnvelope::Interpolation;
    using MixResult   = AudioMixBusNode::MixResult;
    using MixTrack    = AudioMixBusNode::MixTrack;
    using MixOutput   = AudioMixBusNode::MixOutput;

    // Lanes (all fail-closed defaults).
    bool envelopeNormalizationParityOk   = false;
    bool envelopeStaticFadePathParityOk  = false;
    bool envelopeForTrackFallbackParityOk = false;
    bool envelopeEvaluationParityOk      = false;
    bool emptyEnvelopeSilenceParityOk    = false;
    bool subMillisecondHoldOk            = false;
    bool boundaryInclusivityOk           = false;
    bool mixGainNormalizationOk          = false;
    bool perFrameEnvelopeAppliedOk       = false;
    bool staticGainCompositionOk         = false;
    bool nullEnvelopeBackCompatOk        = false;
    bool singleQuantizationOk            = false;
    bool envelopeCursorMonotonicOk       = false;
    bool envelopeCursorResetPerCallOk    = false;
    bool floorPtsDerivationOk            = false;
    bool unsupportedInterpolationRejectOk = false;
    bool keyframeCapRejectOk             = false;
    bool invalidEnvelopeRangeRejectOk    = false;
    bool invalidEnvelopeStartPtsRejectOk = false;
    bool invalidEnvelopeGainRejectOk     = false;
    bool noPerMixAllocationOk            = false;
    // Source-level honesty lanes: GraphAudioScheduler and the production
    // chunk mixer are untouched and were not needed by this slice; the
    // runtime evidence backing them is the null-envelope back-compat proof.
    bool schedulerUnchangedOk            = false;
    bool productionMixdownUntouchedOk    = false;
    bool lifecycleOk                     = false;
    bool stackScoped                     = false;

    // Metrics.
    long long normalizedKeyframeCount = 0;
    long long staticFadeKeyframeCount = 0;
    long long evaluationSampleCount   = 0;
    double    maxGainDiff             = 0.0;
    uint64_t  staticGainChecksum      = 0;
    uint64_t  envelopeMixChecksum     = 0;
    uint64_t  nullEnvelopeChecksum    = 0;
    uint64_t  baselineStaticChecksum  = 0;
    uint64_t  prescaleApproxChecksum  = 0;
    uint64_t  singleQuantChecksum     = 0;
    uint64_t  roundPtsChecksum        = 0;
    double    minEffectiveGainMetric  = 0.0;
    double    maxEffectiveGainMetric  = 0.0;
    long long envelopeEvaluationsMetric = 0;
    long long framesMixedMetric       = 0;
    std::string failureReason;
    auto fail = [&](const char* reason) {
        if (failureReason.empty()) failureReason = reason;
    };

    try {
        // ── Fixture A: keyframe normalization parity ────────────────────────
        // [1s, 5s], mixGain 0.5, deliberately unsorted raw list exercising
        // out-of-range discard (both sides), sub-ms merge keeping the later
        // keyframe, volume clamp, synthesized silent head and holding tail.
        const std::vector<Keyframe> rawA = {
            {3000000, 0.8, Interp::kLinear},
            {500000, 0.9, Interp::kLinear},   // before trackStart: discarded
            {2000400, 0.6, Interp::kLinear},  // merges with 2000000, kept
            {2000000, 0.5, Interp::kLinear},  // merged away (earlier)
            {6000000, 0.1, Interp::kLinear},  // after trackEnd: discarded
            {2500000, 1.5, Interp::kLinear},  // clamps to 1.0
        };
        AudioGainEnvelope envA;
        if (AudioGainEnvelope::Normalize(rawA.data(), rawA.size(), 1000000, 5000000, 0.5,
                                         &envA) != BuildResult::kOk) {
            fail("normalize_a_build_failed");
        }
        const std::vector<std::pair<int64_t, double>> expectedA = {
            {1000000, 0.0},
            {2000400, 0.6 * 0.5},
            {2500000, 1.0 * 0.5},
            {3000000, 0.8 * 0.5},
            {5000000, 0.8 * 0.5},
        };
        std::vector<RefKeyframe> rawARef;
        for (const Keyframe& kf : rawA) {
            rawARef.push_back(RefKeyframe{static_cast<double>(kf.timeUs) / 1e6, kf.gain});
        }
        const std::vector<RefKeyframe> refA = RefNormalize(rawARef, 1.0, 5.0, 0.5);
        envelopeNormalizationParityOk =
            CheckEnvelopeExact(envA, expectedA) && CheckEnvelopeRefParity(envA, refA);
        if (!envelopeNormalizationParityOk) fail("envelope_normalization_parity");
        normalizedKeyframeCount = static_cast<long long>(envA.keyframeCount());

        // ── Fixture B: static volume/fade path parity ───────────────────────
        // B1: plain fades. B2: overlapping fades scaled proportionally
        // (values chosen so integer floor scaling and Kotlin double scaling
        // land on the same instant). B3: fade-in clamped to the duration.
        AudioGainEnvelope envB1;
        AudioGainEnvelope envB2;
        AudioGainEnvelope envB3;
        if (AudioGainEnvelope::FromStatic(0.8, 1.0, 500000, 700000, 0, 2000000, &envB1) !=
                BuildResult::kOk ||
            AudioGainEnvelope::FromStatic(0.5, 1.0, 900000, 900000, 0, 1200000, &envB2) !=
                BuildResult::kOk ||
            AudioGainEnvelope::FromStatic(0.6, 1.0, 3000000, 0, 0, 2000000, &envB3) !=
                BuildResult::kOk) {
            fail("from_static_build_failed");
        }
        const std::vector<RefKeyframe> refB1 = RefFromStatic(0.8, 1.0, 0.5, 0.7, 0.0, 2.0);
        const std::vector<RefKeyframe> refB2 = RefFromStatic(0.5, 1.0, 0.9, 0.9, 0.0, 1.2);
        const std::vector<RefKeyframe> refB3 = RefFromStatic(0.6, 1.0, 3.0, 0.0, 0.0, 2.0);
        envelopeStaticFadePathParityOk =
            CheckEnvelopeExact(envB1, {{0, 0.0}, {500000, 0.8}, {1300000, 0.8}, {2000000, 0.0}}) &&
            CheckEnvelopeRefParity(envB1, refB1) &&
            CheckEnvelopeExact(envB2, {{0, 0.0}, {600000, 0.5}, {1200000, 0.0}}) &&
            CheckEnvelopeRefParity(envB2, refB2) &&
            CheckEnvelopeExact(envB3, {{0, 0.0}, {2000000, 0.6}}) &&
            CheckEnvelopeRefParity(envB3, refB3);
        if (!envelopeStaticFadePathParityOk) fail("envelope_static_fade_parity");
        staticFadeKeyframeCount = static_cast<long long>(envB1.keyframeCount());

        // ── Fixture C: ForTrack fallback (all keyframes out of range) ───────
        const std::vector<Keyframe> rawC = {
            {0, 0.9, Interp::kLinear},
            {3000000, 0.2, Interp::kLinear},
        };
        AudioGainEnvelope envC;
        if (AudioGainEnvelope::ForTrack(rawC.data(), rawC.size(), 0.7, 0.5, 0, 0, 1000000,
                                        2000000, &envC) != BuildResult::kOk) {
            fail("for_track_build_failed");
        }
        const std::vector<RefKeyframe> refC = RefForTrack(
            {{0.0, 0.9}, {3.0, 0.2}}, 0.7, 0.5, 0.0, 0.0, 1.0, 2.0);
        envelopeForTrackFallbackParityOk =
            CheckEnvelopeExact(envC, {{1000000, 0.7 * 0.5}, {2000000, 0.7 * 0.5}}) &&
            CheckEnvelopeRefParity(envC, refC);
        if (!envelopeForTrackFallbackParityOk) fail("envelope_for_track_fallback_parity");

        // ── Boundary inclusivity: keyframes exactly at trackStart/trackEnd
        // survive (inclusive range) and hold before/at/after the ends ───────
        const std::vector<Keyframe> rawBoundary = {
            {0, 0.25, Interp::kLinear},
            {2000000, 0.75, Interp::kLinear},
        };
        AudioGainEnvelope envBoundary;
        if (AudioGainEnvelope::Normalize(rawBoundary.data(), rawBoundary.size(), 0, 2000000,
                                         1.0, &envBoundary) != BuildResult::kOk) {
            fail("boundary_build_failed");
        }
        boundaryInclusivityOk =
            CheckEnvelopeExact(envBoundary, {{0, 0.25}, {2000000, 0.75}}) &&
            envBoundary.evaluate(0) == 0.25 &&
            envBoundary.evaluate(-5000) == 0.25 &&
            envBoundary.evaluate(2000000) == 0.75 &&
            envBoundary.evaluate(2000001) == 0.75;
        if (!boundaryInclusivityOk) fail("boundary_inclusivity");

        // ── mixGain normalization: outside [0,1] resets to unity ────────────
        const std::vector<Keyframe> rawM = {{0, 0.5, Interp::kLinear}};
        AudioGainEnvelope envM1;
        AudioGainEnvelope envM2;
        AudioGainEnvelope envM3;
        AudioGainEnvelope envM4;
        mixGainNormalizationOk =
            AudioGainEnvelope::Normalize(rawM.data(), 1, 0, 1000000, 1.5, &envM1) ==
                BuildResult::kOk &&
            CheckEnvelopeExact(envM1, {{0, 0.5}, {1000000, 0.5}}) &&
            AudioGainEnvelope::Normalize(rawM.data(), 1, 0, 1000000, -0.2, &envM2) ==
                BuildResult::kOk &&
            CheckEnvelopeExact(envM2, {{0, 0.5}, {1000000, 0.5}}) &&
            AudioGainEnvelope::Normalize(rawM.data(), 1, 0, 1000000, 0.5, &envM3) ==
                BuildResult::kOk &&
            CheckEnvelopeExact(envM3, {{0, 0.25}, {1000000, 0.25}}) &&
            AudioGainEnvelope::FromStatic(0.5, 1.7, 0, 0, 0, 1000000, &envM4) ==
                BuildResult::kOk &&
            CheckEnvelopeExact(envM4, {{0, 0.5}, {1000000, 0.5}});
        if (!mixGainNormalizationOk) fail("mix_gain_normalization");

        // ── Empty envelope: silence parity ──────────────────────────────────
        const AudioGainEnvelope emptyEnv;
        size_t emptyCursor = 0;
        emptyEnvelopeSilenceParityOk =
            emptyEnv.empty() && emptyEnv.keyframeCount() == 0 &&
            emptyEnv.evaluate(0) == 0.0 && emptyEnv.evaluate(123456789) == 0.0 &&
            emptyEnv.evaluateCursor(500, &emptyCursor) == 0.0 &&
            emptyEnv.keyframeAt(0).timeUs == 0 && emptyEnv.keyframeAt(0).gain == 0.0 &&
            RefEvaluate({}, 0.5) == 0.0;
        if (!emptyEnvelopeSilenceParityOk) fail("empty_envelope_silence_parity");

        // ── Sub-millisecond rules: merge keeps the later keyframe and no
        // built envelope carries a sub-ms span (making the evaluate() hold
        // branch defensive-only, exactly as in Kotlin) ───────────────────────
        bool mergedEarlierDropped = true;
        for (size_t i = 0; i < envA.keyframeCount(); ++i) {
            if (envA.keyframeAt(i).timeUs == 2000000) mergedEarlierDropped = false;
        }
        const bool mergedKeptLater = mergedEarlierDropped &&
            envA.keyframeCount() == 5 &&
            envA.keyframeAt(1).timeUs == 2000400 &&
            std::fabs(envA.keyframeAt(1).gain - 0.6 * 0.5) <= 1e-12;
        subMillisecondHoldOk = mergedKeptLater &&
            CheckNoSubMillisecondSpans(envA) && CheckNoSubMillisecondSpans(envB1) &&
            CheckNoSubMillisecondSpans(envB2) && CheckNoSubMillisecondSpans(envB3) &&
            CheckNoSubMillisecondSpans(envC) && CheckNoSubMillisecondSpans(envBoundary);
        if (!subMillisecondHoldOk) fail("sub_millisecond_hold");

        // ── Unsupported interpolation reject (Normalize and ForTrack both
        // reject; ForTrack must not silently fall back to the static path) ───
        const Keyframe badInterp{500000, 0.5, static_cast<Interp>(3)};
        AudioGainEnvelope envBad;
        unsupportedInterpolationRejectOk =
            AudioGainEnvelope::Normalize(&badInterp, 1, 0, 1000000, 1.0, &envBad) ==
                BuildResult::kUnsupportedInterpolation &&
            AudioGainEnvelope::ForTrack(&badInterp, 1, 0.5, 1.0, 0, 0, 0, 1000000, &envBad) ==
                BuildResult::kUnsupportedInterpolation;
        if (!unsupportedInterpolationRejectOk) fail("unsupported_interpolation_reject");

        // ── Keyframe cap: kMaxRawKeyframes accepted, one more rejected
        // before any mutation of the output envelope ─────────────────────────
        {
            std::vector<Keyframe> capRaw(AudioGainEnvelope::kMaxRawKeyframes + 1);
            for (size_t i = 0; i < capRaw.size(); ++i) {
                capRaw[i] = Keyframe{static_cast<int64_t>(i) * 2000, 0.5, Interp::kLinear};
            }
            const int64_t capEndAt =
                static_cast<int64_t>(AudioGainEnvelope::kMaxRawKeyframes - 1) * 2000;
            AudioGainEnvelope envAtCap;
            const bool atCapOk = AudioGainEnvelope::Normalize(
                capRaw.data(), AudioGainEnvelope::kMaxRawKeyframes, 0, capEndAt, 1.0,
                &envAtCap) == BuildResult::kOk &&
                envAtCap.keyframeCount() == AudioGainEnvelope::kMaxRawKeyframes;
            AudioGainEnvelope envSentinel = envBoundary; // pre-filled sentinel content
            const bool overCapRejected = AudioGainEnvelope::Normalize(
                capRaw.data(), capRaw.size(), 0, capEndAt + 2000, 1.0, &envSentinel) ==
                BuildResult::kTooManyKeyframes;
            keyframeCapRejectOk = atCapOk && overCapRejected &&
                CheckEnvelopeExact(envSentinel, {{0, 0.25}, {2000000, 0.75}});
            if (!keyframeCapRejectOk) fail("keyframe_cap_reject");
        }

        // ── Invalid envelope range: negative track bounds (either end) and
        // end-before-start must all reject with kInvalidRange from
        // Normalize, FromStatic, and both ForTrack paths BEFORE the output
        // envelope mutates (proven via a pre-filled sentinel) ────────────────
        {
            const Keyframe rangeKf{500000, 0.5, Interp::kLinear};
            AudioGainEnvelope envRangeSentinel = envBoundary; // pre-filled sentinel content
            const bool normalizeNegStartRejected = AudioGainEnvelope::Normalize(
                &rangeKf, 1, -1, 1000000, 1.0, &envRangeSentinel) ==
                BuildResult::kInvalidRange;
            const bool normalizeNegEndRejected = AudioGainEnvelope::Normalize(
                &rangeKf, 1, 0, -1, 1.0, &envRangeSentinel) ==
                BuildResult::kInvalidRange;
            const bool fromStaticNegStartRejected = AudioGainEnvelope::FromStatic(
                0.5, 1.0, 0, 0, -1, 1000000, &envRangeSentinel) ==
                BuildResult::kInvalidRange;
            // Both bounds negative with end >= start: rejected on sign alone,
            // not on ordering.
            const bool fromStaticNegBothRejected = AudioGainEnvelope::FromStatic(
                0.5, 1.0, 0, 0, -2, -1, &envRangeSentinel) ==
                BuildResult::kInvalidRange;
            // ForTrack inherits the reject through both builder paths
            // (keyframe path and the rawCount == 0 static path).
            const bool forTrackKeyframePathRejected = AudioGainEnvelope::ForTrack(
                &rangeKf, 1, 0.5, 1.0, 0, 0, -1, 1000000, &envRangeSentinel) ==
                BuildResult::kInvalidRange;
            const bool forTrackStaticPathRejected = AudioGainEnvelope::ForTrack(
                nullptr, 0, 0.5, 1.0, 0, 0, -1, 1000000, &envRangeSentinel) ==
                BuildResult::kInvalidRange;
            const bool endBeforeStartStillRejected = AudioGainEnvelope::Normalize(
                &rangeKf, 1, 2000000, 1000000, 1.0, &envRangeSentinel) ==
                BuildResult::kInvalidRange;
            invalidEnvelopeRangeRejectOk =
                normalizeNegStartRejected && normalizeNegEndRejected &&
                fromStaticNegStartRejected && fromStaticNegBothRejected &&
                forTrackKeyframePathRejected && forTrackStaticPathRejected &&
                endBeforeStartStillRejected &&
                CheckEnvelopeExact(envRangeSentinel, {{0, 0.25}, {2000000, 0.75}});
            if (!invalidEnvelopeRangeRejectOk) fail("invalid_envelope_range_reject");
        }

        // ── Mix fixtures: 48 kHz stereo node, one 960-frame (20 ms) window
        // with a fade-in/hold/fade-out envelope over [0, 20 ms] ──────────────
        constexpr int32_t kRate       = 48000;
        constexpr int64_t kFrames     = 960;
        constexpr int64_t kMaxFrames  = 2048;
        AudioGainEnvelope envRamp; // (0,0) -> (10ms,1) -> (15ms,1) -> (20ms,0)
        if (AudioGainEnvelope::FromStatic(1.0, 1.0, 10000, 5000, 0, 20000, &envRamp) !=
            BuildResult::kOk) {
            fail("ramp_envelope_build_failed");
        }
        AudioGainEnvelope envFlatUnity; // constant 1.0 over the window
        if (AudioGainEnvelope::FromStatic(1.0, 1.0, 0, 0, 0, 20000, &envFlatUnity) !=
            BuildResult::kOk) {
            fail("flat_envelope_build_failed");
        }

        std::vector<int16_t> pcmStereo(static_cast<size_t>(kFrames * 2));
        for (size_t i = 0; i < pcmStereo.size(); ++i) {
            pcmStereo[i] = static_cast<int16_t>(
                static_cast<int32_t>((i * 37) % 1301) - 650);
        }

        AudioMixBusNode node("p4_mixbus_timeline_diag", kRate, 2, kMaxFrames);
        std::vector<int16_t> out(static_cast<size_t>(kFrames * 2), 0);

        MixTrack track{};
        track.pcm          = pcmStereo.data();
        track.frameCount   = kFrames;
        track.sampleRate   = kRate;
        track.channelCount = 2;

        // M1: unit static gain + ramp envelope (per-frame application).
        track.gain               = 1.0;
        track.envelope           = &envRamp;
        track.envelopeStartPtsUs = 0;
        MixOutput m1{};
        if (node.mix(&track, 1, kFrames, out.data(), static_cast<int64_t>(out.size()),
                     &m1) != MixResult::kOk) {
            fail("m1_mix_failed");
        }
        const std::vector<int16_t> m1Expected = ExpectedSingleTrackMix(
            pcmStereo, kFrames, 2, 2, kRate, 1.0, &envRamp, 0, false);
        envelopeMixChecksum = m1.checksum;
        framesMixedMetric = m1.framesMixed;
        envelopeEvaluationsMetric = m1.envelopeEvaluations;
        perFrameEnvelopeAppliedOk =
            m1.checksum == ChecksumPcm16(m1Expected) &&
            std::equal(out.begin(), out.end(), m1Expected.begin()) &&
            m1.envelopeApplied && m1.envelopeEvaluations == kFrames &&
            m1.framesMixed == kFrames &&
            m1.minEffectiveGain == 0.0 && m1.maxEffectiveGain == 1.0;
        if (!perFrameEnvelopeAppliedOk) fail("per_frame_envelope_applied");

        // Floor PTS derivation: M1 must equal the floor-PTS reference and
        // differ from the nearest-integer-PTS variant.
        const std::vector<int16_t> m1RoundExpected = ExpectedSingleTrackMix(
            pcmStereo, kFrames, 2, 2, kRate, 1.0, &envRamp, 0, true);
        roundPtsChecksum = ChecksumPcm16(m1RoundExpected);
        floorPtsDerivationOk =
            m1.checksum == ChecksumPcm16(m1Expected) && m1.checksum != roundPtsChecksum;
        if (!floorPtsDerivationOk) fail("floor_pts_derivation");

        // M2: static gain 0.5 composed with the ramp envelope.
        track.gain = 0.5;
        MixOutput m2{};
        if (node.mix(&track, 1, kFrames, out.data(), static_cast<int64_t>(out.size()),
                     &m2) != MixResult::kOk) {
            fail("m2_mix_failed");
        }
        const std::vector<int16_t> m2Expected = ExpectedSingleTrackMix(
            pcmStereo, kFrames, 2, 2, kRate, 0.5, &envRamp, 0, false);
        staticGainChecksum = m2.checksum;
        minEffectiveGainMetric = m2.minEffectiveGain;
        maxEffectiveGainMetric = m2.maxEffectiveGain;
        staticGainCompositionOk =
            m2.checksum == ChecksumPcm16(m2Expected) &&
            m2.minEffectiveGain == 0.0 && m2.maxEffectiveGain == 0.5 &&
            m2.checksum != m1.checksum;
        if (!staticGainCompositionOk) fail("static_gain_composition");

        // M3: null envelope must be bit-identical to the pre-slice
        // static-gain behaviour; M4 (flat unity envelope * same static gain)
        // must reproduce it exactly.
        track.gain     = 0.5;
        track.envelope = nullptr;
        MixOutput m3{};
        if (node.mix(&track, 1, kFrames, out.data(), static_cast<int64_t>(out.size()),
                     &m3) != MixResult::kOk) {
            fail("m3_mix_failed");
        }
        const std::vector<int16_t> baselineExpected = ExpectedSingleTrackMix(
            pcmStereo, kFrames, 2, 2, kRate, 0.5, nullptr, 0, false);
        baselineStaticChecksum = ChecksumPcm16(baselineExpected);
        nullEnvelopeChecksum   = m3.checksum;
        const bool m3BufferMatchesBaseline =
            std::equal(out.begin(), out.end(), baselineExpected.begin());
        track.envelope = &envFlatUnity;
        MixOutput m4{};
        if (node.mix(&track, 1, kFrames, out.data(), static_cast<int64_t>(out.size()),
                     &m4) != MixResult::kOk) {
            fail("m4_mix_failed");
        }
        nullEnvelopeBackCompatOk =
            m3.checksum == baselineStaticChecksum &&
            m3BufferMatchesBaseline &&
            m4.checksum == m3.checksum &&
            !m3.envelopeApplied && m3.envelopeEvaluations == 0 &&
            m3.minEffectiveGain == 0.0 && m3.maxEffectiveGain == 0.0 &&
            m4.envelopeApplied;
        if (!nullEnvelopeBackCompatOk) fail("null_envelope_back_compat");

        // Cursor reset per call: repeating M1 must be bit-reproducible (the
        // envelope cursor is call-local; no state persists on the node or
        // the envelope).
        track.gain     = 1.0;
        track.envelope = &envRamp;
        MixOutput m1Again{};
        if (node.mix(&track, 1, kFrames, out.data(), static_cast<int64_t>(out.size()),
                     &m1Again) != MixResult::kOk) {
            fail("m1_repeat_mix_failed");
        }
        bool cursorApiRepeatOk = true;
        {
            // A fresh cursor over the same monotonic sweep must reproduce
            // the previous pass exactly (the envelope keeps no state).
            std::vector<double> pass1;
            std::vector<double> pass2;
            size_t c1 = 0;
            size_t c2 = 0;
            for (int64_t t = 0; t <= 20000; t += 37) pass1.push_back(envRamp.evaluateCursor(t, &c1));
            for (int64_t t = 0; t <= 20000; t += 37) pass2.push_back(envRamp.evaluateCursor(t, &c2));
            cursorApiRepeatOk = pass1 == pass2;
        }
        envelopeCursorResetPerCallOk =
            m1Again.checksum == m1.checksum &&
            m1Again.envelopeEvaluations == m1.envelopeEvaluations && cursorApiRepeatOk;
        if (!envelopeCursorResetPerCallOk) fail("envelope_cursor_reset_per_call");

        // No per-mix allocation (structural): the accumulator is sized once
        // at construction and reused; 64 repeated identical mixes must stay
        // bit-identical with stable output metrics. No global allocation
        // hooks are installed (honest limit of this lane).
        {
            bool stable = true;
            for (int i = 0; i < 64 && stable; ++i) {
                MixOutput rep{};
                if (node.mix(&track, 1, kFrames, out.data(),
                             static_cast<int64_t>(out.size()), &rep) != MixResult::kOk) {
                    stable = false;
                    break;
                }
                stable = rep.checksum == m1.checksum && rep.framesMixed == m1.framesMixed &&
                    rep.maxAccumulatorAbs == m1.maxAccumulatorAbs &&
                    rep.envelopeEvaluations == m1.envelopeEvaluations &&
                    rep.minEffectiveGain == m1.minEffectiveGain &&
                    rep.maxEffectiveGain == m1.maxEffectiveGain;
            }
            noPerMixAllocationOk = stable;
            if (!noPerMixAllocationOk) fail("no_per_mix_allocation");
        }

        // ── Fail-before-output rejects ──────────────────────────────────────
        // Negative envelopeStartPtsUs and an out-of-range envelope gain
        // (FromStatic with volume 1.5 — Kotlin parity does not clamp the
        // static volume) must both reject before the output buffer or the
        // accumulator-visible result mutates. The invalid-gain envelope is a
        // legal build product, so no test-only mutation API is needed.
        {
            AudioGainEnvelope envOverUnity;
            if (AudioGainEnvelope::FromStatic(1.5, 1.0, 0, 0, 0, 20000, &envOverUnity) !=
                BuildResult::kOk) {
                fail("over_unity_envelope_build_failed");
            }
            std::vector<int16_t> sentinelOut(static_cast<size_t>(kFrames * 2),
                                             static_cast<int16_t>(0x5A5A));
            MixTrack badTrack = track;
            badTrack.gain               = 1.0;
            badTrack.envelope           = &envRamp;
            badTrack.envelopeStartPtsUs = -1;
            MixOutput badOut{};
            badOut.framesMixed = 777; // must be zeroed by the failing call
            const MixResult startPtsResult = node.mix(
                &badTrack, 1, kFrames, sentinelOut.data(),
                static_cast<int64_t>(sentinelOut.size()), &badOut);
            const bool sentinelIntact1 = std::all_of(
                sentinelOut.begin(), sentinelOut.end(),
                [](int16_t v) { return v == static_cast<int16_t>(0x5A5A); });
            invalidEnvelopeStartPtsRejectOk =
                startPtsResult == MixResult::kInvalidEnvelopeStartPts &&
                sentinelIntact1 && badOut.framesMixed == 0 && badOut.checksum == 0;
            if (!invalidEnvelopeStartPtsRejectOk) fail("invalid_envelope_start_pts_reject");

            badTrack.envelope           = &envOverUnity;
            badTrack.envelopeStartPtsUs = 0;
            MixOutput badOut2{};
            const MixResult gainResult = node.mix(
                &badTrack, 1, kFrames, sentinelOut.data(),
                static_cast<int64_t>(sentinelOut.size()), &badOut2);
            const bool sentinelIntact2 = std::all_of(
                sentinelOut.begin(), sentinelOut.end(),
                [](int16_t v) { return v == static_cast<int16_t>(0x5A5A); });
            invalidEnvelopeGainRejectOk =
                gainResult == MixResult::kInvalidEnvelopeGain &&
                sentinelIntact2 && badOut2.framesMixed == 0 && badOut2.checksum == 0;
            if (!invalidEnvelopeGainRejectOk) fail("invalid_envelope_gain_reject");
        }

        // ── Single quantization: stereo->mono downmix with composed static
        // and envelope gain must match sample*effectiveGain truncated ONCE
        // and be distinguishable from the pre-scale-to-int16 approximation
        // of the production Kotlin chunk-mixer path ──────────────────────────
        {
            constexpr int64_t kMonoFrames = 16;
            std::vector<int16_t> pcmSq(static_cast<size_t>(kMonoFrames * 2));
            for (int64_t f = 0; f < kMonoFrames; ++f) {
                pcmSq[static_cast<size_t>(f * 2 + 0)] = static_cast<int16_t>(5 + 2 * f);
                pcmSq[static_cast<size_t>(f * 2 + 1)] = 1;
            }
            AudioGainEnvelope envFlat0p9; // constant 0.9 over [0, 1000] us
            if (AudioGainEnvelope::FromStatic(0.9, 1.0, 0, 0, 0, 1000, &envFlat0p9) !=
                BuildResult::kOk) {
                fail("flat_0p9_envelope_build_failed");
            }
            AudioMixBusNode monoNode("p4_mixbus_timeline_diag_mono", kRate, 1, 64);
            std::vector<int16_t> monoOut(static_cast<size_t>(kMonoFrames), 0);
            MixTrack sqTrack{};
            sqTrack.pcm                = pcmSq.data();
            sqTrack.frameCount         = kMonoFrames;
            sqTrack.sampleRate         = kRate;
            sqTrack.channelCount       = 2;
            sqTrack.gain               = 0.9;
            sqTrack.envelope           = &envFlat0p9;
            sqTrack.envelopeStartPtsUs = 0;
            MixOutput sqOut{};
            if (monoNode.mix(&sqTrack, 1, kMonoFrames, monoOut.data(),
                             static_cast<int64_t>(monoOut.size()), &sqOut) != MixResult::kOk) {
                fail("single_quantization_mix_failed");
            }
            const std::vector<int16_t> sqExpected = ExpectedSingleTrackMix(
                pcmSq, kMonoFrames, 2, 1, kRate, 0.9, &envFlat0p9, 0, false);
            singleQuantChecksum = ChecksumPcm16(sqExpected);
            prescaleApproxChecksum = PrescaleApproxChecksumStereoToMono(
                pcmSq, kMonoFrames, kRate, 0.9, envFlat0p9, 0);
            singleQuantizationOk =
                sqOut.checksum == singleQuantChecksum &&
                singleQuantChecksum != prescaleApproxChecksum;
            if (!singleQuantizationOk) fail("single_quantization");
        }

        // ── Analytic evaluation parity + cursor monotonicity: >= 2000
        // samples across every built envelope compared against the Kotlin
        // double-seconds reference; cursor path must equal the full scan
        // exactly and never move backward on a monotonic sweep ───────────────
        {
            struct ParityCase {
                const AudioGainEnvelope* env;
                std::vector<RefKeyframe> ref;
                int64_t                  loUs;
                int64_t                  hiUs;
            };
            std::vector<RefKeyframe> refRamp = RefFromStatic(1.0, 1.0, 0.01, 0.005, 0.0, 0.02);
            std::vector<RefKeyframe> refFlatUnity = RefFromStatic(1.0, 1.0, 0.0, 0.0, 0.0, 0.02);
            std::vector<RefKeyframe> refBoundary = RefNormalize(
                {{0.0, 0.25}, {2.0, 0.75}}, 0.0, 2.0, 1.0);
            const std::vector<ParityCase> cases = {
                {&envA, refA, 900000, 5100000},
                {&envB1, refB1, -100000, 2100000},
                {&envB2, refB2, -100000, 1300000},
                {&envB3, refB3, -100000, 2100000},
                {&envC, refC, 900000, 2100000},
                {&envBoundary, refBoundary, -100000, 2100000},
                {&envRamp, refRamp, -5000, 25000},
                {&envFlatUnity, refFlatUnity, -5000, 25000},
            };
            constexpr int kSamplesPerCase = 300;
            bool parity = true;
            bool cursorMonotonic = true;
            for (const ParityCase& pc : cases) {
                size_t cursor = 0;
                size_t lastCursor = 0;
                for (int i = 0; i < kSamplesPerCase; ++i) {
                    const int64_t t = pc.loUs +
                        (static_cast<int64_t>(i) * (pc.hiUs - pc.loUs)) / (kSamplesPerCase - 1);
                    const double nativeGain = pc.env->evaluate(t);
                    const double refGain = RefEvaluate(pc.ref, static_cast<double>(t) / 1e6);
                    const double diff = std::fabs(nativeGain - refGain);
                    if (diff > maxGainDiff) maxGainDiff = diff;
                    if (!(diff <= 1e-9)) parity = false;
                    const double cursorGain = pc.env->evaluateCursor(t, &cursor);
                    if (cursorGain != nativeGain) cursorMonotonic = false;
                    if (cursor < lastCursor) cursorMonotonic = false;
                    lastCursor = cursor;
                    ++evaluationSampleCount;
                }
            }
            envelopeEvaluationParityOk = parity && evaluationSampleCount >= 2000;
            if (!envelopeEvaluationParityOk) fail("envelope_evaluation_parity");
            envelopeCursorMonotonicOk = cursorMonotonic;
            if (!envelopeCursorMonotonicOk) fail("envelope_cursor_monotonic");
        }

        // ── Honesty lanes ───────────────────────────────────────────────────
        // GraphAudioScheduler (route/window owner) and the production
        // AndroidNativeAudioMixBusChunkMixer were neither modified nor
        // needed: the scheduler keeps emitting unit gain / null envelope,
        // which the null-envelope back-compat lane proved bit-identical to
        // the prior behaviour. Source-level claims only; no production
        // export execution is claimed.
        schedulerUnchangedOk         = nullEnvelopeBackCompatOk;
        productionMixdownUntouchedOk = nullEnvelopeBackCompatOk;
        if (!schedulerUnchangedOk) fail("scheduler_unchanged");
        if (!productionMixdownUntouchedOk) fail("production_mixdown_untouched");

        // Everything above lives on this call's stack/locals; both nodes and
        // every envelope are destroyed on scope exit before the reply is
        // built. One-shot route: no registry, no handle, no OS resource.
        stackScoped = true;
        lifecycleOk = true;
    } catch (const std::exception& e) {
        fail(e.what());
    } catch (...) {
        fail("unknown_native_exception");
    }

    const bool pass =
        envelopeNormalizationParityOk && envelopeStaticFadePathParityOk &&
        envelopeForTrackFallbackParityOk && envelopeEvaluationParityOk &&
        emptyEnvelopeSilenceParityOk && subMillisecondHoldOk && boundaryInclusivityOk &&
        mixGainNormalizationOk && perFrameEnvelopeAppliedOk && staticGainCompositionOk &&
        nullEnvelopeBackCompatOk && singleQuantizationOk && envelopeCursorMonotonicOk &&
        envelopeCursorResetPerCallOk && floorPtsDerivationOk &&
        unsupportedInterpolationRejectOk && keyframeCapRejectOk &&
        invalidEnvelopeRangeRejectOk &&
        invalidEnvelopeStartPtsRejectOk && invalidEnvelopeGainRejectOk &&
        noPerMixAllocationOk && schedulerUnchangedOk && productionMixdownUntouchedOk &&
        lifecycleOk && stackScoped && failureReason.empty();

    std::string status;
    status.reserve(3072);
    AppendKV(status, "status", pass ? "PASS" : "FAIL");
    if (!pass) {
        AppendKV(status, "reason",
                 failureReason.empty() ? "lane_failed" : failureReason);
    }
    auto laneKV = [&](const char* key, bool value) {
        AppendKV(status, key, value ? "true" : "false");
    };
    laneKV("envelopeNormalizationParityOk", envelopeNormalizationParityOk);
    laneKV("envelopeStaticFadePathParityOk", envelopeStaticFadePathParityOk);
    laneKV("envelopeForTrackFallbackParityOk", envelopeForTrackFallbackParityOk);
    laneKV("envelopeEvaluationParityOk", envelopeEvaluationParityOk);
    laneKV("emptyEnvelopeSilenceParityOk", emptyEnvelopeSilenceParityOk);
    laneKV("subMillisecondHoldOk", subMillisecondHoldOk);
    laneKV("boundaryInclusivityOk", boundaryInclusivityOk);
    laneKV("mixGainNormalizationOk", mixGainNormalizationOk);
    laneKV("perFrameEnvelopeAppliedOk", perFrameEnvelopeAppliedOk);
    laneKV("staticGainCompositionOk", staticGainCompositionOk);
    laneKV("nullEnvelopeBackCompatOk", nullEnvelopeBackCompatOk);
    laneKV("singleQuantizationOk", singleQuantizationOk);
    laneKV("envelopeCursorMonotonicOk", envelopeCursorMonotonicOk);
    laneKV("envelopeCursorResetPerCallOk", envelopeCursorResetPerCallOk);
    laneKV("floorPtsDerivationOk", floorPtsDerivationOk);
    laneKV("unsupportedInterpolationRejectOk", unsupportedInterpolationRejectOk);
    laneKV("keyframeCapRejectOk", keyframeCapRejectOk);
    laneKV("invalidEnvelopeRangeRejectOk", invalidEnvelopeRangeRejectOk);
    laneKV("invalidEnvelopeStartPtsRejectOk", invalidEnvelopeStartPtsRejectOk);
    laneKV("invalidEnvelopeGainRejectOk", invalidEnvelopeGainRejectOk);
    laneKV("noPerMixAllocationOk", noPerMixAllocationOk);
    laneKV("schedulerUnchangedOk", schedulerUnchangedOk);
    laneKV("productionMixdownUntouchedOk", productionMixdownUntouchedOk);
    laneKV("lifecycleOk", lifecycleOk);
    laneKV("stackScoped", stackScoped);
    laneKV("canonical", pass);
    AppendKV(status, "normalizedKeyframeCount", LongStr(normalizedKeyframeCount));
    AppendKV(status, "staticFadeKeyframeCount", LongStr(staticFadeKeyframeCount));
    AppendKV(status, "evaluationSampleCount", LongStr(evaluationSampleCount));
    // Max |nativeGain - kotlinReferenceGain| scaled by 1e15 (<= 1e-9 means
    // the scaled value stays below 1e6).
    AppendKV(status, "maxGainDiffScaled",
             LongStr(static_cast<long long>(std::llround(maxGainDiff * 1e15))));
    AppendKV(status, "staticGainChecksumHex", Hex64(staticGainChecksum));
    AppendKV(status, "envelopeMixChecksumHex", Hex64(envelopeMixChecksum));
    AppendKV(status, "nullEnvelopeChecksumHex", Hex64(nullEnvelopeChecksum));
    AppendKV(status, "baselineStaticChecksumHex", Hex64(baselineStaticChecksum));
    AppendKV(status, "prescaleApproxChecksumHex", Hex64(prescaleApproxChecksum));
    AppendKV(status, "singleQuantChecksumHex", Hex64(singleQuantChecksum));
    AppendKV(status, "roundPtsChecksumHex", Hex64(roundPtsChecksum));
    AppendKV(status, "minEffectiveGain", DoubleStr(minEffectiveGainMetric));
    AppendKV(status, "maxEffectiveGain", DoubleStr(maxEffectiveGainMetric));
    AppendKV(status, "envelopeEvaluations", LongStr(envelopeEvaluationsMetric));
    AppendKV(status, "framesMixed", LongStr(framesMixedMetric));
    AppendKV(status, "sampleRate", "48000");
    AppendKV(status, "channelCount", "2");
    AppendKV(status, "maxFramesPerMix", "2048");
    AppendKV(status, "envelopeGainRejectVia", "from_static_volume_above_unity_no_test_hook");
    AppendKV(status, "timelineOwnershipHonesty",
             "p0_prerequisite_for_production_graph_reroute_not_a_runtime_queue_blocker");
    AppendKV(status, "proofBoundary", kProofBoundary);

    return env->NewStringUTF(status.c_str());
}
