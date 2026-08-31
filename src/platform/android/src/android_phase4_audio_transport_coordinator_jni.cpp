// P4-AUDIO-GRAPH-TRANSPORT-CLOCK sub-slice D: single-threaded
// clock-driven -> scheduler -> output-ring transport coordinator native
// proof.
//
// Honest non-claims:
// - Does not claim realtime or audible playback.
// - Does not use AudioTrack, AAudio, OpenSL, or Oboe.
// - Does not spawn threads or register callbacks.
// - Does not read any internal wall clock; every AudioClock/coordinator
//   call below is fed an explicit, caller-chosen sysTimeNs.
// - Does not implement resampling or a speed API.
// - Does not seek any source ring; ClockedAudioTransportCoordinator only
//   ever calls requestSeek() on its own output ring, never
//   consumePendingSeekOnReaderThread() (this translation unit plays the
//   output ring's reader role directly to simulate the seek-ack
//   handshake).
// - Does not touch iOS or product/editor UI.
// - Does not close P4-AUDIO-GRAPH-TRANSPORT-CLOCK.
//
// This translation unit is Android-only and must NOT be included in iOS or
// host builds; it is added via the Android-only target_sources block in
// src/CMakeLists.txt.
//
// JNI entry point:
//   runAndroidDagPhase4AudioTransportCoordinatorSmoke -> jstring

#include <jni.h>

#include <cstdint>
#include <limits>
#include <memory>
#include <sstream>
#include <string>
#include <unordered_map>
#include <vector>

#include "vanguard/audio/audio_clock.h"
#include "vanguard/audio/audio_mix_bus_node.h"
#include "vanguard/audio/audio_ring_buffer.h"
#include "vanguard/audio/audio_sample_provider.h"
#include "vanguard/audio/clocked_audio_transport_coordinator.h"
#include "vanguard/audio/decoded_audio_pcm_source_node.h"
#include "vanguard/audio/graph_audio_scheduler.h"
#include "vanguard/audio/vector_audio_sample_provider.h"
#include "vanguard/graph/graph.h"

