// P4 True-DAG V4.3 sub-slice G1: native JNI diagnostic session core for the
// future real MediaCodec-to-AudioDecoderRingWriter ingest proof.
//
// Session-based route: Kotlin (a future coordinator, not part of this
// sub-slice) will own MediaCodec/MediaExtractor entirely and hand
// already-decoded interleaved little-endian signed PCM16 chunks across a
// direct java.nio.ByteBuffer; this translation unit only feeds them through
// the existing AudioDecoderRingWriter -> AudioSpscAudioRingBuffer producer
// seam and drains/verifies them on the ring's reader side.
//
// Honest non-claims:
// - Not a decoder: no MediaCodec/MediaExtractor/AMediaCodec ownership in C++.
// - No AudioTrack/AAudio/OpenSL/Oboe, no realtime or audible playback, no OS
//   callbacks, no C++->Kotlin callbacks.
// - Spawns no native worker threads; each session records its creating
//   std::thread::id and every non-destroy entry point fails closed with
//   status=wrong_owner_thread when driven from any other thread, so one
//   caller thread plays the ring's producer and consumer roles sequentially.
// - No file IO, no wall-clock reads, no locks inside the audio primitives;
//   the only mutex here guards the session registry map lifecycle.
// - No export or pass-2 graph reroute, no streaming/cache, no iOS, no
//   product/editor UI. Writer-local EOS only.
//
// This translation unit is Android-only and must NOT be included in iOS or
// host builds; it is added via the Android-only target_sources block in
// src/CMakeLists.txt.
//
// JNI entry points (VanguardNativeBridge.kt companion object):
//   createAudioDecoderRingIngestSmokeSession  -> jlong handle (0 on failure)
//   ingestAudioDecoderRingPcm16               -> jstring key=value
//   drainAudioDecoderRingIngestSession        -> jstring key=value
//   requestAudioDecoderRingIngestSeek         -> jstring key=value
//   setAudioDecoderRingIngestEos              -> jstring key=value
//   destroyAudioDecoderRingIngestSmokeSession -> jstring key=value

#include <jni.h>

#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <memory>
#include <mutex>
#include <thread>
#include <unordered_map>

#include "vanguard/audio/audio_decoder_ring_writer.h"
#include "vanguard/audio/audio_ring_buffer.h"

namespace {

using vanguard::audio::AudioDecoderRingWriter;
using vanguard::audio::AudioSpscAudioRingBuffer;
using WriterStatus = AudioDecoderRingWriter::Status;

constexpr size_t  kMaxLiveSessions       = 4;
constexpr int64_t kMaxIngestFramesPerCall = AudioDecoderRingWriter::kMaxWriteFrames; // 8192
constexpr int64_t kMaxDrainFramesPerCall  = AudioSpscAudioRingBuffer::kMaxCapacityFrames; // 65536
constexpr int64_t kDrainChunkFrames       = 512;
// 128 chunks * 512 frames covers the largest legal ring in one call while
// keeping the pop loop strictly bounded.
constexpr int     kMaxDrainIterations     = 128;

const char* WriterStatusName(WriterStatus s) {
    switch (s) {
        case WriterStatus::kOk:              return "ok";
        case WriterStatus::kPartialWrite:    return "partial_write";
        case WriterStatus::kRingFull:        return "ring_full";
        case WriterStatus::kFormatMismatch:  return "format_mismatch";
        case WriterStatus::kInvalidArgument: return "invalid_argument";
        case WriterStatus::kAlreadyEos:      return "already_eos";
        case WriterStatus::kAwaitingSeekAck: return "awaiting_seek_ack";
    }
    return "unknown";
}

// Same simple signed-sample accumulation shape as the sub-slice F pipeline
// integration smoke: checksum = checksum * 31 + uint16(sample).
uint64_t AccumulateChecksum(uint64_t checksum, const int16_t* samples, int64_t count) {
    for (int64_t i = 0; i < count; ++i) {
        checksum = checksum * 31u + static_cast<uint64_t>(static_cast<uint16_t>(samples[i]));
    }
    return checksum;
}

// ---------------------------------------------------------------------------
// Diagnostic ring-ingest session. Owns exactly one ring + one writer; all
// non-destroy calls are owner-thread-only, so the per-session counters below
// are plain (non-atomic) owner-thread-private state.
// ---------------------------------------------------------------------------
struct RingIngestSession {
    AudioSpscAudioRingBuffer ring;
    AudioDecoderRingWriter   writer;
    std::thread::id          ownerThreadId;

