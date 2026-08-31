// P4-AUDIO-GRAPH-TRANSPORT-CLOCK sub-slice B: lock-free SPSC audio
// ring-buffer transport primitive + diagnostic AudioSampleProvider adapter
// native proof.
//
// Honest non-claims:
// - Does not claim realtime or audible playback.
// - Does not use AudioTrack, AAudio, OpenSL, or Oboe.
// - Does not claim realtime OS clock ownership.
// - Does not implement a production PCM writer.
// - Does not use MediaCodec or MediaExtractor.
// - Does not add any C++ -> Kotlin callback.
// - Does not reroute export.
// - Does not stream and does not use any cache.
// - Does not touch app/editor/product UI.
// - Does not touch iOS.
// - Does not close P4-AUDIO-GRAPH-TRANSPORT-CLOCK.
// - Does not close P4-AUDIO-MIXBUS.
//
// AudioSpscAudioRingBuffer and RingBufferAudioSampleProvider are
// diagnostic-only: one real std::thread producer is used below purely to
// exercise the lock-free SPSC contract under genuine concurrency, but
// nothing here is wired to a realtime audio path, an OS clock, or any
// Kotlin/Dart caller. This translation unit is Android-only and must NOT
// be included in iOS or host builds; it is added via the Android-only
// target_sources block in src/CMakeLists.txt. If host ThreadSanitizer has
// not been run over this code, no sanitizer race-freedom claim is made
// here.
//
// JNI entry point:
//   runAndroidDagPhase4AudioRingBufferTransportSmoke -> jstring

#include <jni.h>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cstdint>
#include <memory>
#include <sstream>
#include <stdexcept>
#include <string>
#include <thread>
#include <unordered_map>
#include <vector>

#include "vanguard/audio/audio_mix_bus_node.h"
#include "vanguard/audio/audio_ring_buffer.h"
#include "vanguard/audio/decoded_audio_pcm_source_node.h"
#include "vanguard/audio/graph_audio_scheduler.h"
#include "vanguard/audio/ring_buffer_audio_sample_provider.h"
#include "vanguard/graph/graph.h"

