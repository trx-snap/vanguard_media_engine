// P4-AUDIO-GRAPH-TRANSPORT-CLOCK sub-slice C: caller-clocked, lock-free
// monotonic media-position tracker + drift-telemetry native proof.
//
// Honest non-claims:
// - Does not claim realtime or audible playback.
// - Does not use AudioTrack, AAudio, OpenSL, or Oboe.
// - Does not implement a production PCM decoder or writer.
// - Does not reroute export.
// - Does not stream.
// - Does not touch iOS or product/editor UI.
// - Does not read any internal wall clock; every AudioClock call below is
//   fed an explicit, caller-chosen sysTimeNs.
//
// AudioClock is diagnostic-only here: this translation unit exercises it
// directly on the calling thread (no separate reader thread is spawned),
// so the seqlock retry path is proven functionally (bounded, non-blocking
// reads succeed) rather than under genuine cross-thread contention. The
// ring-coordination lane instantiates AudioSpscAudioRingBuffer and
// RingBufferAudioSampleProvider (both already proven in sub-slice B) only
// to exercise the requestSeek -> provide/consume -> AudioClock::seek
// hand-off; it does not modify either type. This translation unit is
// Android-only and must NOT be included in iOS or host builds; it is added
// via the Android-only target_sources block in src/CMakeLists.txt.
//
// JNI entry point:
//   runAndroidDagPhase4AudioClockSmoke -> jstring

#include <jni.h>

#include <cstdint>
#include <limits>
#include <sstream>
#include <string>
#include <vector>

#include "vanguard/audio/audio_clock.h"
#include "vanguard/audio/audio_ring_buffer.h"
#include "vanguard/audio/ring_buffer_audio_sample_provider.h"
#include "vanguard/core/status.h"

