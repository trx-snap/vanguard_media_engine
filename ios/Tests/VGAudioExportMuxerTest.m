// VGAudioExportMuxerTest.m
// vanguard_media_engine — Phase 10-C Slice A
//
// Gate tests: VGAudioExportMuxer static-volume parsing correction.
//
// Slice A closure: explicit volume 0.0 must produce a near-silent export,
// not a unity-gain export. Closure tests also prove:
//   - negative volume preserves the prior unity-fallback (audible output);
//   - an omitted volume key defaults to unity (audible output).
//
// PCM analysis: decoded via AVAssetReader with kAudioFormatLinearPCM int16 output.
// Peak absolute sample magnitude is used as the silence/audible discriminator.
// The thresholds (100) are provisional — AAC codec silence may decode with
// small non-zero residuals due to quantization, so exact RMS == 0 is not required.
// A 440 Hz sine wave at unity gain produces a raw peak of ~32767; after AAC
// round-trip the peak remains well above 1000, so 100 is a conservative boundary.
//
// Mock prefix: VGAEM_ (VG Audio Export Muxer)

#import <XCTest/XCTest.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <AudioToolbox/AudioToolbox.h>

#import "VGAudioExportMuxer.h"
#import <UMF/VGAudioSidecarPlan.h>

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - Test fixtures
// ─────────────────────────────────────────────────────────────────────────────

/// Returns a unique temporary file path with the given extension.
static NSString *VGAEM_TempPath(NSString *ext) {
    return [NSTemporaryDirectory()
        stringByAppendingPathComponent:
            [NSString stringWithFormat:@"VGAEM_%@.%@",
             [[NSUUID UUID] UUIDString], ext]];
}

/// Creates a synthetic video-only H.264 128×128 MP4 with `frameCount` frames
/// at `fps`. Audio-free — matches the expected `videoTempPath` input for
/// VGAudioExportMuxer. Returns nil on failure.
/// Adapted from the VGVES_CreateTestAsset pattern in VGVideoExportSessionTest.m.
static NSString * _Nullable VGAEM_CreateVideoOnlyMP4(NSUInteger frameCount,
                                                      double fps) {
    NSString *path = VGAEM_TempPath(@"mp4");
    NSURL *url = [NSURL fileURLWithPath:path];

    NSError *err = nil;
    AVAssetWriter *writer = [AVAssetWriter assetWriterWithURL:url
                                                     fileType:AVFileTypeMPEG4
                                                        error:&err];
    if (!writer || err) return nil;

    NSDictionary *vSettings = @{
        AVVideoCodecKey:  AVVideoCodecTypeH264,
        AVVideoWidthKey:  @(128),
        AVVideoHeightKey: @(128),
    };
    AVAssetWriterInput *videoInput =
        [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeVideo
                                           outputSettings:vSettings];
    videoInput.expectsMediaDataInRealTime = NO;

    NSDictionary *attrs = @{
        (id)kCVPixelBufferPixelFormatTypeKey:     @(kCVPixelFormatType_32BGRA),
        (id)kCVPixelBufferWidthKey:               @(128),
        (id)kCVPixelBufferHeightKey:              @(128),
        (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
    };
    AVAssetWriterInputPixelBufferAdaptor *adaptor =
        [AVAssetWriterInputPixelBufferAdaptor
            assetWriterInputPixelBufferAdaptorWithAssetWriterInput:videoInput
                                     sourcePixelBufferAttributes:attrs];

    if (![writer canAddInput:videoInput]) return nil;
    [writer addInput:videoInput];
    [writer startWriting];
    [writer startSessionAtSourceTime:kCMTimeZero];

    CMTime frameDuration = CMTimeMakeWithSeconds(1.0 / fps, 600);
    for (NSUInteger i = 0; i < frameCount; i++) {
        while (!videoInput.isReadyForMoreMediaData) {
            [NSThread sleepForTimeInterval:0.002];
        }
        CVPixelBufferRef pb = NULL;
        CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool, &pb);
        if (!pb) break;
        CVPixelBufferLockBaseAddress(pb, 0);
        memset(CVPixelBufferGetBaseAddress(pb), (int)(i * 40 + 60),
               CVPixelBufferGetDataSize(pb));
        CVPixelBufferUnlockBaseAddress(pb, 0);
        CMTime pts = CMTimeMultiply(frameDuration, (int32_t)i);
        [adaptor appendPixelBuffer:pb withPresentationTime:pts];
        CVPixelBufferRelease(pb);
    }

    [videoInput markAsFinished];
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    [writer finishWritingWithCompletionHandler:^{ dispatch_semaphore_signal(done); }];
    dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 15LL * NSEC_PER_SEC));

    return (writer.status == AVAssetWriterStatusCompleted) ? path : nil;
}

