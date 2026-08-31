// P4-AUDIO-GRAPH-TRANSPORT-CLOCK (sub-slice F): closed-loop
// ingest-to-transport audio graph pipeline integration proof.
//
// Ties the existing primitives together in one native call:
//   AudioDecoderRingWriter -> source AudioSpscAudioRingBuffer(s)
//     -> RingBufferAudioSampleProvider(s) -> GraphAudioScheduler
//     -> AudioMixBusNode -> ClockedAudioTransportCoordinator
//     -> output AudioSpscAudioRingBuffer -> consumer drain.
//
// Honest non-claims:
// - Does not claim realtime or audible playback.
// - Does not use MediaCodec, MediaExtractor, AudioTrack, AAudio, OpenSL,
//   or Oboe.
// - Does not spawn threads, take locks, or register OS callbacks. This
//   translation unit is single-threaded inside one JNI call and plays the
//   producer and consumer ring roles sequentially, for diagnostics only.
// - Does not perform file IO and never reads a wall clock; every
//   AudioClock/coordinator call is fed an explicit caller-chosen sysTimeNs.
// - Does not resample or change speed.
// - Does not reroute export or the pass-2 graph, and does not stream or
//   cache.
// - Does not add PCM retention/ingest to DecodedAudioPcmSourceNode; source
//   nodes are graph topology anchors only.
// - Writer EOS is writer-local only.
// - Does not touch iOS or product/editor UI.
// - Does not close P4-AUDIO-GRAPH-TRANSPORT-CLOCK.
//
// All graph/ring/provider/writer/coordinator objects are stack-scoped or
// RAII-local to the JNI call: no static session registry, no handles
// retained across calls.
//
// This translation unit is Android-only and must NOT be included in iOS or
// host builds; it is added via the Android-only target_sources block in
// src/CMakeLists.txt.
//
// JNI entry point:
//   runAndroidDagPhase4AudioPipelineIntegrationSmoke -> jstring

#include <jni.h>

#include <cstdint>
#include <memory>
#include <sstream>
#include <stdexcept>
#include <string>
#include <unordered_map>
#include <vector>

#include "vanguard/audio/audio_clock.h"
#include "vanguard/audio/audio_decoder_ring_writer.h"
#include "vanguard/audio/audio_mix_bus_node.h"
#include "vanguard/audio/audio_ring_buffer.h"
#include "vanguard/audio/audio_sample_provider.h"
#include "vanguard/audio/clocked_audio_transport_coordinator.h"
#include "vanguard/audio/decoded_audio_pcm_source_node.h"
#include "vanguard/audio/graph_audio_scheduler.h"
#include "vanguard/audio/ring_buffer_audio_sample_provider.h"
#include "vanguard/graph/graph.h"