    // Set by a successful requestSeek; cleared once drain consumes the
    // reader-side ack boundary.
    bool ackPendingSeek{false};

    uint64_t nativeAcceptedChecksum{0};
    int64_t  nativeTotalFramesAccepted{0};
    uint64_t nativeDrainedChecksum{0};
    int64_t  nativeTotalFramesDrained{0};

    RingIngestSession(int32_t sampleRate, int32_t channelCount, int64_t capacityFrames)
        : ring(sampleRate, channelCount, capacityFrames),
          writer(&ring, sampleRate, channelCount),
          ownerThreadId(std::this_thread::get_id()) {}
};

// ---------------------------------------------------------------------------
// Session registry. The mutex guards only this lifecycle map (create/lookup/
// destroy), never the audio primitives. Values are shared_ptr so an entry
// point that looked a session up stays safe even if destroy concurrently
// erases the map entry: the object is freed only when the last reference
// drops.
// ---------------------------------------------------------------------------
std::mutex gRingIngestRegistryMutex;
std::unordered_map<int64_t, std::shared_ptr<RingIngestSession>> gRingIngestSessions;
int64_t gNextRingIngestHandle = 1; // guarded by gRingIngestRegistryMutex

std::shared_ptr<RingIngestSession> FindRingIngestSession(jlong handle) {
    std::lock_guard<std::mutex> lock(gRingIngestRegistryMutex);
    auto it = gRingIngestSessions.find(static_cast<int64_t>(handle));
    return it == gRingIngestSessions.end() ? nullptr : it->second;
}

bool IsPowerOfTwoInRange(int64_t v) {
    return v >= 64 && v <= kMaxDrainFramesPerCall && (v & (v - 1)) == 0;
}

} // namespace

// ---------------------------------------------------------------------------
// JNI: createAudioDecoderRingIngestSmokeSession
// Returns 0 on any invalid input or when the live-session cap is reached.
// ---------------------------------------------------------------------------
extern "C" JNIEXPORT jlong JNICALL
Java_com_connects_vanguard_1media_1engine_bridge_VanguardNativeBridge_00024Companion_createAudioDecoderRingIngestSmokeSession(
    JNIEnv* /* env */,
    jobject /* companion */,
    jint sampleRate,
    jint channelCount,
    jint ringCapacityFrames) {

    if (sampleRate <= 0) return 0;
    if (channelCount != 1 && channelCount != 2) return 0;
    if (!IsPowerOfTwoInRange(static_cast<int64_t>(ringCapacityFrames))) return 0;

    std::shared_ptr<RingIngestSession> session;
    try {
        session = std::make_shared<RingIngestSession>(
            static_cast<int32_t>(sampleRate),
            static_cast<int32_t>(channelCount),
            static_cast<int64_t>(ringCapacityFrames));
    } catch (...) {
        return 0;
    }

    std::lock_guard<std::mutex> lock(gRingIngestRegistryMutex);
    if (gRingIngestSessions.size() >= kMaxLiveSessions) return 0;
    const int64_t handle = gNextRingIngestHandle++;
    gRingIngestSessions[handle] = std::move(session);
    return static_cast<jlong>(handle);
}