/// Creates a synthetic 1-second mono 440 Hz sine-wave WAV file.
/// Produces a clearly audible, non-silent source for muxer tests.
/// Adapted from the VGAOE_CreateSineWave pattern in VGAudioOnlyExporterTest.m.
static NSString * _Nullable VGAEM_CreateSineWaveWAV(double durationSec) {
    NSString *path = VGAEM_TempPath(@"wav");
    NSURL *url = [NSURL fileURLWithPath:path];
    [[NSFileManager defaultManager] removeItemAtURL:url error:nil];

    NSError *err = nil;
    AVAssetWriter *w = [AVAssetWriter assetWriterWithURL:url
                                                 fileType:AVFileTypeWAVE
                                                    error:&err];
    if (!w || err) return nil;

    NSDictionary *settings = @{
        AVFormatIDKey:               @(kAudioFormatLinearPCM),
        AVSampleRateKey:             @(44100.0),
        AVNumberOfChannelsKey:       @(1),
        AVLinearPCMBitDepthKey:      @16,
        AVLinearPCMIsFloatKey:       @NO,
        AVLinearPCMIsBigEndianKey:   @NO,
        AVLinearPCMIsNonInterleaved: @NO,
    };
    AVAssetWriterInput *inp =
        [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeAudio
                                           outputSettings:settings];
    inp.expectsMediaDataInRealTime = NO;
    [w addInput:inp];
    [w startWriting];
    [w startSessionAtSourceTime:kCMTimeZero];

    float sampleRate = 44100.0f;
    int numSamples = (int)(sampleRate * durationSec);
    size_t dataSize = (size_t)numSamples * sizeof(int16_t);
    int16_t *buf = (int16_t *)malloc(dataSize);
    for (int i = 0; i < numSamples; i++) {
        buf[i] = (int16_t)(32767.0 * sin(2.0 * M_PI * 440.0 * i / sampleRate));
    }

    AudioStreamBasicDescription asbd = {
        .mFormatID         = kAudioFormatLinearPCM,
        .mSampleRate       = sampleRate,
        .mChannelsPerFrame = 1,
        .mBitsPerChannel   = 16,
        .mFramesPerPacket  = 1,
        .mBytesPerFrame    = 2,
        .mBytesPerPacket   = 2,
        .mFormatFlags = kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
    };

    CMBlockBufferRef bb = NULL;
    CMBlockBufferCreateWithMemoryBlock(NULL, buf, dataSize, kCFAllocatorNull,
                                       NULL, 0, dataSize, 0, &bb);

    CMFormatDescriptionRef fmt = NULL;
    CMAudioFormatDescriptionCreate(NULL, &asbd, 0, NULL, 0, NULL, NULL, &fmt);
    CMSampleTimingInfo timing = {
        CMTimeMake(1, (int32_t)sampleRate), kCMTimeZero, kCMTimeInvalid
    };
    CMSampleBufferRef sample = NULL;
    CMSampleBufferCreate(NULL, bb, YES, NULL, NULL, fmt,
                         numSamples, 1, &timing, 0, NULL, &sample);
    CFRelease(bb);
    if (fmt) CFRelease(fmt);
    free(buf);

    if (sample) {
        [inp appendSampleBuffer:sample];
        CFRelease(sample);
    }
    [inp markAsFinished];

    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    [w finishWritingWithCompletionHandler:^{ dispatch_semaphore_signal(sem); }];
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 10LL * NSEC_PER_SEC));

    return (w.status == AVAssetWriterStatusCompleted) ? path : nil;
}

