#include "vg_native_waveform_extractor.h"

#include <media/NdkMediaExtractor.h>
#include <media/NdkMediaFormat.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/stat.h>
#include <cmath>
#include <vector>
#include <cstring>
#include <algorithm>

#define DR_MP3_IMPLEMENTATION
#include "dr_mp3.h"

#include "aacdec.h"

namespace vanguard {

static VgNativeWaveformResult extractMp3Direct(
    const std::string& path,
    int32_t samplesPerSecond,
    double maxDurationSeconds,
    double fallbackDurationSeconds
) {
    VgNativeWaveformResult res;
    res.samplesPerSecond = samplesPerSecond;

    drmp3 mp3;
    if (!drmp3_init_file(&mp3, path.c_str(), nullptr)) {
        res.success = false;
        res.errorMessage = "DR_MP3_INIT_FAILED";
        return res;
    }

    int sampleRate = mp3.sampleRate;
    int channels = mp3.channels;
    if (sampleRate <= 0 || channels <= 0) {
        drmp3_uninit(&mp3);
        res.success = false;
        res.errorMessage = "INVALID_AUDIO_FORMAT";
        return res;
    }

    int windowTarget = std::round((double)sampleRate / (double)samplesPerSecond) * channels;
    if (windowTarget < 1) windowTarget = 1;

    size_t estimatedPoints = 1000;
    if (fallbackDurationSeconds > 0.0) {
        estimatedPoints = (size_t)(fallbackDurationSeconds * samplesPerSecond) + 32;
    }
    res.samples.reserve(estimatedPoints);

    const size_t CHUNK_FRAMES = 2048;
    std::vector<float> pcm(CHUNK_FRAMES * channels);
    double sumSquares = 0.0;
    int windowCount = 0;
    uint64_t totalDecodedFrames = 0;

    while (true) {
        drmp3_uint64 framesRead = drmp3_read_pcm_frames_f32(&mp3, CHUNK_FRAMES, pcm.data());
        if (framesRead == 0) break;
        totalDecodedFrames += framesRead;

        size_t sampleCount = framesRead * channels;
        size_t sampleIdx = 0;
        while (sampleIdx < sampleCount) {
            int need = windowTarget - windowCount;
            int avail = (int)(sampleCount - sampleIdx);
            int take = (avail < need) ? avail : need;

            double blockSum = 0.0;
            const float* src = &pcm[sampleIdx];
            for (int i = 0; i < take; ++i) {
                float s = src[i];
                blockSum += (double)s * s;
            }
            sumSquares += blockSum;
            sampleIdx += take;
            windowCount += take;

            if (windowCount >= windowTarget) {
                float rms = (float)std::sqrt(sumSquares / (double)windowTarget);
                if (rms > 1.0f) rms = 1.0f;
                if (rms < 0.0f) rms = 0.0f;
                res.samples.push_back(rms);
                sumSquares = 0.0;
                windowCount = 0;
            }
        }
    }

    if (windowCount > 0 && windowCount >= windowTarget / 2) {
        float rms = (float)std::sqrt(sumSquares / (double)windowCount);
        if (rms > 1.0f) rms = 1.0f;
        if (rms < 0.0f) rms = 0.0f;
        res.samples.push_back(rms);
    }

    drmp3_uninit(&mp3);

    double actualDuration = (double)totalDecodedFrames / (double)sampleRate;
    if (actualDuration <= 0.0 && fallbackDurationSeconds > 0.0) {
        actualDuration = fallbackDurationSeconds;
    }

    if (actualDuration > maxDurationSeconds) {
        res.success = false;
        res.errorMessage = "DURATION_EXCEEDED";
        return res;
    }

    res.durationSeconds = actualDuration;
    res.pointCount = (int32_t)res.samples.size();
    res.success = (res.pointCount > 0);
    return res;
}

static VgNativeWaveformResult extractAacStream(
    AMediaExtractor* extractor,
    int audioTrackIndex,
    int32_t sampleRate,
    int32_t channelCount,
    double durationSeconds,
    int32_t samplesPerSecond,
    double maxDurationSeconds
) {
    VgNativeWaveformResult res;
    res.samplesPerSecond = samplesPerSecond;
    res.durationSeconds = durationSeconds;

    if (durationSeconds > maxDurationSeconds) {
        res.success = false;
        res.errorMessage = "DURATION_EXCEEDED";
        return res;
    }

    AMediaExtractor_selectTrack(extractor, audioTrackIndex);

    HAACDecoder decoder = AACInitDecoder();
    if (!decoder) {
        res.success = false;
        res.errorMessage = "AAC_INIT_FAILED";
        return res;
    }

    AACFrameInfo frameInfo;
    memset(&frameInfo, 0, sizeof(frameInfo));
    frameInfo.nChans = channelCount;
    frameInfo.sampRateCore = sampleRate;
    frameInfo.profile = AAC_PROFILE_LC;
    AACSetRawBlockParams(decoder, 0, &frameInfo);

    int windowTarget = std::round((double)sampleRate / (double)samplesPerSecond) * channelCount;
    if (windowTarget < 1) windowTarget = 1;

    size_t estimatedPoints = (size_t)(durationSeconds * samplesPerSecond) + 32;
    res.samples.reserve(estimatedPoints > 64 ? estimatedPoints : 64);

    std::vector<uint8_t> inBuf(64 * 1024);
    short outPcm[4096]; // 2048 samples * 2 channels

    int64_t sumSquaresLong = 0;
    int windowCount = 0;
    int decodedFrames = 0;

    while (true) {
        ssize_t sampleSize = AMediaExtractor_readSampleData(extractor, inBuf.data(), inBuf.size());
        if (sampleSize < 0) break;

        unsigned char* inPtr = inBuf.data();
        int bytesLeft = (int)sampleSize;

        int rc = AACDecode(decoder, &inPtr, &bytesLeft, outPcm);
        if (rc == 0) {
            decodedFrames++;
            AACFrameInfo curInfo;
            AACGetLastFrameInfo(decoder, &curInfo);
            int totalSamps = curInfo.outputSamps;
            int sampleIdx = 0;
            while (sampleIdx < totalSamps) {
                int need = windowTarget - windowCount;
                int avail = totalSamps - sampleIdx;
                int take = (avail < need) ? avail : need;

                int64_t blockSum = 0;
                const short* src = &outPcm[sampleIdx];
                for (int i = 0; i < take; ++i) {
                    int s = src[i];
                    blockSum += (int64_t)s * s;
                }
                sumSquaresLong += blockSum;
                sampleIdx += take;
                windowCount += take;

                if (windowCount >= windowTarget) {
                    double meanSquare = (double)sumSquaresLong / ((double)windowTarget * 1073741824.0);
                    float rms = (float)std::sqrt(meanSquare);
                    if (rms > 1.0f) rms = 1.0f;
                    if (rms < 0.0f) rms = 0.0f;
                    res.samples.push_back(rms);
                    sumSquaresLong = 0;
                    windowCount = 0;
                }
            }
        }

        AMediaExtractor_advance(extractor);
    }

    if (windowCount > 0 && windowCount >= windowTarget / 2) {
        double meanSquare = (double)sumSquaresLong / ((double)windowCount * 1073741824.0);
        float rms = (float)std::sqrt(meanSquare);
        if (rms > 1.0f) rms = 1.0f;
        if (rms < 0.0f) rms = 0.0f;
        res.samples.push_back(rms);
    }

    AACFreeDecoder(decoder);

    res.pointCount = (int32_t)res.samples.size();
    res.success = (decodedFrames > 0 && res.pointCount > 0);
    if (!res.success) {
        res.errorMessage = "AAC_DECODE_FAILED";
    }
    return res;
}

VgNativeWaveformResult VgNativeWaveformExtractor::extract(
    const std::string& path,
    int32_t samplesPerSecond,
    double maxDurationSeconds
) {
    VgNativeWaveformResult failure;
    failure.success = false;

    if (path.empty() || samplesPerSecond < 1 || samplesPerSecond > 1000 || maxDurationSeconds <= 0.0) {
        failure.errorMessage = "INVALID_ARG";
        return failure;
    }

    int fd = open(path.c_str(), O_RDONLY);
    if (fd < 0) {
        failure.errorMessage = "CANNOT_OPEN_FILE";
        return failure;
    }

    struct stat st;
    if (fstat(fd, &st) != 0 || st.st_size <= 0) {
        close(fd);
        failure.errorMessage = "INVALID_FILE_SIZE";
        return failure;
    }

    AMediaExtractor* extractor = AMediaExtractor_new();
    if (!extractor) {
        close(fd);
        failure.errorMessage = "EXTRACTOR_ALLOC_FAILED";
        return failure;
    }

    media_status_t status = AMediaExtractor_setDataSourceFd(extractor, fd, 0, st.st_size);
    close(fd);

    if (status != AMEDIA_OK) {
        AMediaExtractor_delete(extractor);
        failure.errorMessage = "SET_DATA_SOURCE_FAILED";
        return failure;
    }

    size_t numTracks = AMediaExtractor_getTrackCount(extractor);
    int audioTrackIndex = -1;
    AMediaFormat* audioFormat = nullptr;

    for (size_t i = 0; i < numTracks; ++i) {
        AMediaFormat* f = AMediaExtractor_getTrackFormat(extractor, i);
        if (!f) continue;
        const char* mime = nullptr;
        if (AMediaFormat_getString(f, AMEDIAFORMAT_KEY_MIME, &mime) && mime) {
            if (strncmp(mime, "audio/", 6) == 0) {
                audioTrackIndex = (int)i;
                audioFormat = f;
                break;
            }
        }
        AMediaFormat_delete(f);
    }

    if (audioTrackIndex < 0 || !audioFormat) {
        AMediaExtractor_delete(extractor);
        failure.errorMessage = "NO_AUDIO_TRACK";
        return failure;
    }

    int64_t durationUs = 0;
    AMediaFormat_getInt64(audioFormat, AMEDIAFORMAT_KEY_DURATION, &durationUs);
    double durationSeconds = durationUs > 0 ? (double)durationUs / 1000000.0 : 0.0;

    int32_t sampleRate = 0;
    AMediaFormat_getInt32(audioFormat, AMEDIAFORMAT_KEY_SAMPLE_RATE, &sampleRate);

    int32_t channelCount = 0;
    AMediaFormat_getInt32(audioFormat, AMEDIAFORMAT_KEY_CHANNEL_COUNT, &channelCount);

    const char* mime = nullptr;
    AMediaFormat_getString(audioFormat, AMEDIAFORMAT_KEY_MIME, &mime);

    std::string mimeStr = mime ? mime : "";
    AMediaFormat_delete(audioFormat);

    // Fast-path 1: MP3
    if (mimeStr == "audio/mpeg") {
        AMediaExtractor_delete(extractor);
        return extractMp3Direct(path, samplesPerSecond, maxDurationSeconds, durationSeconds);
    }

    // Fast-path 2: AAC (MP4 / M4A / MKV video or audio)
    if (mimeStr == "audio/mp4a-latm" || mimeStr == "audio/aac") {
        VgNativeWaveformResult result = extractAacStream(
            extractor,
            audioTrackIndex,
            sampleRate,
            channelCount,
            durationSeconds,
            samplesPerSecond,
            maxDurationSeconds
        );
        AMediaExtractor_delete(extractor);
        return result;
    }

    // Unhandled codec (e.g. AC3, Opus, FLAC): Cleanly signal fallback to MediaCodec
    AMediaExtractor_delete(extractor);
    failure.errorMessage = "UNSUPPORTED_NATIVE_CODEC";
    return failure;
}

} // namespace vanguard