// ---------------------------------------------------------------------------
// JNI: ingestAudioDecoderRingPcm16
// Owner-thread-only. Treats `pcm` as interleaved little-endian signed PCM16
// starting at byte offset 0 and clamps the accepted frame count to
// min(frameCount, 8192, capacityFramesFromBuffer).
// ---------------------------------------------------------------------------
extern "C" JNIEXPORT jstring JNICALL
Java_com_connects_vanguard_1media_1engine_bridge_VanguardNativeBridge_00024Companion_ingestAudioDecoderRingPcm16(
    JNIEnv* env,
    jobject /* companion */,
    jlong sessionHandle,
    jobject pcmBufferJ,
    jint frameCount) {

    char status[640];

    const std::shared_ptr<RingIngestSession> session = FindRingIngestSession(sessionHandle);
    if (!session) {
        std::snprintf(status, sizeof(status),
            "status=not_found;framesRequested=%d;framesAccepted=0", static_cast<int>(frameCount));
        return env->NewStringUTF(status);
    }
    if (std::this_thread::get_id() != session->ownerThreadId) {
        std::snprintf(status, sizeof(status),
            "status=wrong_owner_thread;framesRequested=%d;framesAccepted=0",
            static_cast<int>(frameCount));
        return env->NewStringUTF(status);
    }
    if (frameCount <= 0) {
        std::snprintf(status, sizeof(status),
            "status=invalid_frame_count;framesRequested=%d;framesAccepted=0",
            static_cast<int>(frameCount));
        return env->NewStringUTF(status);
    }
    if (!pcmBufferJ) {
        std::snprintf(status, sizeof(status),
            "status=null_pcm_buffer;framesRequested=%d;framesAccepted=0",
            static_cast<int>(frameCount));
        return env->NewStringUTF(status);
    }

    const jlong bufferCapacityBytes = env->GetDirectBufferCapacity(pcmBufferJ);
    if (bufferCapacityBytes < 0) {
        std::snprintf(status, sizeof(status),
            "status=non_direct_buffer;framesRequested=%d;framesAccepted=0",
            static_cast<int>(frameCount));
        return env->NewStringUTF(status);
    }
    void* rawAddr = env->GetDirectBufferAddress(pcmBufferJ);
    if (!rawAddr) {
        std::snprintf(status, sizeof(status),
            "status=direct_buffer_address_unavailable;framesRequested=%d;framesAccepted=0",
            static_cast<int>(frameCount));
        return env->NewStringUTF(status);
    }

    const int64_t bytesPerFrame = 2ll * session->ring.channelCount();
    const int64_t capacityFramesFromBuffer = static_cast<int64_t>(bufferCapacityBytes) / bytesPerFrame;
    if (capacityFramesFromBuffer <= 0) {
        std::snprintf(status, sizeof(status),
            "status=insufficient_buffer_capacity;framesRequested=%d;framesAccepted=0",
            static_cast<int>(frameCount));
        return env->NewStringUTF(status);
    }

    const int64_t framesToWrite = std::min<int64_t>(
        {static_cast<int64_t>(frameCount), kMaxIngestFramesPerCall, capacityFramesFromBuffer});

    const int16_t* pcm = static_cast<const int16_t*>(rawAddr);
    int64_t framesAccepted = 0;
    const WriterStatus writerStatus = session->writer.write(
        pcm, framesToWrite, session->ring.sampleRate(), session->ring.channelCount(),
        &framesAccepted);

    if (framesAccepted > 0) {
        session->nativeAcceptedChecksum = AccumulateChecksum(
            session->nativeAcceptedChecksum, pcm,
            framesAccepted * session->ring.channelCount());
        session->nativeTotalFramesAccepted += framesAccepted;
    }

    const AudioDecoderRingWriter::Metrics& m = session->writer.metrics();
    std::snprintf(status, sizeof(status),
        "status=ok;framesRequested=%d;framesAccepted=%lld;writerStatus=%s;"
        "writerAvailableToWrite=%lld;writerTotalFramesWritten=%llu;"
        "writerPartialWriteEvents=%llu;writerBackpressureRejects=%llu;"
        "nativeAcceptedChecksumHex=%016llx;nativeTotalFramesAccepted=%lld",
        static_cast<int>(frameCount),
        static_cast<long long>(framesAccepted),
        WriterStatusName(writerStatus),
        static_cast<long long>(session->ring.availableWriteFrames()),
        static_cast<unsigned long long>(m.totalFramesWritten),
        static_cast<unsigned long long>(m.partialWriteEvents),
        static_cast<unsigned long long>(m.backpressureRejects),
        static_cast<unsigned long long>(session->nativeAcceptedChecksum),
        static_cast<long long>(session->nativeTotalFramesAccepted));
    return env->NewStringUTF(status);
}