/// Builds a VGAudioSidecarPlan from a controlled track dictionary.
/// The caller supplies the complete track dictionary so that individual
/// fields (including volume presence/absence) can be tested independently.
static VGAudioSidecarPlan *VGAEM_SidecarPlanWithTrackDict(NSDictionary<NSString *, id> *td) {
    return [[VGAudioSidecarPlan alloc] initWithTracks:@[td]
                                      volumeKeyframes:nil
                                        waveformCache:nil
                                timeRemapAudioPolicy:nil];
}

/// Runs VGAudioExportMuxer synchronously and returns (success, durationSeconds, error).
/// Times out after 60 seconds to accommodate real AVAssetExportSession runs.
static BOOL VGAEM_RunMuxSync(NSString *videoPath,
                              VGAudioSidecarPlan *sidecar,
                              NSString *outputPath,
                              NSTimeInterval *outDuration,
                              NSError * _Nullable *outError) {
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    __block BOOL resultSuccess = NO;
    __block NSTimeInterval resultDuration = 0.0;
    __block NSError *resultError = nil;

    VGAudioExportMuxer *muxer =
        [[VGAudioExportMuxer alloc] initWithVideoTempPath:videoPath
                                             audioSidecar:sidecar
                                          finalOutputPath:outputPath];
    [muxer startMuxWithCompletion:^(BOOL success, NSTimeInterval duration,
                                    NSError * _Nullable error) {
        resultSuccess  = success;
        resultDuration = duration;
        resultError    = error;
        dispatch_semaphore_signal(done);
    }];

    dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 60LL * NSEC_PER_SEC));
    if (outDuration) *outDuration = resultDuration;
    if (outError)    *outError    = resultError;
    return resultSuccess;
}

/// Decodes the first audio track of an MP4 file and returns the peak absolute
/// int16 sample magnitude. Returns 0 if the file has no decodable audio.
///
/// Uses AVAssetReader + AVAssetReaderTrackOutput with 16-bit signed PCM output
/// settings to perform an objective energy measurement without subjective listening.
static int32_t VGAEM_DecodedAudioPeak(NSString *filePath) {
    NSURL *url = [NSURL fileURLWithPath:filePath];
    AVAsset *asset = [AVAsset assetWithURL:url];
    NSArray<AVAssetTrack *> *audioTracks = [asset tracksWithMediaType:AVMediaTypeAudio];
    if (audioTracks.count == 0) return 0;

    NSDictionary *outputSettings = @{
        AVFormatIDKey:               @(kAudioFormatLinearPCM),
        AVLinearPCMBitDepthKey:      @16,
        AVLinearPCMIsFloatKey:       @NO,
        AVLinearPCMIsBigEndianKey:   @NO,
        AVLinearPCMIsNonInterleaved: @NO,
    };

    NSError *err = nil;
    AVAssetReader *reader = [AVAssetReader assetReaderWithAsset:asset error:&err];
    if (!reader || err) return 0;

    AVAssetReaderTrackOutput *output =
        [AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:audioTracks.firstObject
                                                   outputSettings:outputSettings];
    output.alwaysCopiesSampleData = NO;
    if (![reader canAddOutput:output]) return 0;
    [reader addOutput:output];

    if (![reader startReading]) return 0;

    int32_t peak = 0;
    CMSampleBufferRef sample = NULL;
    while ((sample = [output copyNextSampleBuffer]) != NULL) {
        CMBlockBufferRef block = CMSampleBufferGetDataBuffer(sample);
        if (block) {
            size_t totalLen = CMBlockBufferGetDataLength(block);
            char *bytes = NULL;
            size_t actualLen = 0;
            if (CMBlockBufferGetDataPointer(block, 0, &actualLen, &totalLen, &bytes) == noErr
                && bytes != NULL) {
                NSUInteger sampleCount = totalLen / sizeof(int16_t);
                int16_t *samples = (int16_t *)bytes;
                for (NSUInteger i = 0; i < sampleCount; i++) {
                    int32_t abs = samples[i] < 0 ? -(int32_t)samples[i] : (int32_t)samples[i];
                    if (abs > peak) peak = abs;
                }
            }
        }
        CFRelease(sample);
    }
    [reader cancelReading];
    return peak;
}

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - VGAudioExportMuxerTest
// ─────────────────────────────────────────────────────────────────────────────

