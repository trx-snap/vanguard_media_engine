// P4-AUDIO-GRAPH-TRANSPORT-CLOCK sub-slice E: standalone producer-side
// decoder-to-source-ring ingest seam native proof.
//
// Honest non-claims:
// - Does not use MediaCodec, MediaExtractor, AudioTrack, AAudio, OpenSL, or
//   Oboe.
// - Does not perform realtime or audible playback.
// - Does not register an OS callback.
// - Does not spawn threads or take locks.
// - Does not perform file IO.
// - Does not reroute export or touch streaming/cache.
// - Does not touch iOS or product/editor UI.
// - Does not wire DecodedAudioPcmSourceNode.
// - Does not integrate with GraphAudioScheduler or any transport
//   coordinator.
// - Does not resample.
// - Does not produce audible output.
// - EOS tracked here is writer-local only; it is not a ring or decoder
//   concept.
// - AudioDecoderRingWriter never calls
//   consumePendingSeekOnReaderThread(); this translation unit plays the
//   ring's reader role directly (by calling that method itself) purely to
//   simulate the seek-ack handshake for the proof below.
// - Does not close P4-AUDIO-GRAPH-TRANSPORT-CLOCK.
//
// This translation unit is Android-only and must NOT be included in iOS or
// host builds; it is added via the Android-only target_sources block in
// src/CMakeLists.txt.
//
// JNI entry point:
//   runAndroidDagPhase4AudioDecoderRingWriterSmoke -> jstring

#include <jni.h>

#include <cstdint>
#include <sstream>
#include <stdexcept>
#include <string>
#include <vector>

#include "vanguard/audio/audio_decoder_ring_writer.h"
#include "vanguard/audio/audio_ring_buffer.h"