namespace {

constexpr const char* kProofBoundary =
    "native_spsc_audio_ring_buffer_transport_primitive_and_diagnostic_provider_adapter_only_no_realtime_no_audio_track_no_playback_no_clock_ownership_no_decoder_writer_no_export_reroute_no_streaming_no_ios_no_product";

using vanguard::audio::AudioMixBusNode;
using vanguard::audio::AudioSampleProvider;
using vanguard::audio::AudioSpscAudioRingBuffer;
using vanguard::audio::AudioWindowBuffer;
using vanguard::audio::AudioWindowRequest;
using vanguard::audio::DecodedAudioPcmSourceNode;
using vanguard::audio::GraphAudioScheduler;
using vanguard::audio::RingBufferAudioSampleProvider;
using vanguard::graph::Graph;
using SchedulerResult = GraphAudioScheduler::SchedulerResult;

std::string RunAudioRingBufferTransportSmokeInternal() {
    bool ringSpscLockFreeOk           = false;
    bool ringCapacityBoundOk          = false;
    bool ringNoAllocationOk           = false;
    bool fifoOrderIntegrityOk         = false;
    bool wraparoundIntegrityOk        = false;
    bool noTornFrameOk                = false;
    bool overrunRejectOk              = false;
    bool underrunZeroFillOk           = false;
    bool underrunSilentWindowOk       = false;
    bool rewindRejectOk               = false;
    bool forwardSkipBoundedOk         = false;
    bool flushDrainSemanticsOk        = false;
    bool seekEpochHandshakeOk         = false;
    bool concurrentProducerConsumerOk = false;
    bool schedulerIntegrationChecksumOk = false;
    bool teardownWhileQuiescedOk      = false;
    bool lifecycleOk                  = false;
    bool stackScoped                  = true;

    std::string failureReason;

    uint64_t metricFramesPushed      = 0;
    uint64_t metricFramesPopped      = 0;
    uint64_t metricOverrunEvents     = 0;
    uint64_t metricFramesRejected    = 0;
    uint64_t metricUnderrunEvents    = 0;
    uint64_t metricFramesZeroFilled  = 0;
    uint64_t metricForwardSkipFrames = 0;
    uint64_t metricRewindRejects     = 0;
    uint32_t metricSeekRequest       = 0;
    uint32_t metricSeekAck           = 0;
    int64_t  metricConcurrentFrames      = 0;
    int      metricConcurrentRepetitions = 0;
    uint64_t metricProducerChecksum      = 0;
    uint64_t metricConsumerChecksum      = 0;

    constexpr int32_t kSampleRate = 48000;
    constexpr int32_t kChannels   = 2;

    // ── 1. ringSpscLockFreeOk ──
    ringSpscLockFreeOk = AudioSpscAudioRingBuffer::atomicIndicesLockFree();
    if (!ringSpscLockFreeOk && failureReason.empty()) {
        failureReason = "ring_spsc_lock_free_failed";
    }

    // ── 2. ringCapacityBoundOk ──
    {
        AudioSpscAudioRingBuffer boundRing(kSampleRate, kChannels, 4096);
        bool overCapacityThrows = false;
        try {
            AudioSpscAudioRingBuffer over(kSampleRate, kChannels, AudioSpscAudioRingBuffer::kMaxCapacityFrames * 2);
            (void)over;
        } catch (const std::invalid_argument&) {
            overCapacityThrows = true;
        } catch (...) {
        }

        ringCapacityBoundOk = boundRing.capacityFrames() == 4096 &&
                              boundRing.capacitySamples() == 4096 * kChannels &&
                              AudioSpscAudioRingBuffer::kMaxCapacityFrames == 65536 &&
                              overCapacityThrows;
        if (!ringCapacityBoundOk && failureReason.empty()) failureReason = "ring_capacity_bound_failed";
    }

    // ── 3. ringNoAllocationOk: storage capacity constant across many push/pop calls ──
    {
        AudioSpscAudioRingBuffer allocRing(kSampleRate, kChannels, 1024);
        const int64_t capBefore = allocRing.storageCapacitySamples();

        std::vector<int16_t> allocChunk(64 * kChannels, 42);
        std::vector<int16_t> allocPopChunk(64 * kChannels, 0);
        for (int i = 0; i < 50; ++i) {
            allocRing.tryPushFrames(allocChunk.data(), 64);
            allocRing.tryPopFrames(allocPopChunk.data(), 64);
        }

        const int64_t capAfter = allocRing.storageCapacitySamples();
        ringNoAllocationOk = capBefore > 0 && capBefore == capAfter;
        if (!ringNoAllocationOk && failureReason.empty()) failureReason = "ring_no_allocation_failed";
    }

    // ── 4. fifoOrderIntegrityOk ──
    {
        AudioSpscAudioRingBuffer fifoRing(kSampleRate, kChannels, 2048);
        constexpr int64_t kFifoFrames = 500;
        std::vector<int16_t> fifoIn(static_cast<size_t>(kFifoFrames) * kChannels);
        for (int64_t f = 0; f < kFifoFrames; ++f) {
            fifoIn[f * kChannels + 0] = static_cast<int16_t>(f);
            fifoIn[f * kChannels + 1] = static_cast<int16_t>(-f);
        }

        const int64_t pushed = fifoRing.tryPushFrames(fifoIn.data(), kFifoFrames);
        std::vector<int16_t> fifoOut(static_cast<size_t>(kFifoFrames) * kChannels, -1);
        const int64_t popped = fifoRing.tryPopFrames(fifoOut.data(), kFifoFrames);

        fifoOrderIntegrityOk = pushed == kFifoFrames && popped == kFifoFrames && fifoOut == fifoIn;
        if (!fifoOrderIntegrityOk && failureReason.empty()) failureReason = "fifo_order_integrity_failed";
    }

    // ── 5. wraparoundIntegrityOk: small capacity forces many index wraps ──
    {
        AudioSpscAudioRingBuffer wrapRing(kSampleRate, kChannels, 32);
        constexpr int64_t kWrapTotalFrames = 5000;
        uint64_t wrapPushChecksum = 0;
        uint64_t wrapPopChecksum  = 0;

        std::vector<int16_t> wrapChunk(16 * kChannels);
        std::vector<int16_t> wrapPopChunk(16 * kChannels);
        int64_t produced = 0;
        int64_t consumed = 0;
        int iterations = 0;

        while (consumed < kWrapTotalFrames && iterations < 10000) {
            if (produced < kWrapTotalFrames) {
                const int64_t chunkFrames = std::min<int64_t>(16, kWrapTotalFrames - produced);
                for (int64_t f = 0; f < chunkFrames; ++f) {
                    const int16_t s = static_cast<int16_t>((produced + f) & 0x7FFF);
                    wrapChunk[f * kChannels + 0] = s;
                    wrapChunk[f * kChannels + 1] = s;
                }
                const int64_t accepted = wrapRing.tryPushFrames(wrapChunk.data(), chunkFrames);
                for (int64_t f = 0; f < accepted; ++f) {
                    wrapPushChecksum = wrapPushChecksum * 1000003ull +
                                      static_cast<uint64_t>(static_cast<uint16_t>(wrapChunk[f * kChannels + 0]));
                    wrapPushChecksum = wrapPushChecksum * 1000003ull +
                                      static_cast<uint64_t>(static_cast<uint16_t>(wrapChunk[f * kChannels + 1]));
                }
                produced += accepted;
            }

            const int64_t popped = wrapRing.tryPopFrames(wrapPopChunk.data(), 16);
            for (int64_t f = 0; f < popped; ++f) {
                wrapPopChecksum = wrapPopChecksum * 1000003ull +
                                  static_cast<uint64_t>(static_cast<uint16_t>(wrapPopChunk[f * kChannels + 0]));
                wrapPopChecksum = wrapPopChecksum * 1000003ull +
                                  static_cast<uint64_t>(static_cast<uint16_t>(wrapPopChunk[f * kChannels + 1]));
            }
            consumed += popped;
            ++iterations;
        }

        wraparoundIntegrityOk = produced == kWrapTotalFrames && consumed == kWrapTotalFrames &&
                                wrapPushChecksum == wrapPopChecksum;
        if (!wraparoundIntegrityOk && failureReason.empty()) failureReason = "wraparound_integrity_failed";
    }

    // ── 6. noTornFrameOk: each popped frame's two channel samples are self-consistent ──
    {
        AudioSpscAudioRingBuffer tornRing(kSampleRate, kChannels, 64);
        constexpr int64_t kTornFrames = 40;
        std::vector<int16_t> tornIn(static_cast<size_t>(kTornFrames) * kChannels);
        for (int64_t f = 0; f < kTornFrames; ++f) {
            tornIn[f * kChannels + 0] = static_cast<int16_t>(1000 + f);
            tornIn[f * kChannels + 1] = static_cast<int16_t>(-(1000 + f));
        }
        tornRing.tryPushFrames(tornIn.data(), kTornFrames);

        std::vector<int16_t> tornOut(static_cast<size_t>(kTornFrames) * kChannels, 0);
        const int64_t tornPopped = tornRing.tryPopFrames(tornOut.data(), kTornFrames);

        bool allPairsIntact = tornPopped == kTornFrames;
        for (int64_t f = 0; f < tornPopped && allPairsIntact; ++f) {
            if (tornOut[f * kChannels + 0] != static_cast<int16_t>(1000 + f)) allPairsIntact = false;
            if (tornOut[f * kChannels + 0] != -tornOut[f * kChannels + 1]) allPairsIntact = false;
        }

        noTornFrameOk = allPairsIntact;
        if (!noTornFrameOk && failureReason.empty()) failureReason = "no_torn_frame_failed";
    }

    // ── 7. overrunRejectOk: drop-newest, unread data never overwritten ──
    {
        AudioSpscAudioRingBuffer overRing(kSampleRate, kChannels, 16);
        std::vector<int16_t> fillIn(16 * kChannels);
        for (int64_t f = 0; f < 16; ++f) {
            fillIn[f * kChannels + 0] = static_cast<int16_t>(f);
            fillIn[f * kChannels + 1] = static_cast<int16_t>(f);
        }
        const int64_t filled = overRing.tryPushFrames(fillIn.data(), 16);

        std::vector<int16_t> overflowIn(8 * kChannels, 9999);
        const uint64_t overrunsBefore  = overRing.overrunEvents();
        const uint64_t rejectedBefore  = overRing.framesRejected();
        const int64_t overflowAccepted = overRing.tryPushFrames(overflowIn.data(), 8);
        const uint64_t overrunsAfter   = overRing.overrunEvents();
        const uint64_t rejectedAfter   = overRing.framesRejected();

        std::vector<int16_t> overOut(16 * kChannels, -1);
        const int64_t overPopped     = overRing.tryPopFrames(overOut.data(), 16);
        const bool contentPreserved  = overPopped == 16 && overOut == fillIn;

        metricOverrunEvents  = overrunsAfter;
        metricFramesRejected = rejectedAfter;

        overrunRejectOk = filled == 16 && overflowAccepted == 0 &&
                         overrunsAfter == overrunsBefore + 1 &&
                         rejectedAfter == rejectedBefore + 8 &&
                         contentPreserved;
        if (!overrunRejectOk && failureReason.empty()) failureReason = "overrun_reject_failed";
    }

    // ── 8. underrunZeroFillOk: partial availability zero-fills tail, silent=false ──
    {
        AudioSpscAudioRingBuffer partialRing(kSampleRate, kChannels, 64);
        constexpr int64_t kPartialAvailable = 10;
        std::vector<int16_t> partialIn(static_cast<size_t>(kPartialAvailable) * kChannels);
        for (int64_t f = 0; f < kPartialAvailable; ++f) {
            partialIn[f * kChannels + 0] = static_cast<int16_t>(200 + f);
            partialIn[f * kChannels + 1] = static_cast<int16_t>(200 + f);
        }
        partialRing.tryPushFrames(partialIn.data(), kPartialAvailable);

        RingBufferAudioSampleProvider partialProvider(&partialRing, 0);
        constexpr int64_t kPartialRequestFrames = 20;
        std::vector<int16_t> partialOut(static_cast<size_t>(kPartialRequestFrames) * kChannels, 111);
        AudioWindowRequest partialReq{0, kPartialRequestFrames, kSampleRate, kChannels, 0};
        AudioWindowBuffer partialBuf{partialOut.data(), static_cast<int64_t>(partialOut.size()), 0, false};
        const uint64_t underrunBefore = partialProvider.underrunEvents();
        const auto partialStatus = partialProvider.provide(partialReq, partialBuf);

        bool tailZero = true;
        for (int64_t i = kPartialAvailable * kChannels; i < kPartialRequestFrames * kChannels; ++i) {
            if (partialOut[i] != 0) tailZero = false;
        }
        bool headMatches = true;
        for (int64_t f = 0; f < kPartialAvailable; ++f) {
            if (partialOut[f * kChannels + 0] != static_cast<int16_t>(200 + f) ||
                partialOut[f * kChannels + 1] != static_cast<int16_t>(200 + f)) {
                headMatches = false;
            }
        }

        metricUnderrunEvents   = partialProvider.underrunEvents();
        metricFramesZeroFilled = partialProvider.framesZeroFilled();

        underrunZeroFillOk = partialStatus.ok() && !partialBuf.silent &&
                            partialBuf.framesWritten == kPartialRequestFrames &&
                            tailZero && headMatches &&
                            partialProvider.underrunEvents() == underrunBefore + 1;
        if (!underrunZeroFillOk && failureReason.empty()) failureReason = "underrun_zero_fill_failed";
    }

    // ── 9. underrunSilentWindowOk: empty ring -> silent=true; scheduler -> kSilence, no mix() ──
    {
        AudioSpscAudioRingBuffer emptyRing(kSampleRate, kChannels, 64);
        RingBufferAudioSampleProvider emptyProvider(&emptyRing, 0);
        std::vector<int16_t> emptyOut(32 * kChannels, 55);
        AudioWindowRequest emptyReq{0, 32, kSampleRate, kChannels, 0};
        AudioWindowBuffer emptyBuf{emptyOut.data(), static_cast<int64_t>(emptyOut.size()), 0, false};
        const auto emptyStatus = emptyProvider.provide(emptyReq, emptyBuf);
        const bool directProviderSilentOk = emptyStatus.ok() && emptyBuf.silent && emptyBuf.framesWritten == 32 &&
            std::all_of(emptyOut.begin(), emptyOut.end(), [](int16_t v) { return v == 0; });

        Graph silentGraph;
        auto silentMix = std::make_shared<AudioMixBusNode>("ring_silent_mix", kSampleRate, kChannels, 512);
        auto silentSrc = std::make_shared<DecodedAudioPcmSourceNode>("ring_silent_src", kSampleRate, kChannels, 4800, 0);
        silentGraph.addNode(silentMix);
        silentGraph.addNode(silentSrc);
        silentGraph.connect("ring_silent_src", "audio_out", "ring_silent_mix", "primary_audio_in");

        AudioSpscAudioRingBuffer silentSchedRing(kSampleRate, kChannels, 64);
        RingBufferAudioSampleProvider silentSchedProvider(&silentSchedRing, 0);
        std::unordered_map<std::string, AudioSampleProvider*> silentProviders = {
            {"ring_silent_src", &silentSchedProvider},
        };
        GraphAudioScheduler silentScheduler(silentGraph, "ring_silent_mix", silentProviders);

        std::vector<int16_t> silentSchedOut(32 * kChannels, 66);
        GraphAudioScheduler::SchedulerOutput silentSchedOutMeta;
        const auto silentSchedRes = silentScheduler.renderWindow(
            0, 32, silentSchedOut.data(), static_cast<int64_t>(silentSchedOut.size()), &silentSchedOutMeta);
        const bool schedAllZero = std::all_of(silentSchedOut.begin(), silentSchedOut.end(),
                                              [](int16_t v) { return v == 0; });

        underrunSilentWindowOk = directProviderSilentOk &&
            silentSchedRes == SchedulerResult::kSilence && silentSchedOutMeta.silence &&
            !silentSchedOutMeta.mixCalled && schedAllZero;
        if (!underrunSilentWindowOk && failureReason.empty()) failureReason = "underrun_silent_window_failed";
    }

    // ── 10. rewindRejectOk: rewind fails closed, cursor uncorrupted ──
    {
        AudioSpscAudioRingBuffer rewindRing(kSampleRate, kChannels, 128);
        std::vector<int16_t> rewindIn(64 * kChannels);
        for (int64_t f = 0; f < 64; ++f) {
            rewindIn[f * kChannels + 0] = static_cast<int16_t>(f);
            rewindIn[f * kChannels + 1] = static_cast<int16_t>(f);
        }
        rewindRing.tryPushFrames(rewindIn.data(), 64);

        RingBufferAudioSampleProvider rewindProvider(&rewindRing, 0);
        std::vector<int16_t> firstOut(32 * kChannels, 0);
        AudioWindowRequest firstReq{0, 32, kSampleRate, kChannels, 0};
        AudioWindowBuffer firstBuf{firstOut.data(), static_cast<int64_t>(firstOut.size()), 0, false};
        const auto firstStatus = rewindProvider.provide(firstReq, firstBuf);

        const uint64_t rewindRejectsBefore = rewindProvider.rewindRejects();
        std::vector<int16_t> rewindOut(16 * kChannels, 222);
        const std::vector<int16_t> rewindOutBefore = rewindOut;
        AudioWindowRequest rewindReq{10, 16, kSampleRate, kChannels, 0}; // < expectedNextFrame_(32)
        AudioWindowBuffer rewindBuf{rewindOut.data(), static_cast<int64_t>(rewindOut.size()), 0, false};
        const auto rewindStatus = rewindProvider.provide(rewindReq, rewindBuf);

        std::vector<int16_t> resumeOut(16 * kChannels, 0);
        AudioWindowRequest resumeReq{32, 16, kSampleRate, kChannels, 0};
        AudioWindowBuffer resumeBuf{resumeOut.data(), static_cast<int64_t>(resumeOut.size()), 0, false};
        const auto resumeStatus = rewindProvider.provide(resumeReq, resumeBuf);
        bool resumeMatches = resumeStatus.ok() && !resumeBuf.silent;
        for (int64_t i = 0; i < static_cast<int64_t>(resumeOut.size()) && resumeMatches; ++i) {
            if (resumeOut[i] != rewindIn[32 * kChannels + i]) resumeMatches = false;
        }

        metricRewindRejects = rewindProvider.rewindRejects();

        rewindRejectOk = firstStatus.ok() && !rewindStatus.ok() &&
            rewindProvider.rewindRejects() == rewindRejectsBefore + 1 &&
            rewindOut == rewindOutBefore && resumeMatches;
        if (!rewindRejectOk && failureReason.empty()) failureReason = "rewind_reject_failed";
    }

    // ── 11. forwardSkipBoundedOk: forward gap discards through the skipped range ──
    {
        AudioSpscAudioRingBuffer skipRing(kSampleRate, kChannels, 256);
        std::vector<int16_t> skipIn(200 * kChannels);
        for (int64_t f = 0; f < 200; ++f) {
            skipIn[f * kChannels + 0] = static_cast<int16_t>(f);
            skipIn[f * kChannels + 1] = static_cast<int16_t>(f);
        }
        skipRing.tryPushFrames(skipIn.data(), 200);

        RingBufferAudioSampleProvider skipProvider(&skipRing, 0);
        const uint64_t skipBefore = skipProvider.forwardSkipFrames();
        std::vector<int16_t> skipOut(20 * kChannels, 0);
        AudioWindowRequest skipReq{50, 20, kSampleRate, kChannels, 0}; // skip ahead by 50 from cursor 0
        AudioWindowBuffer skipBuf{skipOut.data(), static_cast<int64_t>(skipOut.size()), 0, false};
        const auto skipStatus = skipProvider.provide(skipReq, skipBuf);

        bool contentMatches = skipStatus.ok() && !skipBuf.silent;
        for (int64_t f = 0; f < 20 && contentMatches; ++f) {
            if (skipOut[f * kChannels + 0] != static_cast<int16_t>(50 + f) ||
                skipOut[f * kChannels + 1] != static_cast<int16_t>(50 + f)) {
                contentMatches = false;
            }
        }

        metricForwardSkipFrames = skipProvider.forwardSkipFrames();

        forwardSkipBoundedOk = contentMatches &&
            skipProvider.forwardSkipFrames() == skipBefore + 50 &&
            skipProvider.expectedNextFrame() == 70;
        if (!forwardSkipBoundedOk && failureReason.empty()) failureReason = "forward_skip_bounded_failed";
    }

    // ── 12. flushDrainSemanticsOk ──
    {
        AudioSpscAudioRingBuffer flushRing(kSampleRate, kChannels, 128);
        std::vector<int16_t> flushIn(64 * kChannels, 7);
        flushRing.tryPushFrames(flushIn.data(), 64);
        const int64_t availBefore = flushRing.availableReadFrames();
        flushRing.discardAllOnReaderThread();
        const int64_t availAfter = flushRing.availableReadFrames();
        std::vector<int16_t> flushOut(8 * kChannels, -1);
        const int64_t poppedAfterFlush = flushRing.tryPopFrames(flushOut.data(), 8);

        flushDrainSemanticsOk = availBefore == 64 && availAfter == 0 && poppedAfterFlush == 0;
        if (!flushDrainSemanticsOk && failureReason.empty()) failureReason = "flush_drain_semantics_failed";
    }

    // ── 13. seekEpochHandshakeOk: pre-seek discarded, post-seek delivered, ack observed ──
    {
        AudioSpscAudioRingBuffer seekRing(kSampleRate, kChannels, 128);
        std::vector<int16_t> preSeekIn(30 * kChannels, 111);
        seekRing.tryPushFrames(preSeekIn.data(), 30);

        RingBufferAudioSampleProvider seekProvider(&seekRing, 0);
        constexpr int64_t kSeekTarget = 500;
        const bool seekRequested = seekRing.requestSeek(kSeekTarget);
        const uint32_t seekReqEpoch = seekRing.seekRequest();

        std::vector<int16_t> firstOut(10 * kChannels, 0);
        AudioWindowRequest firstReq{kSeekTarget, 10, kSampleRate, kChannels, 0};
        AudioWindowBuffer firstBuf{firstOut.data(), static_cast<int64_t>(firstOut.size()), 0, false};
        const auto firstStatus = seekProvider.provide(firstReq, firstBuf);
        const bool preSeekDiscarded = seekRing.availableReadFrames() == 0;
        const bool firstIsSilentSinceDrained = firstStatus.ok() && firstBuf.silent;

        std::vector<int16_t> postSeekIn(10 * kChannels, 222);
        seekRing.tryPushFrames(postSeekIn.data(), 10);

        std::vector<int16_t> secondOut(10 * kChannels, 0);
        AudioWindowRequest secondReq{kSeekTarget + 10, 10, kSampleRate, kChannels, 0};
        AudioWindowBuffer secondBuf{secondOut.data(), static_cast<int64_t>(secondOut.size()), 0, false};
        const auto secondStatus = seekProvider.provide(secondReq, secondBuf);
        const bool postSeekDelivered = secondStatus.ok() && !secondBuf.silent && secondOut == postSeekIn;

        const bool ackObserved = seekRing.seekAck() == seekReqEpoch;

        metricSeekRequest = seekRing.seekRequest();
        metricSeekAck     = seekRing.seekAck();

        seekEpochHandshakeOk = seekRequested && preSeekDiscarded && firstIsSilentSinceDrained &&
            postSeekDelivered && ackObserved && seekProvider.expectedNextFrame() == kSeekTarget + 20;
        if (!seekEpochHandshakeOk && failureReason.empty()) failureReason = "seek_epoch_handshake_failed";
    }

    // ── 14. concurrentProducerConsumerOk: real std::thread writer, main-thread reader ──
    {
        constexpr int64_t kConcurrentTotalFrames  = 1000000;
        constexpr int      kConcurrentRepetitions = 20;
        constexpr int64_t kConcurrentFramesPerRep = kConcurrentTotalFrames / kConcurrentRepetitions;
        // Capacity/chunk sized well above the overrun-lane's deliberately tiny
        // rings so this lane exercises real cross-thread handoff without
        // pathological full-ring spin under physical-device scheduling
        // jitter (thermal throttling, core migration, background load).
        constexpr int64_t kConcurrentRingCapacity = 16384;
        constexpr int64_t kConcurrentChunkFrames  = 2048;
        // Fail-closed bounds: the JNI call must always return PASS/FAIL, not
        // hang. A per-rep stall (no consumer progress) or an overall budget
        // breach signals the writer to stop, joins it, and marks the lane
        // failed rather than blocking the harness indefinitely.
        const auto kConcurrentStallBudget   = std::chrono::seconds(3);
        const auto kConcurrentOverallBudget = std::chrono::seconds(15);

        bool allRepsOk = true;
        bool watchdogTimedOut = false;
        int64_t framesTotal = 0;
        uint64_t producerChecksumTotal = 0;
        uint64_t consumerChecksumTotal = 0;

        const auto overallDeadline = std::chrono::steady_clock::now() + kConcurrentOverallBudget;

        for (int rep = 0; rep < kConcurrentRepetitions && allRepsOk && !watchdogTimedOut; ++rep) {
            AudioSpscAudioRingBuffer ring(kSampleRate, kChannels, kConcurrentRingCapacity);
            std::atomic<bool> stopRequested{false};
            uint64_t producerChecksum = 0;
            uint64_t consumerChecksum = 0;

            std::thread writer([&]() {
                std::vector<int16_t> chunk(static_cast<size_t>(kConcurrentChunkFrames) * kChannels);
                int64_t produced = 0;
                while (produced < kConcurrentFramesPerRep &&
                       !stopRequested.load(std::memory_order_relaxed)) {
                    const int64_t remaining   = kConcurrentFramesPerRep - produced;
                    const int64_t chunkFrames = std::min<int64_t>(kConcurrentChunkFrames, remaining);
                    for (int64_t f = 0; f < chunkFrames; ++f) {
                        const int64_t globalFrame = produced + f;
                        const int16_t sample = static_cast<int16_t>((globalFrame * 7 + rep) & 0x7FFF);
                        chunk[f * kChannels + 0] = sample;
                        chunk[f * kChannels + 1] = sample;
                    }
                    int64_t offset = 0;
                    while (offset < chunkFrames && !stopRequested.load(std::memory_order_relaxed)) {
                        const int64_t accepted =
                            ring.tryPushFrames(chunk.data() + offset * kChannels, chunkFrames - offset);
                        for (int64_t f2 = 0; f2 < accepted; ++f2) {
                            const int16_t s0 = chunk[(offset + f2) * kChannels + 0];
                            const int16_t s1 = chunk[(offset + f2) * kChannels + 1];
                            producerChecksum = producerChecksum * 1000003ull + static_cast<uint64_t>(static_cast<uint16_t>(s0));
                            producerChecksum = producerChecksum * 1000003ull + static_cast<uint64_t>(static_cast<uint16_t>(s1));
                        }
                        offset += accepted;
                        if (accepted == 0) {
                            std::this_thread::yield();
                        }
                    }
                    produced += chunkFrames;
                }
            });

            std::vector<int16_t> popChunk(static_cast<size_t>(kConcurrentChunkFrames) * kChannels);
            int64_t consumed = 0;
            bool repStalled = false;
            auto lastProgressAt = std::chrono::steady_clock::now();
            while (consumed < kConcurrentFramesPerRep) {
                const int64_t popped = ring.tryPopFrames(popChunk.data(), kConcurrentChunkFrames);
                if (popped <= 0) {
                    const auto now = std::chrono::steady_clock::now();
                    if (now - lastProgressAt > kConcurrentStallBudget || now > overallDeadline) {
                        repStalled = true;
                        break;
                    }
                    std::this_thread::yield();
                    continue;
                }
                for (int64_t f2 = 0; f2 < popped; ++f2) {
                    const int16_t s0 = popChunk[f2 * kChannels + 0];
                    const int16_t s1 = popChunk[f2 * kChannels + 1];
                    consumerChecksum = consumerChecksum * 1000003ull + static_cast<uint64_t>(static_cast<uint16_t>(s0));
                    consumerChecksum = consumerChecksum * 1000003ull + static_cast<uint64_t>(static_cast<uint16_t>(s1));
                }
                consumed += popped;
                lastProgressAt = std::chrono::steady_clock::now();
            }

            if (repStalled) {
                stopRequested.store(true, std::memory_order_relaxed);
                watchdogTimedOut = true;
            }
            writer.join();

            if (repStalled || producerChecksum != consumerChecksum || consumed != kConcurrentFramesPerRep) {
                allRepsOk = false;
            }
            framesTotal += consumed;
            producerChecksumTotal = producerChecksumTotal * 1000003ull + producerChecksum;
            consumerChecksumTotal = consumerChecksumTotal * 1000003ull + consumerChecksum;
        }

        metricConcurrentFrames      = framesTotal;
        metricConcurrentRepetitions = kConcurrentRepetitions;
        metricProducerChecksum      = producerChecksumTotal;
        metricConsumerChecksum      = consumerChecksumTotal;

        metricFramesPushed = static_cast<uint64_t>(framesTotal);
        metricFramesPopped = static_cast<uint64_t>(framesTotal);

        concurrentProducerConsumerOk = allRepsOk && framesTotal >= kConcurrentTotalFrames &&
            producerChecksumTotal == consumerChecksumTotal;
        if (!concurrentProducerConsumerOk && failureReason.empty()) {
            failureReason = watchdogTimedOut ? "concurrent_producer_consumer_timeout"
                                              : "concurrent_producer_consumer_failed";
        }
    }

    // ── 15. schedulerIntegrationChecksumOk: ring adapter registered on Graph -> AudioMixBusNode ──
    {
        constexpr int32_t kSchedSampleRate      = 48000;
        constexpr int32_t kSchedChannels        = 2;
        constexpr int64_t kSchedMaxFramesPerMix = 1024;
        constexpr int64_t kSchedWindowFrames    = 512;
        constexpr int64_t kSchedRingCapacity    = 1024;

        Graph schedGraph;
        auto schedMix  = std::make_shared<AudioMixBusNode>("ring_mix", kSchedSampleRate, kSchedChannels, kSchedMaxFramesPerMix);
        auto schedSrc0 = std::make_shared<DecodedAudioPcmSourceNode>("ring_src0", kSchedSampleRate, kSchedChannels, 4800, 0);
        auto schedSrc1 = std::make_shared<DecodedAudioPcmSourceNode>("ring_src1", kSchedSampleRate, kSchedChannels, 4800, 0);
        schedGraph.addNode(schedMix);
        schedGraph.addNode(schedSrc0);
        schedGraph.addNode(schedSrc1);
        schedGraph.connect("ring_src0", "audio_out", "ring_mix", "primary_audio_in");
        schedGraph.connect("ring_src1", "audio_out", "ring_mix", "secondary_audio_in");

        AudioSpscAudioRingBuffer schedRing0(kSchedSampleRate, kSchedChannels, kSchedRingCapacity);
        AudioSpscAudioRingBuffer schedRing1(kSchedSampleRate, kSchedChannels, kSchedRingCapacity);

        std::vector<int16_t> schedPcm0(static_cast<size_t>(kSchedWindowFrames) * kSchedChannels);
        std::vector<int16_t> schedPcm1(static_cast<size_t>(kSchedWindowFrames) * kSchedChannels);
        for (size_t i = 0; i < schedPcm0.size(); ++i) {
            schedPcm0[i] = static_cast<int16_t>(static_cast<int64_t>((i * 41) % 1801) - 900);
        }
        for (size_t i = 0; i < schedPcm1.size(); ++i) {
            schedPcm1[i] = static_cast<int16_t>(static_cast<int64_t>((i * 59) % 1301) - 600);
        }
        schedRing0.tryPushFrames(schedPcm0.data(), kSchedWindowFrames);
        schedRing1.tryPushFrames(schedPcm1.data(), kSchedWindowFrames);

        RingBufferAudioSampleProvider schedProvider0(&schedRing0, 0);
        RingBufferAudioSampleProvider schedProvider1(&schedRing1, 0);
        std::unordered_map<std::string, AudioSampleProvider*> schedProviders = {
            {"ring_src0", &schedProvider0},
            {"ring_src1", &schedProvider1},
        };
        GraphAudioScheduler schedScheduler(schedGraph, "ring_mix", schedProviders);

        std::vector<int16_t> schedOut(static_cast<size_t>(kSchedWindowFrames) * kSchedChannels, 0);
        GraphAudioScheduler::SchedulerOutput schedOutMeta;
        const auto schedRes = schedScheduler.renderWindow(
            0, kSchedWindowFrames, schedOut.data(), static_cast<int64_t>(schedOut.size()), &schedOutMeta);

        std::vector<int16_t> directOut(static_cast<size_t>(kSchedWindowFrames) * kSchedChannels, 0);
        AudioMixBusNode::MixTrack tracks[2] = {
            AudioMixBusNode::MixTrack{schedPcm0.data(), kSchedWindowFrames, kSchedSampleRate, kSchedChannels, 1.0},
            AudioMixBusNode::MixTrack{schedPcm1.data(), kSchedWindowFrames, kSchedSampleRate, kSchedChannels, 1.0},
        };
        AudioMixBusNode::MixOutput directOutMeta;
        const auto directRes = schedMix->mix(tracks, 2, kSchedWindowFrames, directOut.data(),
                                             static_cast<int64_t>(directOut.size()), &directOutMeta);

        schedulerIntegrationChecksumOk = schedRes == SchedulerResult::kOk && schedOutMeta.mixCalled &&
            !schedOutMeta.silence && directRes == AudioMixBusNode::MixResult::kOk &&
            directOutMeta.checksum == schedOutMeta.checksum && directOut == schedOut;
        if (!schedulerIntegrationChecksumOk && failureReason.empty()) failureReason = "scheduler_integration_checksum_failed";
    }

    // ── 16. teardownWhileQuiescedOk: construct/use/quiesce/destroy without crash ──
    {
        bool innerOk = true;
        try {
            AudioSpscAudioRingBuffer teardownRing(kSampleRate, kChannels, 128);
            std::vector<int16_t> teardownPcm(32 * kChannels, 5);
            teardownRing.tryPushFrames(teardownPcm.data(), 32);

            RingBufferAudioSampleProvider teardownProvider(&teardownRing, 0);
            std::vector<int16_t> teardownOut(32 * kChannels, 0);
            AudioWindowRequest teardownReq{0, 32, kSampleRate, kChannels, 0};
            AudioWindowBuffer teardownBuf{teardownOut.data(), static_cast<int64_t>(teardownOut.size()), 0, false};
            const auto teardownStatus = teardownProvider.provide(teardownReq, teardownBuf);
            if (!teardownStatus.ok()) innerOk = false;

            teardownRing.discardAllOnReaderThread();
            if (teardownRing.availableReadFrames() != 0) innerOk = false;
            // teardownProvider and teardownRing destruct here, fully quiesced.
        } catch (...) {
            innerOk = false;
        }
        teardownWhileQuiescedOk = innerOk;
        if (!teardownWhileQuiescedOk && failureReason.empty()) failureReason = "teardown_while_quiesced_failed";
    }

    // ── 17. lifecycleOk: constructor validation contract (throws/succeeds as documented) ──
    {
        bool threwForInvalidSampleRate = false;
        try {
            AudioSpscAudioRingBuffer bad(0, kChannels, 128);
            (void)bad;
        } catch (const std::invalid_argument&) {
            threwForInvalidSampleRate = true;
        } catch (...) {
        }

        bool threwForInvalidChannel = false;
        try {
            AudioSpscAudioRingBuffer bad(kSampleRate, 3, 128);
            (void)bad;
        } catch (const std::invalid_argument&) {
            threwForInvalidChannel = true;
        } catch (...) {
        }

        bool threwForNonPow2 = false;
        try {
            AudioSpscAudioRingBuffer bad(kSampleRate, kChannels, 100);
            (void)bad;
        } catch (const std::invalid_argument&) {
            threwForNonPow2 = true;
        } catch (...) {
        }

        bool threwForOverCapacity = false;
        try {
            AudioSpscAudioRingBuffer bad(kSampleRate, kChannels, 131072);
            (void)bad;
        } catch (const std::invalid_argument&) {
            threwForOverCapacity = true;
        } catch (...) {
        }

        bool validConstructed = true;
        try {
            AudioSpscAudioRingBuffer good(kSampleRate, kChannels, 512);
            (void)good;
        } catch (...) {
            validConstructed = false;
        }

        bool providerRejectsNullRing = false;
        try {
            RingBufferAudioSampleProvider nullProv(nullptr, 0);
            (void)nullProv;
        } catch (const std::invalid_argument&) {
            providerRejectsNullRing = true;
        } catch (...) {
        }

        lifecycleOk = threwForInvalidSampleRate && threwForInvalidChannel && threwForNonPow2 &&
                     threwForOverCapacity && validConstructed && providerRejectsNullRing;
        if (!lifecycleOk && failureReason.empty()) failureReason = "lifecycle_failed";
    }

    const bool allPass = ringSpscLockFreeOk && ringCapacityBoundOk && ringNoAllocationOk &&
                         fifoOrderIntegrityOk && wraparoundIntegrityOk && noTornFrameOk &&
                         overrunRejectOk && underrunZeroFillOk && underrunSilentWindowOk &&
                         rewindRejectOk && forwardSkipBoundedOk && flushDrainSemanticsOk &&
                         seekEpochHandshakeOk && concurrentProducerConsumerOk &&
                         schedulerIntegrationChecksumOk && teardownWhileQuiescedOk &&
                         lifecycleOk && stackScoped;

    std::ostringstream oss;
    oss << "status=" << (allPass ? "PASS" : "FAIL") << ";";
    if (!allPass) {
        oss << "reason=" << (failureReason.empty() ? "unknown_failure" : failureReason) << ";";
    }
    oss << "proofBoundary=" << kProofBoundary << ";"
        << "ringSpscLockFreeOk=" << (ringSpscLockFreeOk ? "true" : "false") << ";"
        << "ringCapacityBoundOk=" << (ringCapacityBoundOk ? "true" : "false") << ";"
        << "ringNoAllocationOk=" << (ringNoAllocationOk ? "true" : "false") << ";"
        << "fifoOrderIntegrityOk=" << (fifoOrderIntegrityOk ? "true" : "false") << ";"
        << "wraparoundIntegrityOk=" << (wraparoundIntegrityOk ? "true" : "false") << ";"
        << "noTornFrameOk=" << (noTornFrameOk ? "true" : "false") << ";"
        << "overrunRejectOk=" << (overrunRejectOk ? "true" : "false") << ";"
        << "underrunZeroFillOk=" << (underrunZeroFillOk ? "true" : "false") << ";"
        << "underrunSilentWindowOk=" << (underrunSilentWindowOk ? "true" : "false") << ";"
        << "rewindRejectOk=" << (rewindRejectOk ? "true" : "false") << ";"
        << "forwardSkipBoundedOk=" << (forwardSkipBoundedOk ? "true" : "false") << ";"
        << "flushDrainSemanticsOk=" << (flushDrainSemanticsOk ? "true" : "false") << ";"
        << "seekEpochHandshakeOk=" << (seekEpochHandshakeOk ? "true" : "false") << ";"
        << "concurrentProducerConsumerOk=" << (concurrentProducerConsumerOk ? "true" : "false") << ";"
        << "schedulerIntegrationChecksumOk=" << (schedulerIntegrationChecksumOk ? "true" : "false") << ";"
        << "teardownWhileQuiescedOk=" << (teardownWhileQuiescedOk ? "true" : "false") << ";"
        << "lifecycleOk=" << (lifecycleOk ? "true" : "false") << ";"
        << "stackScoped=" << (stackScoped ? "true" : "false") << ";"
        << "framesPushed=" << metricFramesPushed << ";"
        << "framesPopped=" << metricFramesPopped << ";"
        << "overrunEvents=" << metricOverrunEvents << ";"
        << "framesRejected=" << metricFramesRejected << ";"
        << "underrunEvents=" << metricUnderrunEvents << ";"
        << "framesZeroFilled=" << metricFramesZeroFilled << ";"
        << "forwardSkipFrames=" << metricForwardSkipFrames << ";"
        << "rewindRejects=" << metricRewindRejects << ";"
        << "seekRequest=" << metricSeekRequest << ";"
        << "seekAck=" << metricSeekAck << ";"
        << "concurrentFrames=" << metricConcurrentFrames << ";"
        << "concurrentRepetitions=" << metricConcurrentRepetitions << ";"
        << "producerChecksum=" << metricProducerChecksum << ";"
        << "consumerChecksum=" << metricConsumerChecksum;

    return oss.str();
}

} // namespace

extern "C" JNIEXPORT jstring JNICALL
Java_com_connects_vanguard_1media_1engine_bridge_VanguardNativeBridge_runAndroidDagPhase4AudioRingBufferTransportSmoke(
    JNIEnv* env,
    jobject /* this */) {
    try {
        const std::string resultStr = RunAudioRingBufferTransportSmokeInternal();
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