@interface VGAudioExportMuxerTest : XCTestCase
@end

@implementation VGAudioExportMuxerTest {
    /// Shared video-only fixture (30 frames at 30fps = 1.0s).
    NSString *_videoPath;
    /// Shared 1-second sine-wave WAV fixture.
    NSString *_audioPath;
}

- (void)setUp {
    [super setUp];
    // 30 frames at 30fps ≈ 1.0s video, audio-free.
    _videoPath = VGAEM_CreateVideoOnlyMP4(30, 30.0);
    // 1-second mono 440 Hz sine wave — clearly non-silent source.
    _audioPath = VGAEM_CreateSineWaveWAV(1.0);
}

- (void)tearDown {
    NSFileManager *fm = [NSFileManager defaultManager];
    if (_videoPath) [fm removeItemAtPath:_videoPath error:nil];
    if (_audioPath) [fm removeItemAtPath:_audioPath error:nil];
    _videoPath = nil;
    _audioPath = nil;
    [super tearDown];
}

// ─────────────────────────────────────────────────────────────────────────────
// TC-10CA-01: unity control versus zero-gain export (Slice A closure)
// ─────────────────────────────────────────────────────────────────────────────
//
// Closure test: proves that explicit volume=0.0 exports near-silent audio while
// volume=1.0 exports clearly audible audio. Both exports use identical inputs.
//
// Peak thresholds (100) are provisional — AAC codec silence may decode with
// small non-zero residuals due to quantization; mathematically exact zero is
// not required. A 440 Hz sine wave at unity gain produces raw peak ~32767;
// after AAC round-trip the peak remains well above 1000.