namespace {

constexpr const char* kProofBoundary =
    "native_audio_decoder_ring_writer_to_spsc_source_ring_ingest_proof_only_no_mediacodec_no_mediaextractor_no_audio_track_no_aaudio_no_opensl_no_oboe_no_realtime_playback_no_os_callback_no_threads_no_locks_no_file_io_no_export_reroute_no_streaming_no_ios_no_product_no_source_node_wiring_no_scheduler_integration_no_resample_no_audible_output_writer_local_eos_only";

using vanguard::audio::AudioDecoderRingWriter;
using vanguard::audio::AudioSpscAudioRingBuffer;
using WriterStatus = AudioDecoderRingWriter::Status;

std::vector<int16_t> MakePcm(int64_t frames, int32_t channelCount) {
    std::vector<int16_t> pcm(static_cast<size_t>(frames) * static_cast<size_t>(channelCount));
    for (int64_t f = 0; f < frames; ++f) {
        const int16_t s = static_cast<int16_t>(((f * 53) % 3001) - 1500);
        for (int32_t ch = 0; ch < channelCount; ++ch) {
            pcm[static_cast<size_t>(f) * channelCount + ch] = s;
        }
    }
    return pcm;
}

std::string RunAudioDecoderRingWriterSmokeInternal() {
    bool constructorValidationOk    = false;
    bool writeSuccessOk             = false;
    bool partialWriteOk             = false;
    bool ringFullOk                 = false;
    bool formatMismatchOk           = false;
    bool invalidArgumentOk          = false;
    bool eosOk                      = false;
    bool seekAwaitAckGateOk         = false;
    bool sourceRingBoundaryOk       = false;
    bool noSteadyStateAllocationOk  = false;
    bool lifecycleOk                = false;
    bool stackScoped                = true;

    std::string failureReason;

    constexpr int32_t kSampleRate = 8000;
    constexpr int32_t kChannels   = 1;

    uint64_t metricPartialWriteFramesAccepted = 0;
    uint64_t metricPartialWriteEvents         = 0;
    uint64_t metricBackpressureRejects        = 0;
    uint64_t metricFormatMismatches           = 0;
    uint64_t metricInvalidArgumentRejects     = 0;
    uint64_t metricAwaitingSeekAckRejects     = 0;
    uint64_t metricEosEvents                  = 0;
    uint64_t metricSeekRequests               = 0;
    uint64_t metricTotalFramesWritten         = 0;

    const std::vector<int16_t> pcm200 = MakePcm(200, kChannels);

    // -- 1. constructorValidationOk --
    {
        AudioSpscAudioRingBuffer validRing(kSampleRate, kChannels, 1024);
        AudioDecoderRingWriter validWriter(&validRing, kSampleRate, kChannels);
        const bool freshStateOk = !validWriter.isEos() && validWriter.nextWriteFrame() == 0 &&
            validWriter.expectedSampleRate() == kSampleRate &&
            validWriter.expectedChannelCount() == kChannels;

        bool nullRingThrew = false;
        std::string nullRingWhat;
        try {
            AudioDecoderRingWriter bad(nullptr, kSampleRate, kChannels);
            (void)bad;
        } catch (const std::invalid_argument& e) {
            nullRingThrew = true;
            nullRingWhat  = e.what();
        }

        AudioSpscAudioRingBuffer okRing(kSampleRate, kChannels, 1024);

        bool invalidSampleRateThrew = false;
        std::string invalidSampleRateWhat;
        try {
            AudioDecoderRingWriter bad(&okRing, 0, kChannels);
            (void)bad;
        } catch (const std::invalid_argument& e) {
            invalidSampleRateThrew = true;
            invalidSampleRateWhat  = e.what();
        }

        bool invalidChannelCountThrew = false;
        std::string invalidChannelCountWhat;
        try {
            AudioDecoderRingWriter bad(&okRing, kSampleRate, 0);
            (void)bad;
        } catch (const std::invalid_argument& e) {
            invalidChannelCountThrew = true;
            invalidChannelCountWhat  = e.what();
        }

        bool formatMismatchSampleRateThrew = false;
        std::string formatMismatchSampleRateWhat;
        try {
            AudioDecoderRingWriter bad(&okRing, kSampleRate * 2, kChannels);
            (void)bad;
        } catch (const std::invalid_argument& e) {
            formatMismatchSampleRateThrew = true;
            formatMismatchSampleRateWhat  = e.what();
        }

        bool formatMismatchChannelCountThrew = false;
        std::string formatMismatchChannelCountWhat;
        try {
            AudioDecoderRingWriter bad(&okRing, kSampleRate, kChannels == 1 ? 2 : 1);
            (void)bad;
        } catch (const std::invalid_argument& e) {
            formatMismatchChannelCountThrew = true;
            formatMismatchChannelCountWhat  = e.what();
        }

        constructorValidationOk = freshStateOk &&
            nullRingThrew && nullRingWhat == "null_ring" &&
            invalidSampleRateThrew && invalidSampleRateWhat == "invalid_sample_rate" &&
            invalidChannelCountThrew && invalidChannelCountWhat == "invalid_channel_count" &&
            formatMismatchSampleRateThrew && formatMismatchSampleRateWhat == "format_mismatch" &&
            formatMismatchChannelCountThrew && formatMismatchChannelCountWhat == "format_mismatch";
        if (!constructorValidationOk && failureReason.empty()) failureReason = "constructor_validation_failed";
    }

    // -- 2. writeSuccessOk --
    {
        AudioSpscAudioRingBuffer ring(kSampleRate, kChannels, 1024);
        AudioDecoderRingWriter writer(&ring, kSampleRate, kChannels);

        int64_t framesWritten = -1;
        const WriterStatus result =
            writer.write(pcm200.data(), 100, kSampleRate, kChannels, &framesWritten);

        writeSuccessOk = result == WriterStatus::kOk && framesWritten == 100 &&
            writer.nextWriteFrame() == 100 && writer.metrics().totalFramesWritten == 100 &&
            ring.availableReadFrames() == 100;
        metricTotalFramesWritten = writer.metrics().totalFramesWritten;
        if (!writeSuccessOk && failureReason.empty()) failureReason = "write_success_failed";
    }

    // -- 3. partialWriteOk / 4. ringFullOk (shared rig) --
    {
        AudioSpscAudioRingBuffer ring(kSampleRate, kChannels, 128);
        AudioDecoderRingWriter writer(&ring, kSampleRate, kChannels);

        int64_t firstOut = -1;
        const WriterStatus firstResult =
            writer.write(pcm200.data(), 100, kSampleRate, kChannels, &firstOut);

        int64_t secondOut = -1;
        const WriterStatus secondResult =
            writer.write(pcm200.data(), 50, kSampleRate, kChannels, &secondOut);

        partialWriteOk = firstResult == WriterStatus::kOk && firstOut == 100 &&
            secondResult == WriterStatus::kPartialWrite && secondOut == 28 &&
            writer.nextWriteFrame() == 128 && writer.metrics().totalFramesWritten == 128 &&
            writer.metrics().partialWriteEvents == 1;
        metricPartialWriteFramesAccepted = static_cast<uint64_t>(secondOut);
        metricPartialWriteEvents         = writer.metrics().partialWriteEvents;
        if (!partialWriteOk && failureReason.empty()) failureReason = "partial_write_failed";

        int64_t thirdOut = -1;
        const WriterStatus thirdResult =
            writer.write(pcm200.data(), 10, kSampleRate, kChannels, &thirdOut);

        ringFullOk = thirdResult == WriterStatus::kRingFull && thirdOut == 0 &&
            writer.nextWriteFrame() == 128 && writer.metrics().backpressureRejects == 1;
        metricBackpressureRejects = writer.metrics().backpressureRejects;
        if (!ringFullOk && failureReason.empty()) failureReason = "ring_full_failed";
    }

    // -- 5. formatMismatchOk (also proves format-mismatch precedes EOS) --
    {
        AudioSpscAudioRingBuffer ring(kSampleRate, kChannels, 1024);
        AudioDecoderRingWriter writer(&ring, kSampleRate, kChannels);
        writer.setEos();

        int64_t wrongRateOut = -1;
        const WriterStatus wrongRateResult =
            writer.write(pcm200.data(), 10, kSampleRate * 2, kChannels, &wrongRateOut);

        int64_t wrongChannelsOut = -1;
        const WriterStatus wrongChannelsResult =
            writer.write(pcm200.data(), 10, kSampleRate, kChannels == 1 ? 2 : 1, &wrongChannelsOut);

        formatMismatchOk = wrongRateResult == WriterStatus::kFormatMismatch && wrongRateOut == 0 &&
            wrongChannelsResult == WriterStatus::kFormatMismatch && wrongChannelsOut == 0 &&
            writer.metrics().formatMismatches == 2 && ring.availableReadFrames() == 0;
        metricFormatMismatches = writer.metrics().formatMismatches;
        if (!formatMismatchOk && failureReason.empty()) failureReason = "format_mismatch_failed";
    }

    // -- 6. invalidArgumentOk (also proves invalid-arg precedes format
    //    mismatch, EOS, and awaiting-seek-ack) --
    {
        AudioSpscAudioRingBuffer ring(kSampleRate, kChannels, 1024);
        AudioDecoderRingWriter writer(&ring, kSampleRate, kChannels);

        int64_t nullOut = -1;
        const WriterStatus nullResult = writer.write(nullptr, 10, kSampleRate, kChannels, &nullOut);

        int64_t zeroOut = -1;
        const WriterStatus zeroResult = writer.write(pcm200.data(), 0, kSampleRate, kChannels, &zeroOut);

        int64_t negOut = -1;
        const WriterStatus negResult = writer.write(pcm200.data(), -5, kSampleRate, kChannels, &negOut);

        int64_t overCapOut = -1;
        const WriterStatus overCapResult = writer.write(
            pcm200.data(), AudioDecoderRingWriter::kMaxWriteFrames + 1, kSampleRate, kChannels, &overCapOut);

        // Invalid-arg beats format mismatch: null pcm + wrong sampleRate/channelCount.
        int64_t nullAndFormatOut = -1;
        const WriterStatus nullAndFormatResult =
            writer.write(nullptr, 10, kSampleRate * 2, kChannels == 1 ? 2 : 1, &nullAndFormatOut);

        // Invalid-arg beats EOS.
        AudioSpscAudioRingBuffer eosRing(kSampleRate, kChannels, 1024);
        AudioDecoderRingWriter eosWriter(&eosRing, kSampleRate, kChannels);
        eosWriter.setEos();
        int64_t eosAndInvalidOut = -1;
        const WriterStatus eosAndInvalidResult =
            eosWriter.write(pcm200.data(), 0, kSampleRate, kChannels, &eosAndInvalidOut);

        // Invalid-arg beats awaiting-seek-ack.
        AudioSpscAudioRingBuffer seekRing(kSampleRate, kChannels, 1024);
        AudioDecoderRingWriter seekWriter(&seekRing, kSampleRate, kChannels);
        seekWriter.requestSeek(50);
        int64_t seekAndInvalidOut = -1;
        const WriterStatus seekAndInvalidResult =
            seekWriter.write(nullptr, 10, kSampleRate, kChannels, &seekAndInvalidOut);

        invalidArgumentOk =
            nullResult == WriterStatus::kInvalidArgument && nullOut == 0 &&
            zeroResult == WriterStatus::kInvalidArgument && zeroOut == 0 &&
            negResult == WriterStatus::kInvalidArgument && negOut == 0 &&
            overCapResult == WriterStatus::kInvalidArgument && overCapOut == 0 &&
            nullAndFormatResult == WriterStatus::kInvalidArgument && nullAndFormatOut == 0 &&
            eosAndInvalidResult == WriterStatus::kInvalidArgument && eosAndInvalidOut == 0 &&
            seekAndInvalidResult == WriterStatus::kInvalidArgument && seekAndInvalidOut == 0 &&
            writer.metrics().invalidArgumentRejects == 5;
        metricInvalidArgumentRejects = writer.metrics().invalidArgumentRejects;
        if (!invalidArgumentOk && failureReason.empty()) failureReason = "invalid_argument_failed";
    }

    // -- 7. eosOk --
    {
        AudioSpscAudioRingBuffer ring(kSampleRate, kChannels, 1024);
        AudioDecoderRingWriter writer(&ring, kSampleRate, kChannels);

        writer.setEos();
        const bool firstEosOk = writer.isEos() && writer.metrics().eosEvents == 1;

        writer.setEos(); // idempotent
        const bool secondEosOk = writer.isEos() && writer.metrics().eosEvents == 1;

        int64_t afterEosOut = -1;
        const WriterStatus afterEosResult =
            writer.write(pcm200.data(), 10, kSampleRate, kChannels, &afterEosOut);

        const WriterStatus seekStatus = writer.requestSeek(75);
        const bool clearedByRequestSeek = !writer.isEos();

        // requestSeek() only publishes the request; ack it here (playing the
        // ring's reader role) so the follow-up write is not gated by
        // kAwaitingSeekAck.
        int64_t ackedFrame = -1;
        const bool ackConsumed = ring.consumePendingSeekOnReaderThread(&ackedFrame);

        int64_t afterSeekOut = -1;
        const WriterStatus afterSeekResult =
            writer.write(pcm200.data(), 10, kSampleRate, kChannels, &afterSeekOut);

        eosOk = firstEosOk && secondEosOk &&
            afterEosResult == WriterStatus::kAlreadyEos && afterEosOut == 0 &&
            seekStatus == WriterStatus::kOk && clearedByRequestSeek &&
            ackConsumed && ackedFrame == 75 &&
            afterSeekResult == WriterStatus::kOk && afterSeekOut == 10 &&
            writer.nextWriteFrame() == 85;
        metricEosEvents = writer.metrics().eosEvents;
        if (!eosOk && failureReason.empty()) failureReason = "eos_failed";
    }

    // -- 8. seekAwaitAckGateOk --
    {
        AudioSpscAudioRingBuffer ring(kSampleRate, kChannels, 1024);
        AudioDecoderRingWriter writer(&ring, kSampleRate, kChannels);

        int64_t preSeekOut = -1;
        writer.write(pcm200.data(), 50, kSampleRate, kChannels, &preSeekOut); // -> nextWriteFrame = 50

        const WriterStatus seekStatus = writer.requestSeek(200);
        const bool awaitingAfterSeek = ring.seekRequest() != ring.seekAck();

        const int64_t readableBeforeAwait = ring.availableReadFrames();
        int64_t awaitOut = -1;
        const WriterStatus awaitResult =
            writer.write(pcm200.data(), 10, kSampleRate, kChannels, &awaitOut);
        const int64_t readableAfterAwait = ring.availableReadFrames();

        // EOS precedes awaiting-seek-ack, checked on an independent writer
        // so it does not disturb `writer`'s own EOS-free state.
        AudioSpscAudioRingBuffer precedenceRing(kSampleRate, kChannels, 1024);
        AudioDecoderRingWriter precedenceWriter(&precedenceRing, kSampleRate, kChannels);
        precedenceWriter.requestSeek(300);
        precedenceWriter.setEos();
        int64_t precedenceOut = -1;
        const WriterStatus precedenceResult =
            precedenceWriter.write(pcm200.data(), 10, kSampleRate, kChannels, &precedenceOut);

        int64_t ackedFrame = -1;
        const bool ackConsumed = ring.consumePendingSeekOnReaderThread(&ackedFrame);

        int64_t postSeekOut = -1;
        const WriterStatus postSeekResult =
            writer.write(pcm200.data(), 30, kSampleRate, kChannels, &postSeekOut);

        seekAwaitAckGateOk =
            seekStatus == WriterStatus::kOk && writer.nextWriteFrame() >= 200 &&
            awaitingAfterSeek &&
            awaitResult == WriterStatus::kAwaitingSeekAck && awaitOut == 0 &&
            readableBeforeAwait == readableAfterAwait &&
            precedenceResult == WriterStatus::kAlreadyEos && precedenceOut == 0 &&
            ackConsumed && ackedFrame == 200 &&
            postSeekResult == WriterStatus::kOk && postSeekOut == 30 &&
            writer.nextWriteFrame() == 230;
        metricAwaitingSeekAckRejects = writer.metrics().awaitingSeekAckRejects;
        metricSeekRequests           = writer.metrics().seekRequests;
        if (!seekAwaitAckGateOk && failureReason.empty()) failureReason = "seek_await_ack_gate_failed";
    }

    // -- 9. sourceRingBoundaryOk --
    {
        AudioSpscAudioRingBuffer ring(kSampleRate, kChannels, 1024);
        AudioDecoderRingWriter writer(&ring, kSampleRate, kChannels);

        int64_t pushOut = -1;
        writer.write(pcm200.data(), 40, kSampleRate, kChannels, &pushOut);
        const uint32_t ackBefore = ring.seekAck();
        const int64_t readableBeforeSeek = ring.availableReadFrames();

        const WriterStatus seekStatus = writer.requestSeek(999);

        const bool ackUntouchedByWriter = ring.seekAck() == ackBefore;
        const bool readableUntouchedByRequestSeek = ring.availableReadFrames() == readableBeforeSeek;
        const bool requestPublished = ring.seekRequest() != ackBefore;

        sourceRingBoundaryOk = pushOut == 40 && seekStatus == WriterStatus::kOk &&
            ackUntouchedByWriter && readableUntouchedByRequestSeek && requestPublished;
        if (!sourceRingBoundaryOk && failureReason.empty()) failureReason = "source_ring_boundary_failed";

        // Drain so this ring's lingering seek state does not leak into
        // later reasoning (it is local to this scope regardless).
        int64_t ackedFrame = -1;
        ring.consumePendingSeekOnReaderThread(&ackedFrame);
    }

    // -- 10. noSteadyStateAllocationOk --
    {
        AudioSpscAudioRingBuffer ring(kSampleRate, kChannels, 1024);
        AudioDecoderRingWriter writer(&ring, kSampleRate, kChannels);

        const int64_t ringCapBefore = ring.storageCapacitySamples();

        bool allWritesOk = true;
        constexpr int64_t kFramesPerIteration = 64;
        std::vector<int16_t> drain(static_cast<size_t>(kFramesPerIteration) * kChannels, 0);
        for (int i = 0; i < 100; ++i) {
            int64_t framesWritten = -1;
            const WriterStatus result =
                writer.write(pcm200.data(), kFramesPerIteration, kSampleRate, kChannels, &framesWritten);
            if (result != WriterStatus::kOk || framesWritten != kFramesPerIteration) {
                allWritesOk = false;
                break;
            }
            ring.tryPopFrames(drain.data(), kFramesPerIteration);
        }

        const int64_t ringCapAfter = ring.storageCapacitySamples();

        noSteadyStateAllocationOk = allWritesOk &&
            ringCapBefore > 0 && ringCapBefore == ringCapAfter &&
            writer.metrics().totalFramesWritten == static_cast<uint64_t>(kFramesPerIteration * 100);
        if (!noSteadyStateAllocationOk && failureReason.empty()) failureReason = "no_steady_state_allocation_failed";
    }

    // -- 11. lifecycleOk --
    {
        AudioSpscAudioRingBuffer ring(kSampleRate, kChannels, 1024);
        AudioDecoderRingWriter writer(&ring, kSampleRate, kChannels);

        const bool freshStateOk = !writer.isEos() && writer.nextWriteFrame() == 0 &&
            writer.metrics().totalFramesWritten == 0;

        const WriterStatus negSeekStatus = writer.requestSeek(-1);
        const bool negSeekRejectedCleanly = negSeekStatus == WriterStatus::kInvalidArgument &&
            ring.seekRequest() == 0 && writer.nextWriteFrame() == 0 && writer.metrics().seekRequests == 0;

        AudioSpscAudioRingBuffer maxRing(kSampleRate, kChannels, AudioDecoderRingWriter::kMaxWriteFrames);
        AudioDecoderRingWriter maxWriter(&maxRing, kSampleRate, kChannels);
        const std::vector<int16_t> pcmMax = MakePcm(AudioDecoderRingWriter::kMaxWriteFrames, kChannels);
        int64_t maxOut = -1;
        const WriterStatus maxResult = maxWriter.write(
            pcmMax.data(), AudioDecoderRingWriter::kMaxWriteFrames, kSampleRate, kChannels, &maxOut);
        const bool maxBoundaryOk = maxResult == WriterStatus::kOk &&
            maxOut == AudioDecoderRingWriter::kMaxWriteFrames &&
            maxWriter.nextWriteFrame() == AudioDecoderRingWriter::kMaxWriteFrames;

        maxWriter.setEos();
        const WriterStatus eosThenSeekStatus = maxWriter.requestSeek(1000);
        const bool eosThenSeekOk = eosThenSeekStatus == WriterStatus::kOk && !maxWriter.isEos() &&
            maxWriter.nextWriteFrame() == 1000;

        // Ack the pending seek (reader role) so the follow-up write is not
        // gated by kAwaitingSeekAck.
        int64_t maxAckedFrame = -1;
        const bool maxAckConsumed = maxRing.consumePendingSeekOnReaderThread(&maxAckedFrame);

        int64_t postClearOut = -1;
        const WriterStatus postClearResult =
            maxWriter.write(pcmMax.data(), 10, kSampleRate, kChannels, &postClearOut);
        const bool postClearOk = postClearResult == WriterStatus::kOk && postClearOut == 10 &&
            maxWriter.nextWriteFrame() == 1010;

        lifecycleOk = freshStateOk && negSeekRejectedCleanly && maxBoundaryOk && eosThenSeekOk &&
            maxAckConsumed && maxAckedFrame == 1000 && postClearOk;
        if (!lifecycleOk && failureReason.empty()) failureReason = "lifecycle_failed";
    }

    const bool allPass = constructorValidationOk && writeSuccessOk && partialWriteOk && ringFullOk &&
                         formatMismatchOk && invalidArgumentOk && eosOk && seekAwaitAckGateOk &&
                         sourceRingBoundaryOk && noSteadyStateAllocationOk && lifecycleOk && stackScoped;

    std::ostringstream oss;
    oss << "status=" << (allPass ? "PASS" : "FAIL") << ";";
    if (!allPass) {
        oss << "reason=" << (failureReason.empty() ? "unknown_failure" : failureReason) << ";";
    }
    oss << "proofBoundary=" << kProofBoundary << ";"
        << "constructorValidationOk=" << (constructorValidationOk ? "true" : "false") << ";"
        << "writeSuccessOk=" << (writeSuccessOk ? "true" : "false") << ";"
        << "partialWriteOk=" << (partialWriteOk ? "true" : "false") << ";"
        << "ringFullOk=" << (ringFullOk ? "true" : "false") << ";"
        << "formatMismatchOk=" << (formatMismatchOk ? "true" : "false") << ";"
        << "invalidArgumentOk=" << (invalidArgumentOk ? "true" : "false") << ";"
        << "eosOk=" << (eosOk ? "true" : "false") << ";"
        << "seekAwaitAckGateOk=" << (seekAwaitAckGateOk ? "true" : "false") << ";"
        << "sourceRingBoundaryOk=" << (sourceRingBoundaryOk ? "true" : "false") << ";"
        << "noSteadyStateAllocationOk=" << (noSteadyStateAllocationOk ? "true" : "false") << ";"
        << "lifecycleOk=" << (lifecycleOk ? "true" : "false") << ";"
        << "stackScoped=" << (stackScoped ? "true" : "false") << ";"
        << "partialWriteFramesAccepted=" << metricPartialWriteFramesAccepted << ";"
        << "partialWriteEvents=" << metricPartialWriteEvents << ";"
        << "backpressureRejects=" << metricBackpressureRejects << ";"
        << "formatMismatches=" << metricFormatMismatches << ";"
        << "invalidArgumentRejects=" << metricInvalidArgumentRejects << ";"
        << "awaitingSeekAckRejects=" << metricAwaitingSeekAckRejects << ";"
        << "eosEvents=" << metricEosEvents << ";"
        << "seekRequests=" << metricSeekRequests << ";"
        << "totalFramesWritten=" << metricTotalFramesWritten;

    return oss.str();
}

} // namespace

extern "C" JNIEXPORT jstring JNICALL
Java_com_connects_vanguard_1media_1engine_bridge_VanguardNativeBridge_runAndroidDagPhase4AudioDecoderRingWriterSmoke(
    JNIEnv* env,
    jobject /* this */) {
    try {
        const std::string resultStr = RunAudioDecoderRingWriterSmokeInternal();
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