namespace {

constexpr const char* kProofBoundary =
    "native_closed_loop_audio_pipeline_integration_proof_only_no_mediacodec_no_mediaextractor_no_audio_track_no_aaudio_no_opensl_no_oboe_no_realtime_playback_no_audible_output_no_os_callback_no_threads_no_locks_no_file_io_no_wall_clock_read_no_resample_no_speed_change_no_export_reroute_no_pass2_graph_reroute_no_streaming_no_cache_no_ios_no_product_no_editor_ui_no_source_node_pcm_ingest_topology_anchor_only_writer_local_eos_only_caller_supplied_systime_only_single_threaded";

using vanguard::audio::AudioClock;
using vanguard::audio::AudioDecoderRingWriter;
using vanguard::audio::AudioMixBusNode;
using vanguard::audio::AudioSampleProvider;
using vanguard::audio::AudioSpscAudioRingBuffer;
using vanguard::audio::ClockedAudioTransportCoordinator;
using vanguard::audio::DecodedAudioPcmSourceNode;
using vanguard::audio::GraphAudioScheduler;
using vanguard::audio::RingBufferAudioSampleProvider;
using vanguard::core::Status;
using vanguard::graph::Graph;
using DispatchResult = ClockedAudioTransportCoordinator::DispatchResult;
using DispatchOutput = ClockedAudioTransportCoordinator::DispatchOutput;
using WriterStatus   = AudioDecoderRingWriter::Status;

constexpr int32_t kSampleRate        = 8000;
constexpr int32_t kChannels          = 1;
constexpr int64_t kMaxFramesPerMix   = 80;
constexpr int64_t kRingCapacityFrames = 256; // power of two, > 2 windows
constexpr int64_t kWindowNs          = 10'000'000LL; // 80 frames @ 8kHz = 10ms

// Deterministic mono PCM pattern. With clipMarkers, frames f%40==7 / f%40==23
// are forced to +/-30000 so the two-track reference mix saturates at those
// frames and the saturated-int16 clamp path is actually exercised.
std::vector<int16_t> MakePattern(int64_t frames, int64_t mul, int64_t mod, int64_t sub,
                                 bool clipMarkers) {
    std::vector<int16_t> pcm(static_cast<size_t>(frames));
    for (int64_t f = 0; f < frames; ++f) {
        int16_t v = static_cast<int16_t>(((f * mul) % mod) - sub);
        if (clipMarkers) {
            if (f % 40 == 7)  v = 30000;
            if (f % 40 == 23) v = -30000;
        }
        pcm[static_cast<size_t>(f)] = v;
    }
    return pcm;
}

uint64_t ChecksumOf(const int16_t* samples, int64_t count) {
    uint64_t checksum = 0;
    for (int64_t i = 0; i < count; ++i) {
        checksum = checksum * 31u + static_cast<uint64_t>(static_cast<uint16_t>(samples[i]));
    }
    return checksum;
}

std::string RunAudioPipelineIntegrationSmokeInternal() {
    bool routeSelectivityOk         = false;
    bool startAwaitAckGateOk        = false;
    bool closedLoopIdentityOk       = false;
    bool sourceSeekAckBoundaryOk    = false;
    bool coordinatorSeekIdentityOk  = false;
    bool firstPostSeekSilenceOk     = false;
    bool noSteadyStateAllocationOk  = false;
    bool noRingPushShortfallOk      = false;
    bool lifecycleOk                = false;
    bool stackScoped                = true;

    std::string failureReason;

    bool anyRingPushShortfall = false;
    bool anyTerminal          = false;

    int64_t  metricClosedLoopFramesVerified   = 0;
    uint64_t metricClosedLoopChecksum         = 0;
    uint64_t metricClosedLoopExpectedChecksum = 0;
    int64_t  metricClosedLoopClippedSamples   = 0;
    int64_t  metricSeekTargetFrame            = 0;
    int64_t  metricSourceSeekTargetFrame      = 0;
    uint64_t metricFirstPostSeekUnderruns     = 0;
    uint64_t metricFirstPostSeekZeroFilled    = 0;
    int64_t  metricSteadyStateDispatches      = 0;
    int64_t  metricSteadyStateFramesPushed    = 0;

    auto dispatchTracked = [&anyRingPushShortfall](ClockedAudioTransportCoordinator& coordinator,
                                                   int64_t sysTimeNs,
                                                   DispatchOutput* out) {
        const DispatchResult r = coordinator.dispatchUntil(sysTimeNs, out);
        if (r == DispatchResult::kRingPushShortfall) {
            anyRingPushShortfall = true;
        }
        return r;
    };

    // ── Main rig: two writer-fed source rings routed through the graph into
    //    one mix bus, dispatched by the clocked coordinator into the output
    //    ring. src_no_provider has a connected edge but no registered
    //    provider and must not be routed. ──
    Graph mainGraph;
    auto mix0 = std::make_shared<AudioMixBusNode>("pipe_mix0", kSampleRate, kChannels, kMaxFramesPerMix);
    auto src0 = std::make_shared<DecodedAudioPcmSourceNode>("src0", kSampleRate, kChannels, 4800, 0);
    auto src1 = std::make_shared<DecodedAudioPcmSourceNode>("src1", kSampleRate, kChannels, 4800, 0);
    auto srcNoProvider = std::make_shared<DecodedAudioPcmSourceNode>("src_no_provider", kSampleRate, kChannels, 4800, 0);
    mainGraph.addNode(mix0);
    mainGraph.addNode(src0);
    mainGraph.addNode(src1);
    mainGraph.addNode(srcNoProvider);
    mainGraph.connect("src0", "audio_out", "pipe_mix0", "primary_audio_in");
    mainGraph.connect("src1", "audio_out", "pipe_mix0", "secondary_audio_in");
    mainGraph.connect("src_no_provider", "audio_out", "pipe_mix0", "audio_in_2");

    AudioSpscAudioRingBuffer sourceRing0(kSampleRate, kChannels, kRingCapacityFrames);
    AudioSpscAudioRingBuffer sourceRing1(kSampleRate, kChannels, kRingCapacityFrames);
    AudioDecoderRingWriter writer0(&sourceRing0, kSampleRate, kChannels);
    AudioDecoderRingWriter writer1(&sourceRing1, kSampleRate, kChannels);
    RingBufferAudioSampleProvider provider0(&sourceRing0, 0);
    RingBufferAudioSampleProvider provider1(&sourceRing1, 0);

    std::unordered_map<std::string, AudioSampleProvider*> mainProviders = {
        {"src0", &provider0},
        {"src1", &provider1},
    };
    GraphAudioScheduler mainScheduler(mainGraph, "pipe_mix0", mainProviders);

    AudioClock mainClock;
    AudioSpscAudioRingBuffer outputRing(kSampleRate, kChannels, kRingCapacityFrames);
    ClockedAudioTransportCoordinator mainCoordinator(mainClock, mainScheduler, outputRing);

    // ── 1. routeSelectivityOk ──
    routeSelectivityOk = mainScheduler.targetValid() &&
        mainScheduler.routedSourceCount() == 2 &&
        mainScheduler.routedSourceIdAt(0) == "src0" &&
        mainScheduler.routedSourceIdAt(1) == "src1";
    if (!routeSelectivityOk && failureReason.empty()) {
        failureReason = "route_selectivity_failed";
    }

    // ── 2. startAwaitAckGateOk + 3. closedLoopIdentityOk ──
    constexpr int64_t kMainFrames = 2 * kMaxFramesPerMix; // 160
    const std::vector<int16_t> pcm0 = MakePattern(kMainFrames, 37, 2001, 1000, true);
    const std::vector<int16_t> pcm1 = MakePattern(kMainFrames, 53, 1401, 700, true);
    {
        int64_t written0 = 0;
        int64_t written1 = 0;
        const WriterStatus w0 = writer0.write(pcm0.data(), kMainFrames, kSampleRate, kChannels, &written0);
        const WriterStatus w1 = writer1.write(pcm1.data(), kMainFrames, kSampleRate, kChannels, &written1);

        const Status startStatus = mainCoordinator.start(0, 0);

        DispatchOutput preAckOut;
        const DispatchResult preAckResult = dispatchTracked(mainCoordinator, kWindowNs, &preAckOut);
        const bool nothingPushedPreAck = outputRing.availableReadFrames() == 0;

        int64_t startAckFrame = -1;
        const bool startAckConsumed = outputRing.consumePendingSeekOnReaderThread(&startAckFrame);

        startAwaitAckGateOk = w0 == WriterStatus::kOk && written0 == kMainFrames &&
            w1 == WriterStatus::kOk && written1 == kMainFrames &&
            startStatus.ok() && preAckResult == DispatchResult::kAwaitingSeekAck &&
            preAckOut.framesRendered == 0 && nothingPushedPreAck &&
            startAckConsumed && startAckFrame == 0;
        if (!startAwaitAckGateOk && failureReason.empty()) {
            failureReason = "start_await_ack_gate_failed";
        }

        DispatchOutput window1Out;
        const DispatchResult window1Result = dispatchTracked(mainCoordinator, kWindowNs, &window1Out);
        DispatchOutput window2Out;
        const DispatchResult window2Result = dispatchTracked(mainCoordinator, 2 * kWindowNs, &window2Out);

        // Hand-computed saturated int16 reference mix for exactly the frames
        // written and dispatched (unit gain, mono, two tracks).
        std::vector<int16_t> referenceMix(static_cast<size_t>(kMainFrames), 0);
        for (int64_t f = 0; f < kMainFrames; ++f) {
            int32_t acc = static_cast<int32_t>(pcm0[static_cast<size_t>(f)]) +
                          static_cast<int32_t>(pcm1[static_cast<size_t>(f)]);
            if (acc > 32767) {
                acc = 32767;
                ++metricClosedLoopClippedSamples;
            } else if (acc < -32768) {
                acc = -32768;
                ++metricClosedLoopClippedSamples;
            }
            referenceMix[static_cast<size_t>(f)] = static_cast<int16_t>(acc);
        }

        std::vector<int16_t> drained(static_cast<size_t>(kMainFrames), 0);
        const int64_t drainedFrames = outputRing.tryPopFrames(drained.data(), kMainFrames);

        bool everySampleMatches = drainedFrames == kMainFrames;
        for (int64_t i = 0; i < kMainFrames && everySampleMatches; ++i) {
            if (drained[static_cast<size_t>(i)] != referenceMix[static_cast<size_t>(i)]) {
                everySampleMatches = false;
            }
        }
        metricClosedLoopChecksum         = ChecksumOf(drained.data(), kMainFrames);
        metricClosedLoopExpectedChecksum = ChecksumOf(referenceMix.data(), kMainFrames);
        metricClosedLoopFramesVerified   = drainedFrames;

        const auto mainSnap = mainCoordinator.snapshot();
        closedLoopIdentityOk = window1Result == DispatchResult::kOk && window1Out.framesRendered == kMaxFramesPerMix &&
            window2Result == DispatchResult::kOk && window2Out.framesRendered == kMaxFramesPerMix &&
            everySampleMatches && metricClosedLoopChecksum == metricClosedLoopExpectedChecksum &&
            mainSnap.totalFramesPushed == kMainFrames && !mainSnap.terminal &&
            metricClosedLoopClippedSamples > 0;
        if (!closedLoopIdentityOk && failureReason.empty()) {
            failureReason = "closed_loop_identity_failed";
        }
    }

    // ── 4. noSteadyStateAllocationOk: repeated write -> dispatch -> drain
    //    cycles on the main rig with all vectors hoisted outside the loop;
    //    ring storage and scheduler scratch capacities must not change. ──
    {
        const size_t  schedCapBefore   = mainScheduler.trackScratchCapacitySamples();
        const size_t  schedTracksBefore = mainScheduler.trackScratchCapacityTracks();
        const int64_t srcCap0Before    = sourceRing0.storageCapacitySamples();
        const int64_t srcCap1Before    = sourceRing1.storageCapacitySamples();
        const int64_t outCapBefore     = outputRing.storageCapacitySamples();

        constexpr int kSteadyStateIterations = 50;
        std::vector<int16_t> drain(static_cast<size_t>(kMaxFramesPerMix), 0);
        bool allCyclesOk = true;
        int64_t sysTimeNs = 2 * kWindowNs;
        for (int i = 0; i < kSteadyStateIterations; ++i) {
            sysTimeNs += kWindowNs;
            int64_t fed0 = 0;
            int64_t fed1 = 0;
            const WriterStatus f0 = writer0.write(pcm0.data(), kMaxFramesPerMix, kSampleRate, kChannels, &fed0);
            const WriterStatus f1 = writer1.write(pcm1.data(), kMaxFramesPerMix, kSampleRate, kChannels, &fed1);
            DispatchOutput out;
            const DispatchResult r = dispatchTracked(mainCoordinator, sysTimeNs, &out);
            const int64_t drainedFrames = outputRing.tryPopFrames(drain.data(), kMaxFramesPerMix);
            if (f0 != WriterStatus::kOk || fed0 != kMaxFramesPerMix ||
                f1 != WriterStatus::kOk || fed1 != kMaxFramesPerMix ||
                r != DispatchResult::kOk || out.framesPushed != kMaxFramesPerMix ||
                drainedFrames != kMaxFramesPerMix) {
                allCyclesOk = false;
                break;
            }
            ++metricSteadyStateDispatches;
            metricSteadyStateFramesPushed += out.framesPushed;
        }

        noSteadyStateAllocationOk = allCyclesOk &&
            schedCapBefore > 0 && schedCapBefore == mainScheduler.trackScratchCapacitySamples() &&
            schedTracksBefore == mainScheduler.trackScratchCapacityTracks() &&
            srcCap0Before > 0 && srcCap0Before == sourceRing0.storageCapacitySamples() &&
            srcCap1Before > 0 && srcCap1Before == sourceRing1.storageCapacitySamples() &&
            outCapBefore > 0 && outCapBefore == outputRing.storageCapacitySamples();
        if (!noSteadyStateAllocationOk && failureReason.empty()) {
            failureReason = "no_steady_state_allocation_failed";
        }
        anyTerminal = anyTerminal || mainCoordinator.snapshot().terminal;
    }

    // ── 5. coordinatorSeekIdentityOk + 6. firstPostSeekSilenceOk ──
    // Fresh single-source rig. The seek frame identity F =
    // frameOfPositionUs(targetPtsUs, sampleRate) is applied to the source
    // ring (via writer.requestSeek), the output ring (via coordinator.seek's
    // ack), and the coordinator cursor. The source-ring ack is consumed by
    // the provider inside the first post-seek provide(), so that first
    // window has no source frames available and must push silence: that is
    // PASS, not failure.
    {
        Graph seekGraph;
        auto seekMix = std::make_shared<AudioMixBusNode>("pipe_mix_seek", kSampleRate, kChannels, kMaxFramesPerMix);
        auto seekSrc = std::make_shared<DecodedAudioPcmSourceNode>("seek_src", kSampleRate, kChannels, 4800, 0);
        seekGraph.addNode(seekMix);
        seekGraph.addNode(seekSrc);
        seekGraph.connect("seek_src", "audio_out", "pipe_mix_seek", "primary_audio_in");

        AudioSpscAudioRingBuffer seekSourceRing(kSampleRate, kChannels, kRingCapacityFrames);
        AudioDecoderRingWriter seekWriter(&seekSourceRing, kSampleRate, kChannels);
        RingBufferAudioSampleProvider seekProvider(&seekSourceRing, 0);
        std::unordered_map<std::string, AudioSampleProvider*> seekProviders = {
            {"seek_src", &seekProvider},
        };
        GraphAudioScheduler seekScheduler(seekGraph, "pipe_mix_seek", seekProviders);
        AudioClock seekClock;
        AudioSpscAudioRingBuffer seekOutputRing(kSampleRate, kChannels, kRingCapacityFrames);
        ClockedAudioTransportCoordinator seekCoordinator(seekClock, seekScheduler, seekOutputRing);

        const std::vector<int16_t> preSeekPattern  = MakePattern(kMaxFramesPerMix, 29, 1601, 800, false);
        const std::vector<int16_t> postSeekPattern = MakePattern(kMaxFramesPerMix, 41, 1201, 600, false);

        int64_t preWritten = 0;
        const WriterStatus preWrite = seekWriter.write(preSeekPattern.data(), kMaxFramesPerMix,
                                                       kSampleRate, kChannels, &preWritten);
        const Status seekStart = seekCoordinator.start(0, 0);
        int64_t startAckFrame = -1;
        const bool startAcked = seekOutputRing.consumePendingSeekOnReaderThread(&startAckFrame);
        DispatchOutput preSeekOut;
        const DispatchResult preSeekResult = dispatchTracked(seekCoordinator, kWindowNs, &preSeekOut);

        std::vector<int16_t> preSeekDrain(static_cast<size_t>(kMaxFramesPerMix), 0);
        const int64_t preSeekDrained = seekOutputRing.tryPopFrames(preSeekDrain.data(), kMaxFramesPerMix);
        bool preSeekMatches = preSeekDrained == kMaxFramesPerMix;
        for (int64_t i = 0; i < kMaxFramesPerMix && preSeekMatches; ++i) {
            if (preSeekDrain[static_cast<size_t>(i)] != preSeekPattern[static_cast<size_t>(i)]) {
                preSeekMatches = false;
            }
        }

        // Seek to 100ms: F must be identical for the source ring, the
        // output ring ack, and the coordinator cursor.
        constexpr int64_t kSeekPtsUs     = 100'000;
        constexpr int64_t kSeekSysTimeNs = 2 * kWindowNs;
        const int64_t seekFrame =
            ClockedAudioTransportCoordinator::frameOfPositionUs(kSeekPtsUs, kSampleRate);
        metricSeekTargetFrame = seekFrame;

        const WriterStatus sourceSeekStatus = seekWriter.requestSeek(seekFrame);
        const Status coordinatorSeekStatus  = seekCoordinator.seek(kSeekPtsUs, kSeekSysTimeNs);
        const auto snapAfterSeek = seekCoordinator.snapshot();

        int64_t blockedWritten = 0;
        const WriterStatus blockedWrite = seekWriter.write(postSeekPattern.data(), kMaxFramesPerMix,
                                                           kSampleRate, kChannels, &blockedWritten);

        DispatchOutput awaitOut;
        const DispatchResult awaitResult = dispatchTracked(seekCoordinator, kSeekSysTimeNs, &awaitOut);

        int64_t seekAckFrame = -1;
        const bool seekAcked = seekOutputRing.consumePendingSeekOnReaderThread(&seekAckFrame);

        // One full window past the seek sysTimeNs before frames are due.
        const uint64_t underrunsBefore  = seekProvider.underrunEvents();
        const uint64_t zeroFilledBefore = seekProvider.framesZeroFilled();
        DispatchOutput silenceOut;
        const DispatchResult silenceResult =
            dispatchTracked(seekCoordinator, kSeekSysTimeNs + kWindowNs, &silenceOut);
        metricFirstPostSeekUnderruns  = seekProvider.underrunEvents() - underrunsBefore;
        metricFirstPostSeekZeroFilled = seekProvider.framesZeroFilled() - zeroFilledBefore;

        firstPostSeekSilenceOk = silenceResult == DispatchResult::kSilence &&
            silenceOut.silence && silenceOut.framesPushed == kMaxFramesPerMix &&
            metricFirstPostSeekUnderruns >= 1 &&
            metricFirstPostSeekZeroFilled == static_cast<uint64_t>(kMaxFramesPerMix) &&
            seekProvider.expectedNextFrame() == seekFrame + kMaxFramesPerMix;
        if (!firstPostSeekSilenceOk && failureReason.empty()) {
            failureReason = "first_post_seek_silence_failed";
        }

        // The provider published the source-ring ack inside provide() and
        // advanced its cursor past the silence window, so the writer must be
        // re-aligned to the provider's next window before postSeekPattern is
        // written: the FIFO ring carries no frame stamps, so an unaligned
        // writer cursor could otherwise pass sample matching one window off.
        const int64_t postSeekFrame = seekFrame + kMaxFramesPerMix;
        const WriterStatus postSeekReseek = seekWriter.requestSeek(postSeekFrame);
        const bool postSeekCursorAligned  = seekWriter.nextWriteFrame() == postSeekFrame;

        int64_t preAckWritten = 0;
        const WriterStatus preAckWrite = seekWriter.write(postSeekPattern.data(), kMaxFramesPerMix,
                                                          kSampleRate, kChannels, &preAckWritten);

        int64_t postSeekSourceAckFrame = -1;
        const bool postSeekSourceAcked =
            seekSourceRing.consumePendingSeekOnReaderThread(&postSeekSourceAckFrame);

        int64_t postWritten = 0;
        const WriterStatus postWrite = seekWriter.write(postSeekPattern.data(), kMaxFramesPerMix,
                                                        kSampleRate, kChannels, &postWritten);
        DispatchOutput postSeekOut;
        const DispatchResult postSeekResult =
            dispatchTracked(seekCoordinator, kSeekSysTimeNs + 2 * kWindowNs, &postSeekOut);
        const bool providerCursorAfterPostSeekOk =
            seekProvider.expectedNextFrame() == postSeekFrame + kMaxFramesPerMix;

        std::vector<int16_t> postSeekDrain(static_cast<size_t>(2 * kMaxFramesPerMix), 111);
        const int64_t postSeekDrained =
            seekOutputRing.tryPopFrames(postSeekDrain.data(), 2 * kMaxFramesPerMix);
        bool silenceWindowAllZero = postSeekDrained == 2 * kMaxFramesPerMix;
        for (int64_t i = 0; i < kMaxFramesPerMix && silenceWindowAllZero; ++i) {
            if (postSeekDrain[static_cast<size_t>(i)] != 0) {
                silenceWindowAllZero = false;
            }
        }
        bool postSeekMatches = postSeekDrained == 2 * kMaxFramesPerMix;
        for (int64_t i = 0; i < kMaxFramesPerMix && postSeekMatches; ++i) {
            if (postSeekDrain[static_cast<size_t>(kMaxFramesPerMix + i)] !=
                postSeekPattern[static_cast<size_t>(i)]) {
                postSeekMatches = false;
            }
        }
        const uint64_t postSeekChecksum =
            ChecksumOf(postSeekDrain.data() + kMaxFramesPerMix, kMaxFramesPerMix);
        const uint64_t postSeekExpectedChecksum =
            ChecksumOf(postSeekPattern.data(), kMaxFramesPerMix);

        coordinatorSeekIdentityOk = preWrite == WriterStatus::kOk && preWritten == kMaxFramesPerMix &&
            seekStart.ok() && startAcked && startAckFrame == 0 &&
            preSeekResult == DispatchResult::kOk && preSeekMatches &&
            sourceSeekStatus == WriterStatus::kOk && seekWriter.nextWriteFrame() >= seekFrame &&
            coordinatorSeekStatus.ok() && snapAfterSeek.nextDispatchFrame == seekFrame &&
            blockedWrite == WriterStatus::kAwaitingSeekAck && blockedWritten == 0 &&
            awaitResult == DispatchResult::kAwaitingSeekAck && awaitOut.framesRendered == 0 &&
            seekAcked && seekAckFrame == seekFrame &&
            postSeekReseek == WriterStatus::kOk && postSeekCursorAligned &&
            preAckWrite == WriterStatus::kAwaitingSeekAck && preAckWritten == 0 &&
            postSeekSourceAcked && postSeekSourceAckFrame == postSeekFrame &&
            postWrite == WriterStatus::kOk && postWritten == kMaxFramesPerMix &&
            postSeekResult == DispatchResult::kOk && silenceWindowAllZero && postSeekMatches &&
            postSeekChecksum == postSeekExpectedChecksum && providerCursorAfterPostSeekOk;
        if (!coordinatorSeekIdentityOk && failureReason.empty()) {
            failureReason = "coordinator_seek_identity_failed";
        }
        anyTerminal = anyTerminal || seekCoordinator.snapshot().terminal;
    }

    // ── 7. sourceSeekAckBoundaryOk ──
    // Fresh source rig proves the writer-side seek boundary: EOS cleared by
    // requestSeek, write rejected until the source ring ack, write accepted
    // after. The downstream rig (provider seeded at F, coordinator started
    // at the matching pts) is constructed after the ack so the provider's
    // expectedNextFrame starts aligned at F.
    {
        AudioSpscAudioRingBuffer boundarySourceRing(kSampleRate, kChannels, kRingCapacityFrames);
        AudioDecoderRingWriter boundaryWriter(&boundarySourceRing, kSampleRate, kChannels);

        const std::vector<int16_t> stalePattern    = MakePattern(40, 19, 901, 450, false);
        const std::vector<int16_t> boundaryPattern = MakePattern(kMaxFramesPerMix, 47, 1301, 650, false);

        int64_t staleWritten = 0;
        const WriterStatus staleWrite = boundaryWriter.write(stalePattern.data(), 40,
                                                             kSampleRate, kChannels, &staleWritten);
        boundaryWriter.setEos();
        const bool eosSet = boundaryWriter.isEos();
        const WriterStatus eosWrite = boundaryWriter.write(boundaryPattern.data(), kMaxFramesPerMix,
                                                           kSampleRate, kChannels, nullptr);

        constexpr int64_t kBoundaryPtsUs = 50'000;
        const int64_t boundaryFrame =
            ClockedAudioTransportCoordinator::frameOfPositionUs(kBoundaryPtsUs, kSampleRate);
        metricSourceSeekTargetFrame = boundaryFrame;

        const WriterStatus boundarySeek = boundaryWriter.requestSeek(boundaryFrame);
        const bool eosCleared      = !boundaryWriter.isEos();
        const bool cursorReseeded  = boundaryWriter.nextWriteFrame() == boundaryFrame;

        int64_t blockedWritten = 0;
        const WriterStatus blockedWrite = boundaryWriter.write(boundaryPattern.data(), kMaxFramesPerMix,
                                                               kSampleRate, kChannels, &blockedWritten);

        int64_t sourceAckFrame = -1;
        const bool sourceAcked = boundarySourceRing.consumePendingSeekOnReaderThread(&sourceAckFrame);

        int64_t postAckWritten = 0;
        const WriterStatus postAckWrite = boundaryWriter.write(boundaryPattern.data(), kMaxFramesPerMix,
                                                               kSampleRate, kChannels, &postAckWritten);

        Graph boundaryGraph;
        auto boundaryMix = std::make_shared<AudioMixBusNode>("pipe_mix_boundary", kSampleRate, kChannels, kMaxFramesPerMix);
        auto boundarySrc = std::make_shared<DecodedAudioPcmSourceNode>("boundary_src", kSampleRate, kChannels, 4800, 0);
        boundaryGraph.addNode(boundaryMix);
        boundaryGraph.addNode(boundarySrc);
        boundaryGraph.connect("boundary_src", "audio_out", "pipe_mix_boundary", "primary_audio_in");

        RingBufferAudioSampleProvider boundaryProvider(&boundarySourceRing, boundaryFrame);
        std::unordered_map<std::string, AudioSampleProvider*> boundaryProviders = {
            {"boundary_src", &boundaryProvider},
        };
        GraphAudioScheduler boundaryScheduler(boundaryGraph, "pipe_mix_boundary", boundaryProviders);
        AudioClock boundaryClock;
        AudioSpscAudioRingBuffer boundaryOutputRing(kSampleRate, kChannels, kRingCapacityFrames);
        ClockedAudioTransportCoordinator boundaryCoordinator(boundaryClock, boundaryScheduler, boundaryOutputRing);

        const Status boundaryStart = boundaryCoordinator.start(kBoundaryPtsUs, 0);
        int64_t boundaryOutAckFrame = -1;
        const bool boundaryOutAcked = boundaryOutputRing.consumePendingSeekOnReaderThread(&boundaryOutAckFrame);

        DispatchOutput boundaryOut;
        const DispatchResult boundaryResult = dispatchTracked(boundaryCoordinator, kWindowNs, &boundaryOut);

        std::vector<int16_t> boundaryDrain(static_cast<size_t>(kMaxFramesPerMix), 0);
        const int64_t boundaryDrained = boundaryOutputRing.tryPopFrames(boundaryDrain.data(), kMaxFramesPerMix);
        bool boundaryMatches = boundaryDrained == kMaxFramesPerMix;
        for (int64_t i = 0; i < kMaxFramesPerMix && boundaryMatches; ++i) {
            if (boundaryDrain[static_cast<size_t>(i)] != boundaryPattern[static_cast<size_t>(i)]) {
                boundaryMatches = false;
            }
        }

        sourceSeekAckBoundaryOk = staleWrite == WriterStatus::kOk && staleWritten == 40 &&
            eosSet && eosWrite == WriterStatus::kAlreadyEos &&
            boundarySeek == WriterStatus::kOk && eosCleared && cursorReseeded &&
            blockedWrite == WriterStatus::kAwaitingSeekAck && blockedWritten == 0 &&
            boundaryWriter.metrics().awaitingSeekAckRejects == 1 &&
            sourceAcked && sourceAckFrame == boundaryFrame &&
            postAckWrite == WriterStatus::kOk && postAckWritten == kMaxFramesPerMix &&
            boundaryStart.ok() && boundaryOutAcked && boundaryOutAckFrame == boundaryFrame &&
            boundaryResult == DispatchResult::kOk && boundaryMatches;
        if (!sourceSeekAckBoundaryOk && failureReason.empty()) {
            failureReason = "source_seek_ack_boundary_failed";
        }
        anyTerminal = anyTerminal || boundaryCoordinator.snapshot().terminal;
    }

    // ── 8. lifecycleOk: cheap fail-closed checks across the seams ──
    {
        AudioSpscAudioRingBuffer lcRing(kSampleRate, kChannels, 64);
        AudioDecoderRingWriter lcWriter(&lcRing, kSampleRate, kChannels);
        const std::vector<int16_t> lcPcm = MakePattern(8, 7, 101, 50, false);

        const WriterStatus formatMismatch =
            lcWriter.write(lcPcm.data(), 8, 44100, kChannels, nullptr);
        const WriterStatus negativeSeek = lcWriter.requestSeek(-1);
        const bool ringRejectsNegativeSeek = !lcRing.requestSeek(-5);

        bool writerCtorMismatchThrew = false;
        try {
            AudioDecoderRingWriter mismatchedWriter(&lcRing, 44100, kChannels);
            (void)mismatchedWriter;
        } catch (const std::invalid_argument&) {
            writerCtorMismatchThrew = true;
        }

        Graph lcGraph;
        auto lcMix = std::make_shared<AudioMixBusNode>("pipe_mix_lc", kSampleRate, kChannels, kMaxFramesPerMix);
        lcGraph.addNode(lcMix);
        std::unordered_map<std::string, AudioSampleProvider*> lcProviders;
        GraphAudioScheduler lcScheduler(lcGraph, "pipe_mix_lc", lcProviders);

        // Channel-count mismatch between scheduler (mono) and output ring
        // (stereo): permanently invalid coordinator, fails closed with no
        // ring mutation.
        AudioClock lcClock;
        AudioSpscAudioRingBuffer lcBadRing(kSampleRate, 2, kRingCapacityFrames);
        ClockedAudioTransportCoordinator lcBadCoordinator(lcClock, lcScheduler, lcBadRing);
        const Status badStart = lcBadCoordinator.start(0, 0);
        DispatchOutput badOut;
        const DispatchResult badDispatch = lcBadCoordinator.dispatchUntil(0, &badOut);
        const bool badRingUntouched = lcBadRing.seekRequest() == 0;

        lifecycleOk = formatMismatch == WriterStatus::kFormatMismatch &&
            negativeSeek == WriterStatus::kInvalidArgument && ringRejectsNegativeSeek &&
            writerCtorMismatchThrew &&
            !badStart.ok() && badDispatch == DispatchResult::kInvalidConfiguration &&
            badOut.framesRendered == 0 && badRingUntouched;
        if (!lifecycleOk && failureReason.empty()) {
            failureReason = "lifecycle_failed";
        }
    }

    // ── 9. noRingPushShortfallOk: terminal shortfall never occurred on any
    //    lane and no coordinator ended terminal. ──
    anyTerminal = anyTerminal || mainCoordinator.snapshot().terminal;
    noRingPushShortfallOk = !anyRingPushShortfall && !anyTerminal;
    if (!noRingPushShortfallOk && failureReason.empty()) {
        failureReason = "ring_push_shortfall_observed";
    }

    const bool allPass = routeSelectivityOk && startAwaitAckGateOk && closedLoopIdentityOk &&
                         sourceSeekAckBoundaryOk && coordinatorSeekIdentityOk &&
                         firstPostSeekSilenceOk && noSteadyStateAllocationOk &&
                         noRingPushShortfallOk && lifecycleOk && stackScoped;

    std::ostringstream oss;
    oss << "status=" << (allPass ? "PASS" : "FAIL") << ";";
    if (!allPass) {
        oss << "reason=" << (failureReason.empty() ? "unknown_failure" : failureReason) << ";";
    }
    oss << "proofBoundary=" << kProofBoundary << ";"
        << "routeSelectivityOk=" << (routeSelectivityOk ? "true" : "false") << ";"
        << "startAwaitAckGateOk=" << (startAwaitAckGateOk ? "true" : "false") << ";"
        << "closedLoopIdentityOk=" << (closedLoopIdentityOk ? "true" : "false") << ";"
        << "sourceSeekAckBoundaryOk=" << (sourceSeekAckBoundaryOk ? "true" : "false") << ";"
        << "coordinatorSeekIdentityOk=" << (coordinatorSeekIdentityOk ? "true" : "false") << ";"
        << "firstPostSeekSilenceOk=" << (firstPostSeekSilenceOk ? "true" : "false") << ";"
        << "noSteadyStateAllocationOk=" << (noSteadyStateAllocationOk ? "true" : "false") << ";"
        << "noRingPushShortfallOk=" << (noRingPushShortfallOk ? "true" : "false") << ";"
        << "lifecycleOk=" << (lifecycleOk ? "true" : "false") << ";"
        << "stackScoped=" << (stackScoped ? "true" : "false") << ";"
        << "closedLoopFramesVerified=" << metricClosedLoopFramesVerified << ";"
        << "closedLoopChecksum=" << metricClosedLoopChecksum << ";"
        << "closedLoopExpectedChecksum=" << metricClosedLoopExpectedChecksum << ";"
        << "closedLoopClippedSamples=" << metricClosedLoopClippedSamples << ";"
        << "seekTargetFrame=" << metricSeekTargetFrame << ";"
        << "sourceSeekTargetFrame=" << metricSourceSeekTargetFrame << ";"
        << "firstPostSeekUnderrunEvents=" << metricFirstPostSeekUnderruns << ";"
        << "firstPostSeekFramesZeroFilled=" << metricFirstPostSeekZeroFilled << ";"
        << "steadyStateDispatches=" << metricSteadyStateDispatches << ";"
        << "steadyStateFramesPushed=" << metricSteadyStateFramesPushed;

    return oss.str();
}

} // namespace

extern "C" JNIEXPORT jstring JNICALL
Java_com_connects_vanguard_1media_1engine_bridge_VanguardNativeBridge_runAndroidDagPhase4AudioPipelineIntegrationSmoke(
    JNIEnv* env,
    jobject /* this */) {
    try {
        const std::string resultStr = RunAudioPipelineIntegrationSmokeInternal();
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