- (void)testTC_10CA_01_unityControlVersusZeroGainExport {
    if (!_videoPath || !_audioPath) {
        XCTSkip(@"TC-10CA-01: fixture creation failed — skipping");
    }

    // ── Control export: volume = 1.0 ─────────────────────────────────────────

    // The muxer deletes videoTempPath on success, so each export needs its own
    // video copy. Copy the shared fixture so tearDown can still clean it up.
    NSString *videoControl = VGAEM_TempPath(@"mp4");
    NSString *videoMuted   = VGAEM_TempPath(@"mp4");
    [[NSFileManager defaultManager] copyItemAtPath:_videoPath
                                            toPath:videoControl
                                             error:nil];
    [[NSFileManager defaultManager] copyItemAtPath:_videoPath
                                            toPath:videoMuted
                                             error:nil];

    NSString *outputControl = VGAEM_TempPath(@"mp4");
    NSString *outputMuted   = VGAEM_TempPath(@"mp4");

    NSDictionary *controlTrack = @{
        @"trackId":   @"VGAEM-tc01-control",
        @"url":       _audioPath,
        @"startTime": @(0.0),
        @"duration":  @(1.0),
        @"volume":    @(1.0),
        @"role":      @"music",
    };
    NSDictionary *mutedTrack = @{
        @"trackId":   @"VGAEM-tc01-muted",
        @"url":       _audioPath,
        @"startTime": @(0.0),
        @"duration":  @(1.0),
        @"volume":    @(0.0),   // explicit static zero — must produce silence
        @"role":      @"music",
    };

    NSTimeInterval controlDuration = 0.0;
    NSError *controlErr = nil;
    BOOL controlOK = VGAEM_RunMuxSync(videoControl,
                                      VGAEM_SidecarPlanWithTrackDict(controlTrack),
                                      outputControl,
                                      &controlDuration,
                                      &controlErr);

    NSTimeInterval mutedDuration = 0.0;
    NSError *mutedErr = nil;
    BOOL mutedOK = VGAEM_RunMuxSync(videoMuted,
                                    VGAEM_SidecarPlanWithTrackDict(mutedTrack),
                                    outputMuted,
                                    &mutedDuration,
                                    &mutedErr);

    // ── Assertions ────────────────────────────────────────────────────────────

    XCTAssertTrue(controlOK,
        @"TC-10CA-01: control mux (volume=1.0) must succeed; error: %@", controlErr);
    XCTAssertTrue(mutedOK,
        @"TC-10CA-01: muted mux (volume=0.0) must succeed; error: %@", mutedErr);

    NSFileManager *fm = [NSFileManager defaultManager];
    XCTAssertTrue([fm fileExistsAtPath:outputControl],
        @"TC-10CA-01: control output file must exist");
    XCTAssertTrue([fm fileExistsAtPath:outputMuted],
        @"TC-10CA-01: muted output file must exist");

    AVAsset *controlAsset = [AVAsset assetWithURL:[NSURL fileURLWithPath:outputControl]];
    AVAsset *mutedAsset   = [AVAsset assetWithURL:[NSURL fileURLWithPath:outputMuted]];

    XCTAssertGreaterThan([controlAsset tracksWithMediaType:AVMediaTypeVideo].count, 0UL,
        @"TC-10CA-01: control output must contain a video track");
    XCTAssertGreaterThan([mutedAsset tracksWithMediaType:AVMediaTypeVideo].count, 0UL,
        @"TC-10CA-01: muted output must contain a video track");

    XCTAssertGreaterThan([controlAsset tracksWithMediaType:AVMediaTypeAudio].count, 0UL,
        @"TC-10CA-01: control output must contain an audio track");
    XCTAssertGreaterThan([mutedAsset tracksWithMediaType:AVMediaTypeAudio].count, 0UL,
        @"TC-10CA-01: muted output must contain an audio track");

    XCTAssertGreaterThan(controlDuration, 0.0,
        @"TC-10CA-01: control duration must be > 0");
    XCTAssertGreaterThan(mutedDuration, 0.0,
        @"TC-10CA-01: muted duration must be > 0");

    XCTAssertEqualWithAccuracy(controlDuration, mutedDuration, 0.1,
        @"TC-10CA-01: durations must match within 0.1s "
        @"(control=%.3fs muted=%.3fs)", controlDuration, mutedDuration);

    // Decode PCM from each output and measure peak absolute sample magnitude.
    // Thresholds are provisional — see file-level comment about AAC residuals.
    int32_t controlPeak = VGAEM_DecodedAudioPeak(outputControl);
    int32_t mutedPeak   = VGAEM_DecodedAudioPeak(outputMuted);

    XCTAssertGreaterThan(controlPeak, 100,
        @"TC-10CA-01: control (volume=1.0) decoded peak must be > 100 (got %d); "
        @"this proves the source is audible — threshold is provisional", controlPeak);
    XCTAssertLessThan(mutedPeak, 100,
        @"TC-10CA-01: muted (volume=0.0) decoded peak must be < 100 (got %d); "
        @"this proves silence — threshold is provisional (AAC residuals expected)",
        mutedPeak);
    XCTAssertGreaterThan(controlPeak, mutedPeak * 10,
        @"TC-10CA-01: control peak (%d) must be > 10× muted peak (%d)",
        controlPeak, mutedPeak);

    // Cleanup outputs (video copies already deleted by muxer on success).
    [fm removeItemAtPath:outputControl error:nil];
    [fm removeItemAtPath:outputMuted   error:nil];
}

// ─────────────────────────────────────────────────────────────────────────────
// TC-10CA-02: negative volume preserves existing unity fallback
// ─────────────────────────────────────────────────────────────────────────────
//
// PM-required compatibility proof: a static volume of -1.0 must produce audible
// output (the prior `if (volume <= 0.0) volume = 1.0;` behaviour is now narrowed
// to `if (volume < 0.0) volume = 1.0;`, preserving negative→unity semantics).