namespace {

constexpr const char* kProofBoundary =
    "native_audio_clock_monotonic_timebase_and_drift_proof_only_no_audio_track_no_aaudio_no_audible_playback_no_decoder_writer_no_export_reroute_no_streaming_no_ios_no_product_no_internal_wall_clock_read";

using vanguard::audio::AudioClock;
using vanguard::audio::AudioSpscAudioRingBuffer;
using vanguard::audio::AudioWindowBuffer;
using vanguard::audio::AudioWindowRequest;
using vanguard::audio::RingBufferAudioSampleProvider;

constexpr int64_t kInt64Max = std::numeric_limits<int64_t>::max();
constexpr int64_t kInt64Min = std::numeric_limits<int64_t>::min();

std::string RunAudioClockSmokeInternal() {
    bool audioClockLockFreeOk  = false;
    bool clockMathOk           = false;
    bool rationalExactnessOk   = false;
    bool doubleDivergenceOk    = false;
    bool playPauseResumeOk     = false;
    bool seekOk                = false;
    bool speedMathOk           = false;
    bool monotonicityFuzzOk    = false;
    bool overflowSaturationOk  = false;
    bool invalidSpeedRejectOk  = false;
    bool driftTelemetryInertOk = false;
    bool ringSeekCoordinationOk = false;
    bool lifecycleOk           = false;
    bool stackScoped           = true;

    std::string failureReason;

    int64_t  finalPositionUs    = 0;
    int64_t  pausedPositionUs   = 0;
    int64_t  resumedPositionUs  = 0;
    int64_t  seekPositionUs     = 0;
    int64_t  driftDeltaUs       = 0;
    uint64_t driftSampleCount   = 0;
    int      fuzzIterations     = 0;

    // ── 1. audioClockLockFreeOk ──
    audioClockLockFreeOk = AudioClock::atomicSequenceLockFree();
    if (!audioClockLockFreeOk && failureReason.empty()) failureReason = "audio_clock_lock_free_failed";

    // ── 2. clockMathOk: ScaleNanosToMicros exactness on hand-computed cases ──
    {
        const bool zeroDelta   = AudioClock::ScaleNanosToMicros(0, 1, 1) == 0;
        const bool subMicro    = AudioClock::ScaleNanosToMicros(999, 1, 1) == 0;
        const bool exactMicro  = AudioClock::ScaleNanosToMicros(1000, 1, 1) == 1;
        const bool oneSecond   = AudioClock::ScaleNanosToMicros(1'000'000'000LL, 1, 1) == 1'000'000LL;
        const bool oneAndHalf  = AudioClock::ScaleNanosToMicros(1'000'000'000LL, 3, 2) == 1'500'000LL;
        const bool halfSpeed   = AudioClock::ScaleNanosToMicros(1'000'000'000LL, 1, 2) == 500'000LL;
        const bool negativeDelta   = AudioClock::ScaleNanosToMicros(-5, 1, 1) == 0;
        const bool invalidNumerator = AudioClock::ScaleNanosToMicros(100, 0, 1) == 0;
        const bool invalidDenominator = AudioClock::ScaleNanosToMicros(100, 1, 0) == 0;

        clockMathOk = zeroDelta && subMicro && exactMicro && oneSecond && oneAndHalf && halfSpeed &&
                     negativeDelta && invalidNumerator && invalidDenominator;
        if (!clockMathOk && failureReason.empty()) failureReason = "clock_math_failed";
    }

    // ── 3. rationalExactnessOk: setSpeed gcd-normalizes the stored ratio ──
    {
        AudioClock rationalClock;
        rationalClock.start(0, 0);
        const auto s1 = rationalClock.setSpeed(4, 8, 0); // -> normalized 1/2
        const auto snap1 = rationalClock.snapshot();
        const auto s2 = rationalClock.setSpeed(1000, 999, 0); // already coprime -> unchanged
        const auto snap2 = rationalClock.snapshot();

        rationalExactnessOk = s1.ok() && snap1.speedNumerator == 1 && snap1.speedDenominator == 2 &&
            s2.ok() && snap2.speedNumerator == 1000 && snap2.speedDenominator == 999;
        if (!rationalExactnessOk && failureReason.empty()) failureReason = "rational_exactness_failed";
    }

    // ── 4. doubleDivergenceOk: single-anchor exact extrapolation vs naive
    //    per-step float microsecond accumulation ──
    {
        AudioClock divClock;
        divClock.start(0, 0);
        constexpr int64_t kStepNs = 333333;
        constexpr int      kSteps = 100000;
        constexpr int64_t kTotalNs = kStepNs * static_cast<int64_t>(kSteps);
        constexpr int64_t kExpectedExactUs = 33'333'300LL; // kTotalNs / 1000, exact

        const int64_t exactPositionUs = divClock.currentPositionUs(kTotalNs);

        float naiveUsAccum = 0.0f;
        const float perStepUs = static_cast<float>(kStepNs) / 1000.0f;
        for (int i = 0; i < kSteps; ++i) {
            naiveUsAccum += perStepUs;
        }
        const int64_t naiveUs = static_cast<int64_t>(naiveUsAccum);

        doubleDivergenceOk = exactPositionUs == kExpectedExactUs && naiveUs != exactPositionUs;
        if (!doubleDivergenceOk && failureReason.empty()) failureReason = "double_divergence_failed";
    }

    // ── 5. playPauseResumeOk ──
    {
        AudioClock lcClock;
        const auto sStart = lcClock.start(1000, 500'000);
        const int64_t posAtStart  = lcClock.currentPositionUs(1000);
        const int64_t posAfter2s  = lcClock.currentPositionUs(1000 + 2'000'000'000LL);

        const auto sPause = lcClock.pause(1000 + 2'000'000'000LL);
        pausedPositionUs = lcClock.currentPositionUs(1000 + 5'000'000'000LL); // frozen despite later sysTimeNs

        const auto sPauseNoOp = lcClock.pause(1000 + 5'500'000'000LL); // pause-on-paused: no-op success
        const int64_t posAfterPauseNoOp = lcClock.currentPositionUs(1000 + 5'900'000'000LL);

        const auto sResume = lcClock.resume(1000 + 5'500'000'000LL);
        resumedPositionUs = lcClock.currentPositionUs(1000 + 6'500'000'000LL); // 1s after resume anchor

        const auto sResumeNoOp = lcClock.resume(1000 + 6'500'000'000LL); // resume-on-playing: no-op success
        const int64_t posAfterResumeNoOp = lcClock.currentPositionUs(1000 + 6'500'000'000LL);

        playPauseResumeOk = sStart.ok() && sPause.ok() && sPauseNoOp.ok() && sResume.ok() && sResumeNoOp.ok() &&
            posAtStart == 500'000 && posAfter2s == 2'500'000 &&
            pausedPositionUs == 2'500'000 && posAfterPauseNoOp == pausedPositionUs &&
            resumedPositionUs == 3'500'000 && posAfterResumeNoOp == resumedPositionUs;
        if (!playPauseResumeOk && failureReason.empty()) failureReason = "play_pause_resume_failed";
    }

    // ── 6. seekOk: seek() is the only operation allowed to move media pts
    //    backward, but it is not backward-only -- both directions must
    //    succeed from kPlaying and kPaused. ──
    {
        AudioClock seekClock;
        seekClock.start(0, 10'000'000);
        const int64_t posBeforeSeek = seekClock.currentPositionUs(3'000'000'000LL); // 13,000,000

        const auto sSeekBack = seekClock.seek(5'000'000, 3'000'000'000LL); // backward, legal
        seekPositionUs = seekClock.currentPositionUs(3'000'000'000LL);

        const auto sSeekForward = seekClock.seek(50'000'000, 3'000'000'000LL); // ahead of current pos -> legal
        const int64_t posAfterForwardSeek = seekClock.currentPositionUs(3'000'000'000LL);

        const auto sSeekNegative = seekClock.seek(-1, 3'000'000'000LL);
        const int64_t posAfterNegativeAttempt = seekClock.currentPositionUs(3'000'000'000LL);
        const auto sSeekBackwardTime = seekClock.seek(1'000'000, 2'000'000'000LL); // sysTimeNs regressed while playing
        const int64_t posAfterBackwardTimeAttempt = seekClock.currentPositionUs(3'000'000'000LL);

        AudioClock stoppedSeekClock;
        const auto sSeekStopped = stoppedSeekClock.seek(0, 0);

        AudioClock pausedSeekClock;
        pausedSeekClock.start(0, 1'000'000);
        pausedSeekClock.pause(500'000'000); // frozen position 1,500,000
        const auto sSeekPausedBack = pausedSeekClock.seek(1'000'000, 600'000'000); // legal backward while paused
        const int64_t posAfterPausedSeekBack = pausedSeekClock.currentPositionUs(999'999'999);
        const auto sSeekPausedForward = pausedSeekClock.seek(9'000'000, 700'000'000); // legal forward while paused
        const int64_t posAfterPausedSeekForward = pausedSeekClock.currentPositionUs(999'999'999);

        // Ordinary kPlaying extrapolation never regresses (see
        // monotonicityFuzzOk below); the sSeekBack transition above
        // (13,000,000 -> 5,000,000) is this proof's demonstration that only
        // seek() can move the media pts backward.
        seekOk = posBeforeSeek == 13'000'000 &&
            sSeekBack.ok() && seekPositionUs == 5'000'000 &&
            sSeekForward.ok() && posAfterForwardSeek == 50'000'000 &&
            !sSeekNegative.ok() && posAfterNegativeAttempt == posAfterForwardSeek &&
            !sSeekBackwardTime.ok() && posAfterBackwardTimeAttempt == posAfterForwardSeek &&
            !sSeekStopped.ok() &&
            sSeekPausedBack.ok() && posAfterPausedSeekBack == 1'000'000 &&
            sSeekPausedForward.ok() && posAfterPausedSeekForward == 9'000'000;
        if (!seekOk && failureReason.empty()) failureReason = "seek_failed";
    }

    // ── 7. speedMathOk ──
    {
        AudioClock speedClock;
        speedClock.start(0, 0);
        const auto sSpeed = speedClock.setSpeed(2, 1, 1'000'000'000LL); // 2x at t=1s, re-anchors to 1,000,000
        const int64_t posAt1s = speedClock.currentPositionUs(1'000'000'000LL);
        const int64_t posAt2s = speedClock.currentPositionUs(2'000'000'000LL); // +1s real @2x -> +2,000,000

        const auto sBadZero    = speedClock.setSpeed(0, 1, 2'000'000'000LL);
        const auto sBadTooHigh = speedClock.setSpeed(1001, 1, 2'000'000'000LL);
        const auto sBadNeg     = speedClock.setSpeed(-1, 1, 2'000'000'000LL);
        const int64_t posAfterBadAttempts = speedClock.currentPositionUs(2'000'000'000LL);

        speedMathOk = sSpeed.ok() && posAt1s == 1'000'000 && posAt2s == 3'000'000 &&
            !sBadZero.ok() && !sBadTooHigh.ok() && !sBadNeg.ok() &&
            posAfterBadAttempts == 3'000'000;
        if (!speedMathOk && failureReason.empty()) failureReason = "speed_math_failed";
    }

    // ── 8. monotonicityFuzzOk: nondecreasing sysTimeNs -> nondecreasing position ──
    {
        AudioClock fuzzClock;
        fuzzClock.start(0, 0);
        fuzzClock.setSpeed(3, 2, 0); // 1.5x, re-anchor at t=0 is a no-op position-wise

        uint64_t lcgState = 88172645463325252ull;
        int64_t sysTimeNs = 0;
        int64_t prevPos = fuzzClock.currentPositionUs(sysTimeNs);
        bool monotonic = true;
        constexpr int kFuzzIterations = 5000;

        for (int i = 0; i < kFuzzIterations; ++i) {
            lcgState ^= lcgState << 13;
            lcgState ^= lcgState >> 7;
            lcgState ^= lcgState << 17;
            const int64_t stepNs = static_cast<int64_t>(lcgState % 10'000'000ull); // always >= 0
            sysTimeNs += stepNs;
            const int64_t pos = fuzzClock.currentPositionUs(sysTimeNs);
            if (pos < prevPos) {
                monotonic = false;
                break;
            }
            prevPos = pos;
        }

        fuzzIterations = kFuzzIterations;
        monotonicityFuzzOk = monotonic;
        if (!monotonicityFuzzOk && failureReason.empty()) failureReason = "monotonicity_fuzz_failed";
    }

    // ── 9. overflowSaturationOk ──
    {
        const int64_t satDirect = AudioClock::ScaleNanosToMicros(kInt64Max, 1000, 1);
        const bool satDirectOk = satDirect == kInt64Max;

        AudioClock satClock;
        satClock.start(0, kInt64Max - 10);
        const int64_t satPos = satClock.currentPositionUs(1'000'000'000LL); // would overflow -> saturate
        const bool satClockOk = satPos == kInt64Max;

        const bool noNegativeOk = AudioClock::ScaleNanosToMicros(-1'000'000, 1, 1) == 0;

        overflowSaturationOk = satDirectOk && satClockOk && noNegativeOk;
        if (!overflowSaturationOk && failureReason.empty()) failureReason = "overflow_saturation_failed";
    }

    // ── 10. invalidSpeedRejectOk ──
    {
        AudioClock rangeClock;
        rangeClock.start(0, 0);
        const auto snapBefore = rangeClock.snapshot();

        const auto rZero       = rangeClock.setSpeed(0, 1, 0);
        const auto rNegNum     = rangeClock.setSpeed(-5, 1, 0);
        const auto rNegDen     = rangeClock.setSpeed(1, -5, 0);
        const auto rTooHighNum = rangeClock.setSpeed(1001, 1, 0);
        const auto rTooHighDen = rangeClock.setSpeed(1, 1001, 0);
        const auto snapAfterRejects = rangeClock.snapshot();

        const bool boundaryLowOk  = rangeClock.setSpeed(1, 1000, 0).ok();
        const bool boundaryHighOk = rangeClock.setSpeed(1000, 1, 0).ok();
        const auto snapAfterBoundary = rangeClock.snapshot();

        invalidSpeedRejectOk = !rZero.ok() && !rNegNum.ok() && !rNegDen.ok() &&
            !rTooHighNum.ok() && !rTooHighDen.ok() &&
            snapAfterRejects.speedNumerator == snapBefore.speedNumerator &&
            snapAfterRejects.speedDenominator == snapBefore.speedDenominator &&
            boundaryLowOk && boundaryHighOk &&
            snapAfterBoundary.speedNumerator == 1000 && snapAfterBoundary.speedDenominator == 1;
        if (!invalidSpeedRejectOk && failureReason.empty()) failureReason = "invalid_speed_reject_failed";
    }

    // ── 11. driftTelemetryInertOk ──
    {
        AudioClock driftClock;
        driftClock.start(0, 1'000'000);
        const int64_t posBeforeDrift = driftClock.currentPositionUs(2'000'000'000LL); // 3,000,000
        const auto snapBeforeDrift = driftClock.snapshot();

        const auto dStatus1 = driftClock.recordDriftSample(3'000'000, 3'000'250, 2'000'000'000LL); // delta +250
        const int64_t posAfterDrift1 = driftClock.currentPositionUs(2'000'000'000LL);
        const auto snapAfterDrift1 = driftClock.snapshot();

        const auto dStatus2 = driftClock.recordDriftSample(5'000'000, 4'999'700, 3'000'000'000LL); // delta -300
        const int64_t posAfterDrift2 = driftClock.currentPositionUs(2'000'000'000LL);
        const auto snapAfterDrift2 = driftClock.snapshot();

        // Extreme inputs: reportedPtsUs - expectedPtsUs must saturate rather
        // than invoke signed-overflow undefined behavior.
        const auto dStatus3 = driftClock.recordDriftSample(kInt64Min, kInt64Max, 4'000'000'000LL); // overflows positive -> saturate to max
        const int64_t posAfterDrift3 = driftClock.currentPositionUs(2'000'000'000LL);
        const auto snapAfterDrift3 = driftClock.snapshot();

        const auto dStatus4 = driftClock.recordDriftSample(kInt64Max, kInt64Min, 5'000'000'000LL); // overflows negative -> saturate to min
        const int64_t posAfterDrift4 = driftClock.currentPositionUs(2'000'000'000LL);
        const auto snapAfterDrift4 = driftClock.snapshot();

        driftDeltaUs = snapAfterDrift4.lastDriftDeltaUs;
        driftSampleCount = snapAfterDrift4.driftSampleCount;

        driftTelemetryInertOk = dStatus1.ok() && dStatus2.ok() && dStatus3.ok() && dStatus4.ok() &&
            posBeforeDrift == posAfterDrift1 && posAfterDrift1 == posAfterDrift2 &&
            posAfterDrift2 == posAfterDrift3 && posAfterDrift3 == posAfterDrift4 &&
            snapAfterDrift1.driftSampleCount == snapBeforeDrift.driftSampleCount + 1 &&
            snapAfterDrift1.lastDriftExpectedPtsUs == 3'000'000 &&
            snapAfterDrift1.lastDriftReportedPtsUs == 3'000'250 &&
            snapAfterDrift1.lastDriftDeltaUs == 250 &&
            snapAfterDrift1.anchorMediaPtsUs == snapBeforeDrift.anchorMediaPtsUs &&
            snapAfterDrift1.anchorSystemTimeNs == snapBeforeDrift.anchorSystemTimeNs &&
            snapAfterDrift2.driftSampleCount == snapBeforeDrift.driftSampleCount + 2 &&
            snapAfterDrift2.lastDriftDeltaUs == -300 &&
            snapAfterDrift3.driftSampleCount == snapBeforeDrift.driftSampleCount + 3 &&
            snapAfterDrift3.lastDriftDeltaUs == kInt64Max &&
            snapAfterDrift3.anchorMediaPtsUs == snapBeforeDrift.anchorMediaPtsUs &&
            snapAfterDrift4.driftSampleCount == snapBeforeDrift.driftSampleCount + 4 &&
            snapAfterDrift4.lastDriftDeltaUs == kInt64Min &&
            snapAfterDrift4.anchorMediaPtsUs == snapBeforeDrift.anchorMediaPtsUs;
        if (!driftTelemetryInertOk && failureReason.empty()) failureReason = "drift_telemetry_inert_failed";
    }

    // ── 12. ringSeekCoordinationOk: ring requestSeek -> provide/consume -> AudioClock::seek ──
    int64_t coordPositionAfterSeek = 0;
    {
        constexpr int32_t kRingSampleRate = 48000;
        constexpr int32_t kRingChannels   = 2;
        constexpr int64_t kRingSeekTargetFrame = 500;

        AudioSpscAudioRingBuffer coordRing(kRingSampleRate, kRingChannels, 1024);
        std::vector<int16_t> initialPcm(200 * static_cast<size_t>(kRingChannels), 111);
        coordRing.tryPushFrames(initialPcm.data(), 200);

        RingBufferAudioSampleProvider coordProvider(&coordRing, 0);
        const bool ringSeekRequested = coordRing.requestSeek(kRingSeekTargetFrame);

        std::vector<int16_t> drainOut(10 * static_cast<size_t>(kRingChannels), 0);
        AudioWindowRequest drainReq{kRingSeekTargetFrame, 10, kRingSampleRate, kRingChannels, 0};
        AudioWindowBuffer drainBuf{drainOut.data(), static_cast<int64_t>(drainOut.size()), 0, false};
        const auto drainStatus = coordProvider.provide(drainReq, drainBuf);

        const uint64_t targetPtsUsFromRingFrame =
            (static_cast<uint64_t>(kRingSeekTargetFrame) * 1000000ull) / static_cast<uint64_t>(kRingSampleRate);

        AudioClock coordClock;
        coordClock.start(0, 0);
        constexpr int64_t kSysTimeNsAtCoordSeek = 1'000'000'000LL; // position=1,000,000us, well ahead of target
        const auto coordSeekStatus =
            coordClock.seek(static_cast<int64_t>(targetPtsUsFromRingFrame), kSysTimeNsAtCoordSeek);
        coordPositionAfterSeek = coordClock.currentPositionUs(kSysTimeNsAtCoordSeek);

        ringSeekCoordinationOk = ringSeekRequested && drainStatus.ok() && drainBuf.silent &&
            coordProvider.expectedNextFrame() == kRingSeekTargetFrame + 10 &&
            coordSeekStatus.ok() &&
            coordPositionAfterSeek == static_cast<int64_t>(targetPtsUsFromRingFrame);
        if (!ringSeekCoordinationOk && failureReason.empty()) failureReason = "ring_seek_coordination_failed";
    }

    // ── 13. lifecycleOk ──
    {
        AudioClock lcClock;
        const auto lcStart1 = lcClock.start(0, 0);
        const auto lcStart2 = lcClock.start(100, 100); // start only legal from kStopped
        const bool startDoubleGuardOk = lcStart1.ok() && !lcStart2.ok();

        const auto lcResumeOnPlaying = lcClock.resume(1); // already playing -> no-op success
        const bool resumeOnPlayingNoOpOk = lcResumeOnPlaying.ok();

        AudioClock lcStoppedClock;
        const auto lcPauseStopped = lcStoppedClock.pause(0);
        const auto lcResumeStopped = lcStoppedClock.resume(0);
        const auto lcSeekStopped = lcStoppedClock.seek(0, 0);
        const bool stoppedGuardOk = !lcPauseStopped.ok() && !lcResumeStopped.ok() && !lcSeekStopped.ok();

        const auto lcSetSpeedStopped = lcStoppedClock.setSpeed(2, 1, 0); // legal while stopped
        const bool setSpeedStoppedOk = lcSetSpeedStopped.ok();

        AudioClock lcNegativeStartClock;
        const auto lcNegativeStart = lcNegativeStartClock.start(0, -1); // negative mediaPtsUs rejected, no mutation
        const int64_t posAfterNegativeStartReject = lcNegativeStartClock.currentPositionUs(0);
        const auto lcNegativeStartRetry = lcNegativeStartClock.start(0, 0); // still kStopped, retry succeeds
        const bool negativeStartRejectOk = !lcNegativeStart.ok() && posAfterNegativeStartReject == 0 &&
            lcNegativeStartRetry.ok();

        lifecycleOk = startDoubleGuardOk && resumeOnPlayingNoOpOk && stoppedGuardOk && setSpeedStoppedOk &&
            negativeStartRejectOk;
        if (!lifecycleOk && failureReason.empty()) failureReason = "lifecycle_failed";
    }

    finalPositionUs = coordPositionAfterSeek;

    const bool allPass = audioClockLockFreeOk && clockMathOk && rationalExactnessOk && doubleDivergenceOk &&
                         playPauseResumeOk && seekOk && speedMathOk && monotonicityFuzzOk &&
                         overflowSaturationOk && invalidSpeedRejectOk && driftTelemetryInertOk &&
                         ringSeekCoordinationOk && lifecycleOk && stackScoped;

    std::ostringstream oss;
    oss << "status=" << (allPass ? "PASS" : "FAIL") << ";";
    if (!allPass) {
        oss << "reason=" << (failureReason.empty() ? "unknown_failure" : failureReason) << ";";
    }
    oss << "proofBoundary=" << kProofBoundary << ";"
        << "audioClockLockFreeOk=" << (audioClockLockFreeOk ? "true" : "false") << ";"
        << "clockMathOk=" << (clockMathOk ? "true" : "false") << ";"
        << "rationalExactnessOk=" << (rationalExactnessOk ? "true" : "false") << ";"
        << "doubleDivergenceOk=" << (doubleDivergenceOk ? "true" : "false") << ";"
        << "playPauseResumeOk=" << (playPauseResumeOk ? "true" : "false") << ";"
        << "seekOk=" << (seekOk ? "true" : "false") << ";"
        << "speedMathOk=" << (speedMathOk ? "true" : "false") << ";"
        << "monotonicityFuzzOk=" << (monotonicityFuzzOk ? "true" : "false") << ";"
        << "overflowSaturationOk=" << (overflowSaturationOk ? "true" : "false") << ";"
        << "invalidSpeedRejectOk=" << (invalidSpeedRejectOk ? "true" : "false") << ";"
        << "driftTelemetryInertOk=" << (driftTelemetryInertOk ? "true" : "false") << ";"
        << "ringSeekCoordinationOk=" << (ringSeekCoordinationOk ? "true" : "false") << ";"
        << "lifecycleOk=" << (lifecycleOk ? "true" : "false") << ";"
        << "stackScoped=" << (stackScoped ? "true" : "false") << ";"
        << "finalPositionUs=" << finalPositionUs << ";"
        << "pausedPositionUs=" << pausedPositionUs << ";"
        << "resumedPositionUs=" << resumedPositionUs << ";"
        << "seekPositionUs=" << seekPositionUs << ";"
        << "driftDeltaUs=" << driftDeltaUs << ";"
        << "driftSampleCount=" << driftSampleCount << ";"
        << "fuzzIterations=" << fuzzIterations;

    return oss.str();
}

} // namespace

extern "C" JNIEXPORT jstring JNICALL
Java_com_connects_vanguard_1media_1engine_bridge_VanguardNativeBridge_runAndroidDagPhase4AudioClockSmoke(
    JNIEnv* env,
    jobject /* this */) {
    try {
        const std::string resultStr = RunAudioClockSmokeInternal();
        return env->NewStringUTF(resultStr.c_str());
    } catch (const std::exception& e) {
        const std::string err =
            std::string("status=FAIL;reason=exception:") + e.what() + ";proofBoundary=" + kProofBoundary;
        return env->NewStringUTF(err.c_str());
    } catch (...) {
        const std::string err =
            std::string("status=FAIL;reason=exception:unknown;proofBoundary=") + kProofBoundary;
        return env->NewStringUTF(err.c_str());
    }
}