namespace {

constexpr const char* kProofBoundary =
    "native_clock_driven_audio_transport_coordinator_proof_only_no_audio_track_no_os_callback_no_decoder_writer_no_export_reroute_no_streaming_no_ios_no_product_no_internal_wall_clock_read_no_threads_no_locks_no_float_timebase_no_resample_no_speed_change_no_source_provider_ring_seek_output_ring_only_unity_speed_only";

using vanguard::audio::AudioClock;
using vanguard::audio::AudioMixBusNode;
using vanguard::audio::AudioSampleProvider;
using vanguard::audio::AudioSpscAudioRingBuffer;
using vanguard::audio::ClockedAudioTransportCoordinator;
using vanguard::audio::DecodedAudioPcmSourceNode;
using vanguard::audio::GraphAudioScheduler;
using vanguard::audio::VectorAudioSampleProvider;
using vanguard::core::Status;
using vanguard::graph::Graph;
using DispatchResult = ClockedAudioTransportCoordinator::DispatchResult;
using DispatchOutput = ClockedAudioTransportCoordinator::DispatchOutput;

constexpr int64_t kInt64Max = std::numeric_limits<int64_t>::max();

// Builds a small deterministic non-zero PCM signal covering `frameCount`
// frames so scheduler mixes are non-silent when the requested window
// overlaps it.
std::vector<int16_t> MakeSignal(int64_t frameCount, int32_t channelCount) {
    std::vector<int16_t> pcm(static_cast<size_t>(frameCount) * static_cast<size_t>(channelCount));
    for (int64_t f = 0; f < frameCount; ++f) {
        const int16_t s = static_cast<int16_t>(((f * 37) % 4001) - 2000);
        for (int32_t ch = 0; ch < channelCount; ++ch) {
            pcm[static_cast<size_t>(f) * channelCount + ch] = s;
        }
    }
    return pcm;
}

std::string RunAudioTransportCoordinatorSmokeInternal() {
    bool coordinatorConstructorValidationOk = false;
    bool startAwaitAckGateOk                = false;
    bool clockDrivenDispatchOk              = false;
    bool boundedCatchUpOk                   = false;
    bool backpressureNoClockMutationOk      = false;
    bool pauseResumeNoDispatchOk            = false;
    bool seekAwaitAckGateOk                 = false;
    bool silenceWindowPushedOk              = false;
    bool schedulerErrorNoCursorAdvanceOk    = false;
    bool nonUnitySpeedRejectOk              = false;
    bool frameConversionOverflowOk          = false;
    bool noSteadyStateAllocationOk          = false;
    bool lifecycleOk                        = false;
    bool stackScoped                        = true;

    std::string failureReason;

    int64_t  metricClockDrivenFramesRendered = 0;
    int64_t  metricBoundedCatchUpCalls       = 0;
    int64_t  metricBoundedCatchUpTotalFrames = 0;
    int64_t  metricSilenceFramesPushed       = 0;
    int64_t  metricFrameOfPositionSaturated  = 0;

    constexpr int32_t kSampleRate      = 8000;
    constexpr int32_t kChannels        = 1;
    constexpr int64_t kMaxFramesPerMix = 256;

    // -- 1. coordinatorConstructorValidationOk --
    {
        Graph graph;
        auto mix = std::make_shared<AudioMixBusNode>("ctc_mix1", kSampleRate, kChannels, kMaxFramesPerMix);
        auto src = std::make_shared<DecodedAudioPcmSourceNode>("ctc_src1", kSampleRate, kChannels, 4800, 0);
        graph.addNode(mix);
        graph.addNode(src);
        graph.connect("ctc_src1", "audio_out", "ctc_mix1", "primary_audio_in");

        VectorAudioSampleProvider provider(kSampleRate, kChannels, 0, MakeSignal(2000, kChannels));
        std::unordered_map<std::string, AudioSampleProvider*> providers = {{"ctc_src1", &provider}};
        GraphAudioScheduler scheduler(graph, "ctc_mix1", providers);

        AudioClock clock;
        AudioSpscAudioRingBuffer matchedRing(kSampleRate, kChannels, 1024);
        ClockedAudioTransportCoordinator validCoordinator(clock, scheduler, matchedRing);
        DispatchOutput validOut;
        const DispatchResult validPreStart = validCoordinator.dispatchUntil(0, &validOut);

        // Mismatched channel count between scheduler (kChannels) and output ring.
        AudioSpscAudioRingBuffer mismatchedRing(kSampleRate, kChannels == 1 ? 2 : 1, 1024);
        AudioClock badClock;
        ClockedAudioTransportCoordinator invalidCoordinator(badClock, scheduler, mismatchedRing);
        const Status badStart = invalidCoordinator.start(0, 0);
        DispatchOutput invalidOut;
        const DispatchResult invalidDispatch = invalidCoordinator.dispatchUntil(0, &invalidOut);
        const bool ringUntouched = mismatchedRing.seekRequest() == 0;

        coordinatorConstructorValidationOk = validPreStart == DispatchResult::kNotStarted &&
            !badStart.ok() && invalidDispatch == DispatchResult::kInvalidConfiguration &&
            invalidOut.framesRendered == 0 && ringUntouched;
        if (!coordinatorConstructorValidationOk && failureReason.empty()) {
            failureReason = "coordinator_constructor_validation_failed";
        }
    }

    // -- 2. startAwaitAckGateOk / 3. clockDrivenDispatchOk (shared rig) --
    int64_t sharedNextFrameAfterFirstDispatch = 0;
    {
        Graph graph;
        auto mix = std::make_shared<AudioMixBusNode>("ctc_mix2", kSampleRate, kChannels, kMaxFramesPerMix);
        auto src = std::make_shared<DecodedAudioPcmSourceNode>("ctc_src2", kSampleRate, kChannels, 4800, 0);
        graph.addNode(mix);
        graph.addNode(src);
        graph.connect("ctc_src2", "audio_out", "ctc_mix2", "primary_audio_in");

        VectorAudioSampleProvider provider(kSampleRate, kChannels, 0, MakeSignal(4000, kChannels));
        std::unordered_map<std::string, AudioSampleProvider*> providers = {{"ctc_src2", &provider}};
        GraphAudioScheduler scheduler(graph, "ctc_mix2", providers);

        AudioClock clock;
        AudioSpscAudioRingBuffer ring(kSampleRate, kChannels, 2048);
        ClockedAudioTransportCoordinator coordinator(clock, scheduler, ring);

        const Status startStatus = coordinator.start(0, 0);
        DispatchOutput preAckOut;
        const DispatchResult preAckResult = coordinator.dispatchUntil(10'000'000, &preAckOut);

        int64_t ackedFrame = -1;
        const bool ackConsumed = ring.consumePendingSeekOnReaderThread(&ackedFrame);

        DispatchOutput dispatchOut;
        const DispatchResult dispatchResult = coordinator.dispatchUntil(10'000'000, &dispatchOut);
        const auto snap = coordinator.snapshot();

        metricClockDrivenFramesRendered = dispatchOut.framesRendered;
        sharedNextFrameAfterFirstDispatch = snap.nextDispatchFrame;

        startAwaitAckGateOk = startStatus.ok() && preAckResult == DispatchResult::kAwaitingSeekAck &&
            preAckOut.framesRendered == 0 && ackConsumed && ackedFrame == 0;
        if (!startAwaitAckGateOk && failureReason.empty()) failureReason = "start_await_ack_gate_failed";

        clockDrivenDispatchOk = dispatchResult == DispatchResult::kOk &&
            dispatchOut.framesRendered == 80 && dispatchOut.framesPushed == 80 &&
            snap.nextDispatchFrame == 80 && !snap.awaitingSeekAck;
        if (!clockDrivenDispatchOk && failureReason.empty()) failureReason = "clock_driven_dispatch_failed";
    }

    // -- 4. boundedCatchUpOk --
    {
        Graph graph;
        auto mix = std::make_shared<AudioMixBusNode>("ctc_mix3", kSampleRate, kChannels, kMaxFramesPerMix);
        auto src = std::make_shared<DecodedAudioPcmSourceNode>("ctc_src3", kSampleRate, kChannels, 4800, 0);
        graph.addNode(mix);
        graph.addNode(src);
        graph.connect("ctc_src3", "audio_out", "ctc_mix3", "primary_audio_in");

        VectorAudioSampleProvider provider(kSampleRate, kChannels, 0, MakeSignal(4000, kChannels));
        std::unordered_map<std::string, AudioSampleProvider*> providers = {{"ctc_src3", &provider}};
        GraphAudioScheduler scheduler(graph, "ctc_mix3", providers);

        AudioClock clock;
        AudioSpscAudioRingBuffer ring(kSampleRate, kChannels, 4096);
        ClockedAudioTransportCoordinator coordinator(clock, scheduler, ring);

        coordinator.start(0, 0);
        int64_t ackedFrame = -1;
        ring.consumePendingSeekOnReaderThread(&ackedFrame);

        constexpr int64_t kTargetSysTimeNs = 200'000'000LL; // 200ms -> 1600 frames due @8kHz
        bool everCapped = false;
        bool allWindowsBounded = true;
        int64_t calls = 0;
        int64_t totalRendered = 0;
        DispatchResult lastResult = DispatchResult::kNoFramesDue;
        while (calls < 20) {
            DispatchOutput out;
            lastResult = coordinator.dispatchUntil(kTargetSysTimeNs, &out);
            if (lastResult == DispatchResult::kNoFramesDue) {
                break;
            }
            if (lastResult != DispatchResult::kOk) {
                allWindowsBounded = false;
                break;
            }
            if (out.framesRendered > kMaxFramesPerMix) {
                allWindowsBounded = false;
            }
            if (out.framesDue > kMaxFramesPerMix) {
                everCapped = true;
            }
            totalRendered += out.framesRendered;
            ++calls;
        }

        metricBoundedCatchUpCalls       = calls;
        metricBoundedCatchUpTotalFrames = totalRendered;

        boundedCatchUpOk = everCapped && allWindowsBounded && totalRendered == 1600 &&
            lastResult == DispatchResult::kNoFramesDue && calls == 7; // ceil(1600/256)
        if (!boundedCatchUpOk && failureReason.empty()) failureReason = "bounded_catch_up_failed";
    }

    // -- 5. backpressureNoClockMutationOk --
    {
        Graph graph;
        auto mix = std::make_shared<AudioMixBusNode>("ctc_mix4", kSampleRate, kChannels, kMaxFramesPerMix);
        auto src = std::make_shared<DecodedAudioPcmSourceNode>("ctc_src4", kSampleRate, kChannels, 4800, 0);
        graph.addNode(mix);
        graph.addNode(src);
        graph.connect("ctc_src4", "audio_out", "ctc_mix4", "primary_audio_in");

        VectorAudioSampleProvider provider(kSampleRate, kChannels, 0, MakeSignal(4000, kChannels));
        std::unordered_map<std::string, AudioSampleProvider*> providers = {{"ctc_src4", &provider}};
        GraphAudioScheduler scheduler(graph, "ctc_mix4", providers);

        AudioClock clock;
        // Capacity must be >= kMaxFramesPerMix (constructor invariant); the
        // backpressure condition below is instead induced by pre-filling
        // the ring so its free space is < 80 frames.
        AudioSpscAudioRingBuffer tinyRing(kSampleRate, kChannels, kMaxFramesPerMix);
        ClockedAudioTransportCoordinator coordinator(clock, scheduler, tinyRing);

        coordinator.start(0, 0);
        int64_t ackedFrame = -1;
        tinyRing.consumePendingSeekOnReaderThread(&ackedFrame);

        std::vector<int16_t> filler(static_cast<size_t>(kMaxFramesPerMix - 56) * kChannels, 0);
        tinyRing.tryPushFrames(filler.data(), kMaxFramesPerMix - 56); // leaves 56 free (< 80 due)

        constexpr int64_t kBackpressureSysTimeNs = 10'000'000LL; // 10ms -> 80 frames due
        const int64_t posBefore = clock.currentPositionUs(kBackpressureSysTimeNs);

        DispatchOutput out1;
        const DispatchResult res1 = coordinator.dispatchUntil(kBackpressureSysTimeNs, &out1);
        const auto snap1 = coordinator.snapshot();

        DispatchOutput out2;
        const DispatchResult res2 = coordinator.dispatchUntil(kBackpressureSysTimeNs, &out2);
        const auto snap2 = coordinator.snapshot();

        const int64_t posAfter = clock.currentPositionUs(kBackpressureSysTimeNs);

        backpressureNoClockMutationOk = res1 == DispatchResult::kBackpressure && out1.framesDue == 80 &&
            res2 == DispatchResult::kBackpressure && out2.framesDue == 80 &&
            snap1.nextDispatchFrame == 0 && snap2.nextDispatchFrame == 0 &&
            snap1.backpressureCount == 1 && snap2.backpressureCount == 2 &&
            posBefore == posAfter;
        if (!backpressureNoClockMutationOk && failureReason.empty()) failureReason = "backpressure_no_clock_mutation_failed";
    }

    // -- 6. pauseResumeNoDispatchOk --
    {
        Graph graph;
        auto mix = std::make_shared<AudioMixBusNode>("ctc_mix5", kSampleRate, kChannels, kMaxFramesPerMix);
        auto src = std::make_shared<DecodedAudioPcmSourceNode>("ctc_src5", kSampleRate, kChannels, 4800, 0);
        graph.addNode(mix);
        graph.addNode(src);
        graph.connect("ctc_src5", "audio_out", "ctc_mix5", "primary_audio_in");

        VectorAudioSampleProvider provider(kSampleRate, kChannels, 0, MakeSignal(4000, kChannels));
        std::unordered_map<std::string, AudioSampleProvider*> providers = {{"ctc_src5", &provider}};
        GraphAudioScheduler scheduler(graph, "ctc_mix5", providers);

        AudioClock clock;
        AudioSpscAudioRingBuffer ring(kSampleRate, kChannels, 2048);
        ClockedAudioTransportCoordinator coordinator(clock, scheduler, ring);

        coordinator.start(0, 0);
        int64_t ackedFrame = -1;
        ring.consumePendingSeekOnReaderThread(&ackedFrame);

        const Status pauseStatus = coordinator.pause(0);
        DispatchOutput pausedOut;
        const DispatchResult pausedResult = coordinator.dispatchUntil(50'000'000, &pausedOut);
        const auto snapPaused = coordinator.snapshot();

        const Status resumeStatus = coordinator.resume(50'000'000);
        DispatchOutput resumedOut;
        const DispatchResult resumedResult = coordinator.dispatchUntil(60'000'000, &resumedOut);

        pauseResumeNoDispatchOk = pauseStatus.ok() && pausedResult == DispatchResult::kPaused &&
            pausedOut.framesRendered == 0 && snapPaused.nextDispatchFrame == 0 &&
            resumeStatus.ok() && resumedResult == DispatchResult::kOk && resumedOut.framesRendered > 0;
        if (!pauseResumeNoDispatchOk && failureReason.empty()) failureReason = "pause_resume_no_dispatch_failed";
    }

    // -- 7. seekAwaitAckGateOk --
    {
        Graph graph;
        auto mix = std::make_shared<AudioMixBusNode>("ctc_mix6", kSampleRate, kChannels, kMaxFramesPerMix);
        auto src = std::make_shared<DecodedAudioPcmSourceNode>("ctc_src6", kSampleRate, kChannels, 4800, 0);
        graph.addNode(mix);
        graph.addNode(src);
        graph.connect("ctc_src6", "audio_out", "ctc_mix6", "primary_audio_in");

        VectorAudioSampleProvider provider(kSampleRate, kChannels, 0, MakeSignal(6000, kChannels));
        std::unordered_map<std::string, AudioSampleProvider*> providers = {{"ctc_src6", &provider}};
        GraphAudioScheduler scheduler(graph, "ctc_mix6", providers);

        AudioClock clock;
        AudioSpscAudioRingBuffer ring(kSampleRate, kChannels, 4096);
        ClockedAudioTransportCoordinator coordinator(clock, scheduler, ring);

        coordinator.start(0, 0);
        int64_t ackedFrame = -1;
        ring.consumePendingSeekOnReaderThread(&ackedFrame);
        DispatchOutput firstOut;
        coordinator.dispatchUntil(10'000'000, &firstOut); // advances cursor to 80

        const Status seekStatus = coordinator.seek(500'000, 20'000'000); // -> frame 4000
        const auto snapAfterSeek = coordinator.snapshot();

        DispatchOutput awaitOut;
        const DispatchResult awaitResult = coordinator.dispatchUntil(20'000'000, &awaitOut);

        int64_t seekAckedFrame = -1;
        const bool seekAckConsumed = ring.consumePendingSeekOnReaderThread(&seekAckedFrame);

        DispatchOutput postSeekOut;
        const DispatchResult postSeekResult = coordinator.dispatchUntil(20'125'000, &postSeekOut);

        seekAwaitAckGateOk = seekStatus.ok() && snapAfterSeek.nextDispatchFrame == 4000 &&
            awaitResult == DispatchResult::kAwaitingSeekAck && awaitOut.framesRendered == 0 &&
            seekAckConsumed && seekAckedFrame == 4000 &&
            postSeekResult == DispatchResult::kOk && postSeekOut.framesRendered == 1;
        if (!seekAwaitAckGateOk && failureReason.empty()) failureReason = "seek_await_ack_gate_failed";
    }

    // -- 8. silenceWindowPushedOk --
    {
        Graph graph;
        auto mix = std::make_shared<AudioMixBusNode>("ctc_mix7", kSampleRate, kChannels, kMaxFramesPerMix);
        auto src = std::make_shared<DecodedAudioPcmSourceNode>("ctc_src7", kSampleRate, kChannels, 4800, 0);
        graph.addNode(mix);
        graph.addNode(src);
        graph.connect("ctc_src7", "audio_out", "ctc_mix7", "primary_audio_in");

        // Content lives far past the dispatch window: every provide() call
        // for frames [0, 80) reports silence (no overlap).
        VectorAudioSampleProvider provider(kSampleRate, kChannels, 0, MakeSignal(10, kChannels));
        std::unordered_map<std::string, AudioSampleProvider*> providers = {{"ctc_src7", &provider}};
        GraphAudioScheduler scheduler(graph, "ctc_mix7", providers);

        AudioClock clock;
        AudioSpscAudioRingBuffer ring(kSampleRate, kChannels, 2048);
        ClockedAudioTransportCoordinator coordinator(clock, scheduler, ring);

        coordinator.start(4'000'000, 0); // media pts far past provider content (10 frames)
        int64_t ackedFrame = -1;
        ring.consumePendingSeekOnReaderThread(&ackedFrame);

        DispatchOutput out;
        const DispatchResult result = coordinator.dispatchUntil(10'000'000, &out);

        std::vector<int16_t> popped(80 * kChannels, 111);
        const int64_t poppedFrames = ring.tryPopFrames(popped.data(), 80);
        bool allZero = true;
        for (int16_t v : popped) {
            if (v != 0) allZero = false;
        }

        metricSilenceFramesPushed = out.framesPushed;

        silenceWindowPushedOk = result == DispatchResult::kSilence && out.framesRendered == 80 &&
            out.framesPushed == 80 && out.silence && poppedFrames == 80 && allZero;
        if (!silenceWindowPushedOk && failureReason.empty()) failureReason = "silence_window_pushed_failed";
    }

    // -- 9. schedulerErrorNoCursorAdvanceOk --
    {
        Graph graph;
        auto mix = std::make_shared<AudioMixBusNode>("ctc_mix8", kSampleRate, kChannels, kMaxFramesPerMix);
        auto src = std::make_shared<DecodedAudioPcmSourceNode>("ctc_src8", kSampleRate, kChannels, 4800, 0);
        graph.addNode(mix);
        graph.addNode(src);
        graph.connect("ctc_src8", "audio_out", "ctc_mix8", "primary_audio_in");

        VectorAudioSampleProvider provider(kSampleRate, kChannels, 0, MakeSignal(4000, kChannels));
        std::unordered_map<std::string, AudioSampleProvider*> providers = {{"ctc_src8", &provider}};
        GraphAudioScheduler scheduler(graph, "ctc_mix8", providers);

        AudioClock clock;
        AudioSpscAudioRingBuffer ring(kSampleRate, kChannels, 2048);
        ClockedAudioTransportCoordinator coordinator(clock, scheduler, ring);

        coordinator.start(0, 0);
        int64_t ackedFrame = -1;
        ring.consumePendingSeekOnReaderThread(&ackedFrame);

        // Stale the scheduler's snapshotted generation without altering
        // routing, forcing renderWindow() -> kStaleGeneration.
        graph.bumpGeneration();

        const int64_t readableBefore = ring.availableReadFrames();
        DispatchOutput out;
        const DispatchResult result = coordinator.dispatchUntil(10'000'000, &out);
        const auto snap = coordinator.snapshot();
        const int64_t readableAfter = ring.availableReadFrames();

        schedulerErrorNoCursorAdvanceOk = result == DispatchResult::kSchedulerError &&
            out.framesRendered == 0 && out.framesPushed == 0 &&
            snap.nextDispatchFrame == 0 && snap.schedulerErrorCount == 1 &&
            readableBefore == readableAfter;
        if (!schedulerErrorNoCursorAdvanceOk && failureReason.empty()) failureReason = "scheduler_error_no_cursor_advance_failed";
    }

    // -- 10. nonUnitySpeedRejectOk --
    {
        Graph graph;
        auto mix = std::make_shared<AudioMixBusNode>("ctc_mix9", kSampleRate, kChannels, kMaxFramesPerMix);
        auto src = std::make_shared<DecodedAudioPcmSourceNode>("ctc_src9", kSampleRate, kChannels, 4800, 0);
        graph.addNode(mix);
        graph.addNode(src);
        graph.connect("ctc_src9", "audio_out", "ctc_mix9", "primary_audio_in");

        VectorAudioSampleProvider provider(kSampleRate, kChannels, 0, MakeSignal(4000, kChannels));
        std::unordered_map<std::string, AudioSampleProvider*> providers = {{"ctc_src9", &provider}};
        GraphAudioScheduler scheduler(graph, "ctc_mix9", providers);

        AudioClock clock;
        AudioSpscAudioRingBuffer ring(kSampleRate, kChannels, 2048);
        ClockedAudioTransportCoordinator coordinator(clock, scheduler, ring);

        coordinator.start(0, 0);
        int64_t ackedFrame = -1;
        ring.consumePendingSeekOnReaderThread(&ackedFrame);

        const Status speedStatus = clock.setSpeed(2, 1, 0);

        DispatchOutput out;
        const DispatchResult result = coordinator.dispatchUntil(10'000'000, &out);
        const auto snap = coordinator.snapshot();

        nonUnitySpeedRejectOk = speedStatus.ok() && result == DispatchResult::kNonUnitySpeed &&
            out.framesRendered == 0 && snap.nextDispatchFrame == 0;
        if (!nonUnitySpeedRejectOk && failureReason.empty()) failureReason = "non_unity_speed_reject_failed";
    }

    // -- 11. frameConversionOverflowOk --
    {
        const bool zeroOk    = ClockedAudioTransportCoordinator::frameOfPositionUs(0, 48000) == 0;
        const bool negOk     = ClockedAudioTransportCoordinator::frameOfPositionUs(-100, 48000) == 0;
        const bool badRateOk = ClockedAudioTransportCoordinator::frameOfPositionUs(1000, 0) == 0;
        const bool oneSecOk  = ClockedAudioTransportCoordinator::frameOfPositionUs(1'000'000, 48000) == 48000;
        const bool halfSecOk = ClockedAudioTransportCoordinator::frameOfPositionUs(1'500'000, 48000) == 72000;

        const int64_t saturated =
            ClockedAudioTransportCoordinator::frameOfPositionUs(kInt64Max, std::numeric_limits<int32_t>::max());
        const bool saturateOk = saturated == kInt64Max;
        metricFrameOfPositionSaturated = saturated;

        frameConversionOverflowOk = zeroOk && negOk && badRateOk && oneSecOk && halfSecOk && saturateOk;
        if (!frameConversionOverflowOk && failureReason.empty()) failureReason = "frame_conversion_overflow_failed";
    }

    // -- 12. noSteadyStateAllocationOk --
    {
        Graph graph;
        auto mix = std::make_shared<AudioMixBusNode>("ctc_mix10", kSampleRate, kChannels, 64);
        auto src = std::make_shared<DecodedAudioPcmSourceNode>("ctc_src10", kSampleRate, kChannels, 4800, 0);
        graph.addNode(mix);
        graph.addNode(src);
        graph.connect("ctc_src10", "audio_out", "ctc_mix10", "primary_audio_in");

        VectorAudioSampleProvider provider(kSampleRate, kChannels, 0, MakeSignal(8000, kChannels));
        std::unordered_map<std::string, AudioSampleProvider*> providers = {{"ctc_src10", &provider}};
        GraphAudioScheduler scheduler(graph, "ctc_mix10", providers);

        AudioClock clock;
        AudioSpscAudioRingBuffer ring(kSampleRate, kChannels, 4096);
        ClockedAudioTransportCoordinator coordinator(clock, scheduler, ring);

        coordinator.start(0, 0);
        int64_t ackedFrame = -1;
        ring.consumePendingSeekOnReaderThread(&ackedFrame);

        const size_t schedCapBefore = scheduler.trackScratchCapacitySamples();
        const int64_t ringCapBefore = ring.storageCapacitySamples();

        bool allDispatchesConsistent = true;
        int64_t sysTimeNs = 0;
        for (int i = 0; i < 100; ++i) {
            sysTimeNs += 8'000'000; // 8ms steps -> 64 frames due per step, matching maxFramesPerMix
            DispatchOutput out;
            const DispatchResult r = coordinator.dispatchUntil(sysTimeNs, &out);
            if (r != DispatchResult::kOk) {
                allDispatchesConsistent = false;
                break;
            }
            std::vector<int16_t> drain(64 * kChannels, 0);
            ring.tryPopFrames(drain.data(), 64);
        }

        const size_t schedCapAfter = scheduler.trackScratchCapacitySamples();
        const int64_t ringCapAfter = ring.storageCapacitySamples();

        noSteadyStateAllocationOk = allDispatchesConsistent &&
            schedCapBefore > 0 && schedCapBefore == schedCapAfter &&
            ringCapBefore > 0 && ringCapBefore == ringCapAfter;
        if (!noSteadyStateAllocationOk && failureReason.empty()) failureReason = "no_steady_state_allocation_failed";
    }

    // -- 13. lifecycleOk --
    {
        Graph graph;
        auto mix = std::make_shared<AudioMixBusNode>("ctc_mix11", kSampleRate, kChannels, kMaxFramesPerMix);
        auto src = std::make_shared<DecodedAudioPcmSourceNode>("ctc_src11", kSampleRate, kChannels, 4800, 0);
        graph.addNode(mix);
        graph.addNode(src);
        graph.connect("ctc_src11", "audio_out", "ctc_mix11", "primary_audio_in");

        VectorAudioSampleProvider provider(kSampleRate, kChannels, 0, MakeSignal(4000, kChannels));
        std::unordered_map<std::string, AudioSampleProvider*> providers = {{"ctc_src11", &provider}};
        GraphAudioScheduler scheduler(graph, "ctc_mix11", providers);

        AudioClock lcClock;
        AudioSpscAudioRingBuffer lcRing(kSampleRate, kChannels, 2048);
        ClockedAudioTransportCoordinator lcCoordinator(lcClock, scheduler, lcRing);

        // Guarded calls before start(): fail closed without crashing.
        const Status pauseBeforeStart  = lcCoordinator.pause(0);
        const Status resumeBeforeStart = lcCoordinator.resume(0);
        const Status seekBeforeStart   = lcCoordinator.seek(0, 0);
        const bool ringUntouchedBeforeStart  = lcRing.seekRequest() == 0;
        const DispatchResult dispatchNullOut = lcCoordinator.dispatchUntil(0, nullptr); // must not crash

        const Status firstStart  = lcCoordinator.start(0, 0);
        const Status doubleStart = lcCoordinator.start(0, 1); // AudioClock::start only legal from kStopped

        AudioClock badClock;
        AudioSpscAudioRingBuffer badRing(kSampleRate, kChannels == 1 ? 2 : 1, 2048); // mismatched channel count
        ClockedAudioTransportCoordinator badCoordinator(badClock, scheduler, badRing);
        const Status badStart  = badCoordinator.start(0, 0);
        const Status badPause  = badCoordinator.pause(0);
        const Status badResume = badCoordinator.resume(0);
        const Status badSeek   = badCoordinator.seek(0, 0);

        lifecycleOk = !pauseBeforeStart.ok() && !resumeBeforeStart.ok() && !seekBeforeStart.ok() &&
            ringUntouchedBeforeStart && dispatchNullOut == DispatchResult::kNotStarted &&
            firstStart.ok() && !doubleStart.ok() &&
            !badStart.ok() && !badPause.ok() && !badResume.ok() && !badSeek.ok();
        if (!lifecycleOk && failureReason.empty()) failureReason = "lifecycle_failed";
    }

    (void)sharedNextFrameAfterFirstDispatch;

    const bool allPass = coordinatorConstructorValidationOk && startAwaitAckGateOk && clockDrivenDispatchOk &&
                         boundedCatchUpOk && backpressureNoClockMutationOk && pauseResumeNoDispatchOk &&
                         seekAwaitAckGateOk && silenceWindowPushedOk && schedulerErrorNoCursorAdvanceOk &&
                         nonUnitySpeedRejectOk && frameConversionOverflowOk && noSteadyStateAllocationOk &&
                         lifecycleOk && stackScoped;

    std::ostringstream oss;
    oss << "status=" << (allPass ? "PASS" : "FAIL") << ";";
    if (!allPass) {
        oss << "reason=" << (failureReason.empty() ? "unknown_failure" : failureReason) << ";";
    }
    oss << "proofBoundary=" << kProofBoundary << ";"
        << "coordinatorConstructorValidationOk=" << (coordinatorConstructorValidationOk ? "true" : "false") << ";"
        << "startAwaitAckGateOk=" << (startAwaitAckGateOk ? "true" : "false") << ";"
        << "clockDrivenDispatchOk=" << (clockDrivenDispatchOk ? "true" : "false") << ";"
        << "boundedCatchUpOk=" << (boundedCatchUpOk ? "true" : "false") << ";"
        << "backpressureNoClockMutationOk=" << (backpressureNoClockMutationOk ? "true" : "false") << ";"
        << "pauseResumeNoDispatchOk=" << (pauseResumeNoDispatchOk ? "true" : "false") << ";"
        << "seekAwaitAckGateOk=" << (seekAwaitAckGateOk ? "true" : "false") << ";"
        << "silenceWindowPushedOk=" << (silenceWindowPushedOk ? "true" : "false") << ";"
        << "schedulerErrorNoCursorAdvanceOk=" << (schedulerErrorNoCursorAdvanceOk ? "true" : "false") << ";"
        << "nonUnitySpeedRejectOk=" << (nonUnitySpeedRejectOk ? "true" : "false") << ";"
        << "frameConversionOverflowOk=" << (frameConversionOverflowOk ? "true" : "false") << ";"
        << "noSteadyStateAllocationOk=" << (noSteadyStateAllocationOk ? "true" : "false") << ";"
        << "lifecycleOk=" << (lifecycleOk ? "true" : "false") << ";"
        << "stackScoped=" << (stackScoped ? "true" : "false") << ";"
        << "clockDrivenFramesRendered=" << metricClockDrivenFramesRendered << ";"
        << "boundedCatchUpCalls=" << metricBoundedCatchUpCalls << ";"
        << "boundedCatchUpTotalFrames=" << metricBoundedCatchUpTotalFrames << ";"
        << "silenceFramesPushed=" << metricSilenceFramesPushed << ";"
        << "frameOfPositionSaturated=" << metricFrameOfPositionSaturated;

    return oss.str();
}

} // namespace

extern "C" JNIEXPORT jstring JNICALL
Java_com_connects_vanguard_1media_1engine_bridge_VanguardNativeBridge_runAndroidDagPhase4AudioTransportCoordinatorSmoke(
    JNIEnv* env,
    jobject /* this */) {
    try {
        const std::string resultStr = RunAudioTransportCoordinatorSmokeInternal();
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