- (void)testTC_10CA_02_negativeVolumePreservesUnityFallback {
    if (!_videoPath || !_audioPath) {
        XCTSkip(@"TC-10CA-02: fixture creation failed — skipping");
    }

    NSString *videoCopy = VGAEM_TempPath(@"mp4");
    [[NSFileManager defaultManager] copyItemAtPath:_videoPath
                                            toPath:videoCopy
                                             error:nil];
    NSString *output = VGAEM_TempPath(@"mp4");

    NSDictionary *negativeTrack = @{
        @"trackId":   @"VGAEM-tc02-negative",
        @"url":       _audioPath,
        @"startTime": @(0.0),
        @"duration":  @(1.0),
        @"volume":    @(-1.0),   // negative — must fall back to unity (audible)
        @"role":      @"music",
    };

    NSTimeInterval duration = 0.0;
    NSError *err = nil;
    BOOL ok = VGAEM_RunMuxSync(videoCopy,
                                VGAEM_SidecarPlanWithTrackDict(negativeTrack),
                                output,
                                &duration,
                                &err);

    XCTAssertTrue(ok,
        @"TC-10CA-02: export with negative volume must succeed; error: %@", err);
    XCTAssertGreaterThan([[[AVAsset assetWithURL:[NSURL fileURLWithPath:output]]
                           tracksWithMediaType:AVMediaTypeAudio] count], 0UL,
        @"TC-10CA-02: output must contain an audio track");

    int32_t peak = VGAEM_DecodedAudioPeak(output);
    XCTAssertGreaterThan(peak, 100,
        @"TC-10CA-02: negative volume (-1.0) must produce audible output (peak=%d); "
        @"this proves the unity fallback is preserved — threshold is provisional", peak);

    [[NSFileManager defaultManager] removeItemAtPath:output error:nil];
}

// ─────────────────────────────────────────────────────────────────────────────
// TC-10CA-03: omitted volume key defaults to unity
// ─────────────────────────────────────────────────────────────────────────────
//
// Proves that an absent `volume` key does not produce silence via [nil doubleValue]
// → 0.0 after the fix. The nil-checked parse must default to 1.0.

- (void)testTC_10CA_03_omittedVolumeDefaultsToUnity {
    if (!_videoPath || !_audioPath) {
        XCTSkip(@"TC-10CA-03: fixture creation failed — skipping");
    }

    NSString *videoCopy = VGAEM_TempPath(@"mp4");
    [[NSFileManager defaultManager] copyItemAtPath:_videoPath
                                            toPath:videoCopy
                                             error:nil];
    NSString *output = VGAEM_TempPath(@"mp4");

    // Construct a track dictionary WITHOUT the "volume" key to prove the
    // omitted-key default behaviour directly.
    NSDictionary *omittedVolumeTrack = @{
        @"trackId":   @"VGAEM-tc03-omitted",
        @"url":       _audioPath,
        @"startTime": @(0.0),
        @"duration":  @(1.0),
        @"role":      @"music",
        // "volume" key intentionally absent
    };

    NSTimeInterval duration = 0.0;
    NSError *err = nil;
    BOOL ok = VGAEM_RunMuxSync(videoCopy,
                                VGAEM_SidecarPlanWithTrackDict(omittedVolumeTrack),
                                output,
                                &duration,
                                &err);

    XCTAssertTrue(ok,
        @"TC-10CA-03: export with omitted volume must succeed; error: %@", err);
    XCTAssertGreaterThan([[[AVAsset assetWithURL:[NSURL fileURLWithPath:output]]
                           tracksWithMediaType:AVMediaTypeAudio] count], 0UL,
        @"TC-10CA-03: output must contain an audio track");

    int32_t peak = VGAEM_DecodedAudioPeak(output);
    XCTAssertGreaterThan(peak, 100,
        @"TC-10CA-03: omitted volume must produce audible output (peak=%d); "
        @"this proves the default 1.0 parse is correct — threshold is provisional", peak);

    [[NSFileManager defaultManager] removeItemAtPath:output error:nil];
}

@end