// ---------------------------------------------------------------------------
// JNI: drainAudioDecoderRingIngestSession
// Owner-thread-only reader side. No per-call heap allocation: pops through a
// fixed stack scratch buffer with a strictly bounded iteration count. When a
// seek ack is pending it first consumes the reader-side seek boundary
// (discarding unread frames) before popping PCM.
// ---------------------------------------------------------------------------
extern "C" JNIEXPORT jstring JNICALL
Java_com_connects_vanguard_1media_1engine_bridge_VanguardNativeBridge_00024Companion_drainAudioDecoderRingIngestSession(
    JNIEnv* env,
    jobject /* companion */,
    jlong sessionHandle,
    jint maxFrames) {

    char status[640];

    const std::shared_ptr<RingIngestSession> session = FindRingIngestSession(sessionHandle);
    if (!session) {
        std::snprintf(status, sizeof(status),
            "status=not_found;framesRequested=%d;framesDrained=0", static_cast<int>(maxFrames));
        return env->NewStringUTF(status);
    }
    if (std::this_thread::get_id() != session->ownerThreadId) {
        std::snprintf(status, sizeof(status),
            "status=wrong_owner_thread;framesRequested=%d;framesDrained=0",
            static_cast<int>(maxFrames));
        return env->NewStringUTF(status);
    }
    if (maxFrames < 0) {
        std::snprintf(status, sizeof(status),
            "status=invalid_max_frames;framesRequested=%d;framesDrained=0",
            static_cast<int>(maxFrames));
        return env->NewStringUTF(status);
    }

    bool    seekAckConsumed      = false;
    int64_t discardedFramesOnSeek = 0;
    int64_t newStartFrame        = -1;
    if (session->ackPendingSeek) {
        const int64_t unreadBeforeAck = session->ring.availableReadFrames();
        int64_t ackFrame = -1;
        if (session->ring.consumePendingSeekOnReaderThread(&ackFrame)) {
            seekAckConsumed       = true;
            discardedFramesOnSeek = unreadBeforeAck;
            newStartFrame         = ackFrame;
            session->ackPendingSeek = false;
        }
    }

    // Stack-only scratch: kDrainChunkFrames frames at up to 2 channels.
    int16_t scratch[kDrainChunkFrames * 2];

    const int64_t framesToDrain = std::min<int64_t>(
        static_cast<int64_t>(maxFrames), kMaxDrainFramesPerCall);
    const int32_t channels = session->ring.channelCount();

    int64_t framesDrained = 0;
    int64_t remaining     = framesToDrain;
    for (int iter = 0; iter < kMaxDrainIterations && remaining > 0; ++iter) {
        const int64_t want = std::min<int64_t>(remaining, kDrainChunkFrames);
        const int64_t got  = session->ring.tryPopFrames(scratch, want);
        if (got <= 0) break;
        session->nativeDrainedChecksum = AccumulateChecksum(
            session->nativeDrainedChecksum, scratch, got * channels);
        framesDrained += got;
        remaining     -= got;
        if (got < want) break; // ring empty mid-chunk
    }
    session->nativeTotalFramesDrained += framesDrained;

    std::snprintf(status, sizeof(status),
        "status=ok;framesRequested=%d;framesDrained=%lld;availableReadAfterDrain=%lld;"
        "nativeDrainedChecksumHex=%016llx;nativeTotalFramesDrained=%lld;"
        "seekAckConsumed=%s;discardedFramesOnSeek=%lld;newStartFrame=%lld",
        static_cast<int>(maxFrames),
        static_cast<long long>(framesDrained),
        static_cast<long long>(session->ring.availableReadFrames()),
        static_cast<unsigned long long>(session->nativeDrainedChecksum),
        static_cast<long long>(session->nativeTotalFramesDrained),
        seekAckConsumed ? "true" : "false",
        static_cast<long long>(discardedFramesOnSeek),
        static_cast<long long>(newStartFrame));
    return env->NewStringUTF(status);
}

