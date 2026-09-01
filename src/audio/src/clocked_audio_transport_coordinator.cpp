#include "vanguard/audio/clocked_audio_transport_coordinator.h"

#include <cstdint>
#include <limits>

namespace vanguard {
namespace audio {

namespace {
constexpr int64_t kInt64Max = std::numeric_limits<int64_t>::max();
constexpr int64_t kMicrosPerSecond = 1'000'000LL;
} // namespace

ClockedAudioTransportCoordinator::ClockedAudioTransportCoordinator(
    AudioClock& clock,
    GraphAudioScheduler& scheduler,
    AudioSpscAudioRingBuffer& outputRing)
    : clock_(clock),
      scheduler_(scheduler),
      ring_(outputRing) {

    sampleRate_      = scheduler_.sampleRate();
    channelCount_     = scheduler_.channelCount();
    maxFramesPerMix_  = scheduler_.maxFramesPerMix();

    configOk_ = sampleRate_ > 0 && channelCount_ > 0 && maxFramesPerMix_ > 0 &&
                sampleRate_ == ring_.sampleRate() && channelCount_ == ring_.channelCount() &&
                ring_.capacityFrames() >= maxFramesPerMix_;

    int64_t scratchSamples = 0;
    if (configOk_) {
        constexpr int64_t kInt64Max = std::numeric_limits<int64_t>::max();
        constexpr size_t  kSizeMax  = std::numeric_limits<size_t>::max();
        if (maxFramesPerMix_ > kInt64Max / static_cast<int64_t>(channelCount_)) {
            configOk_ = false;
        } else {
            scratchSamples = maxFramesPerMix_ * static_cast<int64_t>(channelCount_);
            if (static_cast<uint64_t>(scratchSamples) > static_cast<uint64_t>(kSizeMax)) {
                configOk_ = false;
                scratchSamples = 0;
            }
        }
    }

    scratch_.assign(configOk_ ? static_cast<size_t>(scratchSamples) : 0u, 0);
}

int64_t ClockedAudioTransportCoordinator::frameOfPositionUs(int64_t mediaPtsUs,
                                                              int32_t sampleRate) noexcept {
    if (mediaPtsUs <= 0 || sampleRate <= 0) {
        return 0;
    }

    const int64_t seconds     = mediaPtsUs / kMicrosPerSecond;
    const int64_t remainderUs = mediaPtsUs % kMicrosPerSecond;

    int64_t secondsFrames;
    if (seconds != 0 && seconds > kInt64Max / static_cast<int64_t>(sampleRate)) {
        secondsFrames = kInt64Max;
    } else {
        secondsFrames = seconds * static_cast<int64_t>(sampleRate);
    }

    // remainderUs < 1,000,000 and sampleRate <= INT32_MAX: this product
    // never exceeds ~2.1e15, well within int64 range.
    const int64_t remainderFrames =
        (remainderUs * static_cast<int64_t>(sampleRate)) / kMicrosPerSecond;

    if (secondsFrames > kInt64Max - remainderFrames) {
        return kInt64Max;
    }
    return secondsFrames + remainderFrames;
}

core::Status ClockedAudioTransportCoordinator::start(int64_t mediaPtsUs, int64_t sysTimeNs) noexcept {
    if (!configOk_) {
        return core::Status(core::StatusCode::kError, "invalid_configuration");
    }

    const core::Status status = clock_.start(sysTimeNs, mediaPtsUs);
    if (!status.ok()) {
        return status;
    }

    const int64_t targetFrame = frameOfPositionUs(mediaPtsUs, sampleRate_);
    if (!ring_.requestSeek(targetFrame)) {
        return core::Status(core::StatusCode::kError, "output_ring_seek_rejected");
    }
    nextDispatchFrame_      = targetFrame;
    lastDispatchSysTimeNs_  = sysTimeNs;
    terminal_               = false;
    return status;
}

core::Status ClockedAudioTransportCoordinator::pause(int64_t sysTimeNs) noexcept {
    if (!configOk_) {
        return core::Status(core::StatusCode::kError, "invalid_configuration");
    }
    return clock_.pause(sysTimeNs);
}

core::Status ClockedAudioTransportCoordinator::resume(int64_t sysTimeNs) noexcept {
    if (!configOk_) {
        return core::Status(core::StatusCode::kError, "invalid_configuration");
    }
    return clock_.resume(sysTimeNs);
}

core::Status ClockedAudioTransportCoordinator::seek(int64_t targetPtsUs, int64_t sysTimeNs) noexcept {
    if (!configOk_) {
        return core::Status(core::StatusCode::kError, "invalid_configuration");
    }

    const core::Status status = clock_.seek(targetPtsUs, sysTimeNs);
    if (!status.ok()) {
        return status;
    }

    const int64_t targetFrame = frameOfPositionUs(targetPtsUs, sampleRate_);
    if (!ring_.requestSeek(targetFrame)) {
        return core::Status(core::StatusCode::kError, "output_ring_seek_rejected");
    }
    nextDispatchFrame_ = targetFrame;
    return status;
}

ClockedAudioTransportCoordinator::DispatchResult ClockedAudioTransportCoordinator::failClosed(
    DispatchResult result, DispatchOutput* outResult) const noexcept {
    (void)outResult;
    return result;
}

ClockedAudioTransportCoordinator::DispatchResult ClockedAudioTransportCoordinator::dispatchUntil(
    int64_t sysTimeNs, DispatchOutput* outResult) noexcept {

    if (outResult != nullptr) {
        *outResult = DispatchOutput{};
    }

    if (!configOk_) {
        lastResult_ = DispatchResult::kInvalidConfiguration;
        return failClosed(DispatchResult::kInvalidConfiguration, outResult);
    }

    if (terminal_) {
        lastResult_ = DispatchResult::kRingPushShortfall;
        return failClosed(DispatchResult::kRingPushShortfall, outResult);
    }

    if (sysTimeNs < lastDispatchSysTimeNs_) {
        lastResult_ = DispatchResult::kNonMonotonicTime;
        return failClosed(DispatchResult::kNonMonotonicTime, outResult);
    }
    lastDispatchSysTimeNs_ = sysTimeNs;

    const AudioClock::Snapshot clockSnap = clock_.snapshot();
    if (clockSnap.state == AudioClock::State::kStopped) {
        lastResult_ = DispatchResult::kNotStarted;
        return failClosed(DispatchResult::kNotStarted, outResult);
    }
    if (clockSnap.state == AudioClock::State::kPaused) {
        lastResult_ = DispatchResult::kPaused;
        return failClosed(DispatchResult::kPaused, outResult);
    }
    if (clockSnap.speedNumerator != clockSnap.speedDenominator) {
        lastResult_ = DispatchResult::kNonUnitySpeed;
        return failClosed(DispatchResult::kNonUnitySpeed, outResult);
    }

    if (ring_.seekRequest() != ring_.seekAck()) {
        lastResult_ = DispatchResult::kAwaitingSeekAck;
        return failClosed(DispatchResult::kAwaitingSeekAck, outResult);
    }

    const int64_t mediaPositionUs = clock_.currentPositionUs(sysTimeNs);
    lastMediaPositionUs_ = mediaPositionUs;
    const int64_t currentFrame = frameOfPositionUs(mediaPositionUs, sampleRate_);

    const int64_t framesDue = currentFrame - nextDispatchFrame_;
    if (framesDue <= 0) {
        lastResult_ = DispatchResult::kNoFramesDue;
        return failClosed(DispatchResult::kNoFramesDue, outResult);
    }

    const int64_t framesThisWindow = framesDue < maxFramesPerMix_ ? framesDue : maxFramesPerMix_;

    if (outResult != nullptr) {
        outResult->framesDue = framesDue;
    }

    const int64_t availableWrite = ring_.availableWriteFrames();
    if (availableWrite < framesThisWindow) {
        ++backpressureCount_;
        lastResult_ = DispatchResult::kBackpressure;
        return failClosed(DispatchResult::kBackpressure, outResult);
    }

    GraphAudioScheduler::SchedulerOutput schedOut{};
    const GraphAudioScheduler::SchedulerResult schedResult = scheduler_.renderWindow(
        nextDispatchFrame_, framesThisWindow, scratch_.data(),
        static_cast<int64_t>(scratch_.size()), &schedOut);

    if (schedResult != GraphAudioScheduler::SchedulerResult::kOk &&
        schedResult != GraphAudioScheduler::SchedulerResult::kSilence) {
        ++schedulerErrorCount_;
        lastResult_ = DispatchResult::kSchedulerError;
        return failClosed(DispatchResult::kSchedulerError, outResult);
    }

    const int64_t framesRendered = schedOut.framesRendered;
    const int64_t framesPushed   = ring_.tryPushFrames(scratch_.data(), framesRendered);

    if (framesPushed != framesRendered) {
        terminal_ = true;
        lastResult_ = DispatchResult::kRingPushShortfall;
        return failClosed(DispatchResult::kRingPushShortfall, outResult);
    }

    nextDispatchFrame_ += framesRendered;
    totalFramesRendered_ += framesRendered;
    totalFramesPushed_   += framesPushed;
    ++dispatchCount_;

    const bool silence = schedResult == GraphAudioScheduler::SchedulerResult::kSilence;
    if (silence) {
        ++silenceCount_;
    } else {
        ++okCount_;
    }

    if (outResult != nullptr) {
        outResult->framesRendered     = framesRendered;
        outResult->framesPushed       = framesPushed;
        outResult->nextDispatchFrame  = nextDispatchFrame_;
        outResult->checksum           = schedOut.checksum;
        outResult->silence            = silence;
        outResult->envelopeApplied     = schedOut.envelopeApplied;
        outResult->minEffectiveGain    = schedOut.minEffectiveGain;
        outResult->maxEffectiveGain    = schedOut.maxEffectiveGain;
        outResult->envelopeEvaluations = schedOut.envelopeEvaluations;
    }

    lastResult_ = silence ? DispatchResult::kSilence : DispatchResult::kOk;
    return lastResult_;
}

ClockedAudioTransportCoordinator::Snapshot ClockedAudioTransportCoordinator::snapshot() const noexcept {
    Snapshot snap;
    snap.lastResult          = lastResult_;
    snap.nextDispatchFrame   = nextDispatchFrame_;
    snap.lastMediaPositionUs = lastMediaPositionUs_;
    snap.totalFramesRendered = totalFramesRendered_;
    snap.totalFramesPushed   = totalFramesPushed_;
    snap.dispatchCount       = dispatchCount_;
    snap.okCount             = okCount_;
    snap.silenceCount        = silenceCount_;
    snap.backpressureCount   = backpressureCount_;
    snap.schedulerErrorCount = schedulerErrorCount_;
    snap.awaitingSeekAck     = ring_.seekRequest() != ring_.seekAck();
    snap.terminal            = terminal_;
    return snap;
}

} // namespace audio
} // namespace vanguard