// ---------------------------------------------------------------------------
// JNI: requestAudioDecoderRingIngestSeek
// Owner-thread-only producer side. Publishes the seek request via
// writer.requestSeek(); the ack is consumed later by drain on the reader side.
// ---------------------------------------------------------------------------
extern "C" JNIEXPORT jstring JNICALL
Java_com_connects_vanguard_1media_1engine_bridge_VanguardNativeBridge_00024Companion_requestAudioDecoderRingIngestSeek(
    JNIEnv* env,
    jobject /* companion */,
    jlong sessionHandle,
    jlong targetFrame) {

    char status[256];

    const std::shared_ptr<RingIngestSession> session = FindRingIngestSession(sessionHandle);
    if (!session) {
        std::snprintf(status, sizeof(status),
            "status=not_found;targetFrame=%lld;seekRequests=0",
            static_cast<long long>(targetFrame));
        return env->NewStringUTF(status);
    }
    if (std::this_thread::get_id() != session->ownerThreadId) {
        // Do not read non-atomic writer state from a foreign thread; report a
        // fixed placeholder count on this fail-closed path.
        std::snprintf(status, sizeof(status),
            "status=wrong_owner_thread;targetFrame=%lld;seekRequests=0",
            static_cast<long long>(targetFrame));
        return env->NewStringUTF(status);
    }

    const WriterStatus seekStatus = session->writer.requestSeek(static_cast<int64_t>(targetFrame));
    if (seekStatus == WriterStatus::kOk) {
        session->ackPendingSeek = true;
    }

    std::snprintf(status, sizeof(status),
        "status=%s;targetFrame=%lld;seekRequests=%llu",
        WriterStatusName(seekStatus),
        static_cast<long long>(targetFrame),
        static_cast<unsigned long long>(session->writer.metrics().seekRequests));
    return env->NewStringUTF(status);
}

// ---------------------------------------------------------------------------
// JNI: setAudioDecoderRingIngestEos
// Owner-thread-only. Writer-local EOS only (cleared by the next successful
// seek request inside AudioDecoderRingWriter).
// ---------------------------------------------------------------------------
extern "C" JNIEXPORT jstring JNICALL
Java_com_connects_vanguard_1media_1engine_bridge_VanguardNativeBridge_00024Companion_setAudioDecoderRingIngestEos(
    JNIEnv* env,
    jobject /* companion */,
    jlong sessionHandle) {

    char status[128];

    const std::shared_ptr<RingIngestSession> session = FindRingIngestSession(sessionHandle);
    if (!session) {
        std::snprintf(status, sizeof(status), "status=not_found;eos=false");
        return env->NewStringUTF(status);
    }
    if (std::this_thread::get_id() != session->ownerThreadId) {
        // Do not read non-atomic writer state from a foreign thread; report a
        // fixed placeholder flag on this fail-closed path.
        std::snprintf(status, sizeof(status), "status=wrong_owner_thread;eos=false");
        return env->NewStringUTF(status);
    }

    session->writer.setEos();
    std::snprintf(status, sizeof(status), "status=ok;eos=%s",
        session->writer.isEos() ? "true" : "false");
    return env->NewStringUTF(status);
}

// ---------------------------------------------------------------------------
// JNI: destroyAudioDecoderRingIngestSmokeSession
// Callable from any thread. Idempotent erase-once: handle 0/unknown returns
// status=not_found; a live handle is erased exactly once and returns
// status=ok. A concurrently in-flight call keeps its shared_ptr reference,
// so the session is freed only when the last reference drops (no leaks, no
// use-after-free).
// ---------------------------------------------------------------------------
extern "C" JNIEXPORT jstring JNICALL
Java_com_connects_vanguard_1media_1engine_bridge_VanguardNativeBridge_00024Companion_destroyAudioDecoderRingIngestSmokeSession(
    JNIEnv* env,
    jobject /* companion */,
    jlong sessionHandle) {

    bool erased = false;
    {
        std::lock_guard<std::mutex> lock(gRingIngestRegistryMutex);
        erased = gRingIngestSessions.erase(static_cast<int64_t>(sessionHandle)) > 0;
    }
    return env->NewStringUTF(erased ? "status=ok" : "status=not_found");
}
