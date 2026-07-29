// VGAudioOnlyExporterTest.m — Phase 5E-2

#import <XCTest/XCTest.h>
#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import "VGAudioOnlyExporter.h"
#import <UMF/VGAudioExportProfile.h>
#import <UMF/VGAudioExportManifest.h>

static NSString *const kDomain = @"VGAudioOnlyExporter";

static NSURL *VGAOE_TempURL(NSString *ext) {
    return [NSURL fileURLWithPath:[NSTemporaryDirectory()
        stringByAppendingPathComponent:
            [NSString stringWithFormat:@"VGAOE_%@.%@", [NSUUID UUID].UUIDString, ext]]];
}

// Creates a 1-second mono 440Hz sine-wave WAV file via AVAssetWriter.
static NSURL *VGAOE_CreateSineWave(double durationSec, float sampleRate, int channels) {
    NSURL *url = VGAOE_TempURL(@"wav");
    [[NSFileManager defaultManager] removeItemAtURL:url error:nil];

    NSError *err = nil;
    AVAssetWriter *w = [AVAssetWriter assetWriterWithURL:url
                                                fileType:AVFileTypeWAVE error:&err];
    if (!w) return nil;

    NSDictionary *settings = @{
        AVFormatIDKey:               @(kAudioFormatLinearPCM),
        AVSampleRateKey:             @(sampleRate),
        AVNumberOfChannelsKey:       @(channels),
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

    int numSamples = (int)(sampleRate * durationSec);
    size_t dataSize = numSamples * channels * sizeof(int16_t);
    int16_t *buf = (int16_t *)malloc(dataSize);
    for (int i = 0; i < numSamples; i++) {
        int16_t s = (int16_t)(32767.0 * sin(2.0 * M_PI * 440.0 * i / sampleRate));
        for (int c = 0; c < channels; c++) buf[i * channels + c] = s;
    }

    AudioStreamBasicDescription asbd = {
        .mFormatID         = kAudioFormatLinearPCM,
        .mSampleRate       = sampleRate,
        .mChannelsPerFrame = (UInt32)channels,
        .mBitsPerChannel   = 16,
        .mFramesPerPacket  = 1,
        .mBytesPerFrame    = (UInt32)(channels * 2),
        .mBytesPerPacket   = (UInt32)(channels * 2),
        .mFormatFlags      = kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
    };

    CMBlockBufferRef bb = NULL;
    CMBlockBufferCreateWithMemoryBlock(NULL, buf, dataSize, kCFAllocatorMalloc,
                                       NULL, 0, dataSize, 0, &bb);

    // Simpler: use CMSampleBufferCreate

    CMFormatDescriptionRef fmt = NULL;
    CMAudioFormatDescriptionCreate(NULL, &asbd, 0, NULL, 0, NULL, NULL, &fmt);
    CMSampleTimingInfo timing = { CMTimeMake(1, (int32_t)sampleRate), kCMTimeZero, kCMTimeInvalid };
    CMSampleBufferRef sample = NULL;
    CMSampleBufferCreate(NULL, bb, YES, NULL, NULL, fmt, numSamples,
                          1, &timing, 0, NULL, &sample);
    CFRelease(bb);
    if (fmt) CFRelease(fmt);

    if (sample) {
        [inp appendSampleBuffer:sample];
        CFRelease(sample);
    }
    [inp markAsFinished];

    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    [w finishWritingWithCompletionHandler:^{ dispatch_semaphore_signal(sem); }];
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC));
    return (w.status == AVAssetWriterStatusCompleted) ? url : nil;
}

// Creates a 1-second video+audio fixture for audio-extraction test.
static NSURL *VGAOE_CreateVideoWithAudio(void) {
    NSURL *url = VGAOE_TempURL(@"mp4");
    [[NSFileManager defaultManager] removeItemAtURL:url error:nil];

    NSError *err = nil;
    AVAssetWriter *w = [AVAssetWriter assetWriterWithURL:url
                                                fileType:AVFileTypeMPEG4 error:&err];
    if (!w) return nil;

    // Video track (minimal 128x128 H.264)
    NSDictionary *vs = @{
        AVVideoCodecKey: AVVideoCodecTypeH264,
        AVVideoWidthKey: @128, AVVideoHeightKey: @128,
    };
    AVAssetWriterInput *vi =
        [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeVideo outputSettings:vs];
    vi.expectsMediaDataInRealTime = NO;
    if ([w canAddInput:vi]) [w addInput:vi];

    // Audio track
    NSDictionary *as = @{
        AVFormatIDKey: @(kAudioFormatMPEG4AAC),
        AVSampleRateKey: @44100, AVNumberOfChannelsKey: @1,
        AVEncoderBitRateKey: @64000,
    };
    AVAssetWriterInput *ai =
        [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeAudio outputSettings:as];
    ai.expectsMediaDataInRealTime = NO;
    if ([w canAddInput:ai]) [w addInput:ai];

    // Write one black video frame
    CVPixelBufferRef pb = NULL;
    CVPixelBufferCreate(NULL, 128, 128, kCVPixelFormatType_32BGRA, NULL, &pb);
    AVAssetWriterInputPixelBufferAdaptor *adaptor = nil;
    if (pb) {
        adaptor = [AVAssetWriterInputPixelBufferAdaptor
             assetWriterInputPixelBufferAdaptorWithAssetWriterInput:vi
             sourcePixelBufferAttributes:nil];
    }

    [w startWriting];
    [w startSessionAtSourceTime:kCMTimeZero];

    if (pb && adaptor) {
        [adaptor appendPixelBuffer:pb withPresentationTime:kCMTimeZero];
        CVPixelBufferRelease(pb);
    }
    [vi markAsFinished];

    // Write sine wave audio
    float sr = 44100.0f; int nc = 1;
    int ns = (int)sr;
    size_t ds = ns * nc * sizeof(int16_t);
    int16_t *abuf = (int16_t *)malloc(ds);
    for (int i = 0; i < ns; i++)
        abuf[i] = (int16_t)(32767.0 * sin(2.0 * M_PI * 440.0 * i / sr));

    AudioStreamBasicDescription asbd = {
        .mFormatID = kAudioFormatLinearPCM, .mSampleRate = sr,
        .mChannelsPerFrame = 1, .mBitsPerChannel = 16,
        .mFramesPerPacket = 1, .mBytesPerFrame = 2, .mBytesPerPacket = 2,
        .mFormatFlags = kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
    };
    CMFormatDescriptionRef afmt = NULL;
    CMAudioFormatDescriptionCreate(NULL, &asbd, 0, NULL, 0, NULL, NULL, &afmt);
    CMBlockBufferRef abb = NULL;
    CMBlockBufferCreateWithMemoryBlock(NULL, abuf, ds, kCFAllocatorMalloc, NULL, 0, ds, 0, &abb);
    CMSampleTimingInfo atiming = { CMTimeMake(1, (int32_t)sr), kCMTimeZero, kCMTimeInvalid };
    CMSampleBufferRef asample = NULL;
    CMSampleBufferCreate(NULL, abb, YES, NULL, NULL, afmt, ns, 1, &atiming, 0, NULL, &asample);
    CFRelease(abb);
    if (afmt) CFRelease(afmt);
    if (asample) { [ai appendSampleBuffer:asample]; CFRelease(asample); }
    [ai markAsFinished];

    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    [w finishWritingWithCompletionHandler:^{ dispatch_semaphore_signal(sem); }];
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 15 * NSEC_PER_SEC));
    return (w.status == AVAssetWriterStatusCompleted) ? url : nil;
}

@interface VGAudioOnlyExporterTest : XCTestCase
@end

@implementation VGAudioOnlyExporterTest

- (void)testTC_5E2_01_m4aExportSucceeds {
    NSURL *src = VGAOE_CreateSineWave(1.0, 44100, 2);
    XCTAssertNotNil(src, @"fixture creation failed");
    AVAsset *asset = [AVAsset assetWithURL:src];
    NSURL *out = VGAOE_TempURL(@"m4a");
    VGAudioOnlyExporter *sut = [[VGAudioOnlyExporter alloc]
        initWithAsset:asset profile:[VGAudioExportProfile m4aDefaultProfile] outputURL:out];
    XCTestExpectation *exp = [self expectationWithDescription:@"m4a"];
    [sut startWithCompletion:^(VGAudioExportManifest *m, NSError *e) {
        XCTAssertNil(e, @"%@", e); XCTAssertNotNil(m); [exp fulfill];
    }];
    [self waitForExpectationsWithTimeout:30 handler:nil];
    XCTAssertTrue([[NSFileManager defaultManager] fileExistsAtPath:out.path]);
    [[NSFileManager defaultManager] removeItemAtURL:src error:nil];
    [[NSFileManager defaultManager] removeItemAtURL:out error:nil];
}

- (void)testTC_5E2_02_wavExportSucceeds {
    NSURL *src = VGAOE_CreateSineWave(1.0, 44100, 2);
    XCTAssertNotNil(src); AVAsset *asset = [AVAsset assetWithURL:src];
    NSURL *out = VGAOE_TempURL(@"wav");
    VGAudioOnlyExporter *sut = [[VGAudioOnlyExporter alloc]
        initWithAsset:asset profile:[VGAudioExportProfile wavProfile] outputURL:out];
    XCTestExpectation *exp = [self expectationWithDescription:@"wav"];
    [sut startWithCompletion:^(VGAudioExportManifest *m, NSError *e) {
        XCTAssertNil(e, @"%@", e); XCTAssertNotNil(m); [exp fulfill];
    }];
    [self waitForExpectationsWithTimeout:30 handler:nil];
    [[NSFileManager defaultManager] removeItemAtURL:src error:nil];
    [[NSFileManager defaultManager] removeItemAtURL:out error:nil];
}

- (void)testTC_5E2_03_manifestFieldsMatchOutput {
    NSURL *src = VGAOE_CreateSineWave(1.0, 44100, 2);
    XCTAssertNotNil(src); AVAsset *asset = [AVAsset assetWithURL:src];
    NSURL *out = VGAOE_TempURL(@"m4a");
    VGAudioOnlyExporter *sut = [[VGAudioOnlyExporter alloc]
        initWithAsset:asset profile:[VGAudioExportProfile m4aDefaultProfile] outputURL:out];
    XCTestExpectation *exp = [self expectationWithDescription:@"manifest"];
    [sut startWithCompletion:^(VGAudioExportManifest *m, NSError *e) {
        XCTAssertNil(e); XCTAssertNotNil(m);
        XCTAssertEqual(m.codec, VGAudioCodecAAC);
        XCTAssertGreaterThan(m.sampleRate, 0);
        XCTAssertGreaterThan(m.channels, 0U);
        XCTAssertGreaterThan(m.durationSeconds, 0.0);
        XCTAssertGreaterThan(m.fileSizeBytes, 0LL);
        XCTAssertEqualObjects(m.containerFormat, @"m4a");
        NSDictionary *attrs = [[NSFileManager defaultManager]
            attributesOfItemAtPath:out.path error:nil];
        XCTAssertEqual(m.fileSizeBytes, (int64_t)[attrs[NSFileSize] longLongValue]);
        [exp fulfill];
    }];
    [self waitForExpectationsWithTimeout:30 handler:nil];
    [[NSFileManager defaultManager] removeItemAtURL:src error:nil];
    [[NSFileManager defaultManager] removeItemAtURL:out error:nil];
}

- (void)testTC_5E2_04_wavManifestFields {
    NSURL *src = VGAOE_CreateSineWave(1.0, 44100, 1);
    XCTAssertNotNil(src); AVAsset *asset = [AVAsset assetWithURL:src];
    NSURL *out = VGAOE_TempURL(@"wav");
    VGAudioOnlyExporter *sut = [[VGAudioOnlyExporter alloc]
        initWithAsset:asset profile:[VGAudioExportProfile wavProfile] outputURL:out];
    XCTestExpectation *exp = [self expectationWithDescription:@"wavManifest"];
    [sut startWithCompletion:^(VGAudioExportManifest *m, NSError *e) {
        XCTAssertNil(e); XCTAssertNotNil(m);
        XCTAssertEqual(m.codec, VGAudioCodecPCM);
        XCTAssertEqual(m.bitrate, 0U);
        XCTAssertEqualObjects(m.containerFormat, @"wav");
        NSDictionary *attrs = [[NSFileManager defaultManager]
            attributesOfItemAtPath:out.path error:nil];
        XCTAssertEqual(m.fileSizeBytes, (int64_t)[attrs[NSFileSize] longLongValue]);
        [exp fulfill];
    }];
    [self waitForExpectationsWithTimeout:30 handler:nil];
    [[NSFileManager defaultManager] removeItemAtURL:src error:nil];
    [[NSFileManager defaultManager] removeItemAtURL:out error:nil];
}

- (void)testTC_5E2_05_noAudioTrackReturnsError {
    // Use a nonexistent URL so asset has no tracks.
    AVAsset *asset = [AVAsset assetWithURL:[NSURL fileURLWithPath:@"/nonexistent/audio.wav"]];
    NSURL *out = VGAOE_TempURL(@"m4a");
    VGAudioOnlyExporter *sut = [[VGAudioOnlyExporter alloc]
        initWithAsset:asset profile:[VGAudioExportProfile m4aDefaultProfile] outputURL:out];
    XCTestExpectation *exp = [self expectationWithDescription:@"noAudio"];
    [sut startWithCompletion:^(VGAudioExportManifest *m, NSError *e) {
        XCTAssertNil(m); XCTAssertNotNil(e);
        XCTAssertEqualObjects(e.domain, kDomain);
        [exp fulfill];
    }];
    [self waitForExpectationsWithTimeout:15 handler:nil];
}

- (void)testTC_5E2_06_invalidSourceReturnsError {
    AVAsset *asset = [AVAsset assetWithURL:[NSURL fileURLWithPath:@"/nonexistent/x.wav"]];
    NSURL *out = VGAOE_TempURL(@"m4a");
    VGAudioOnlyExporter *sut = [[VGAudioOnlyExporter alloc]
        initWithAsset:asset profile:[VGAudioExportProfile m4aDefaultProfile] outputURL:out];
    XCTestExpectation *exp = [self expectationWithDescription:@"badSrc"];
    [sut startWithCompletion:^(VGAudioExportManifest *m, NSError *e) {
        XCTAssertNil(m); XCTAssertNotNil(e); [exp fulfill];
    }];
    [self waitForExpectationsWithTimeout:15 handler:nil];
}

- (void)testTC_5E2_07_unsupportedOpusReturnsError {
    NSURL *src = VGAOE_CreateSineWave(1.0, 44100, 1);
    AVAsset *asset = src ? [AVAsset assetWithURL:src] : [AVAsset assetWithURL:[NSURL fileURLWithPath:@"/x"]];
    VGAudioExportProfile *p = [[VGAudioExportProfile alloc]
        initWithCodec:VGAudioCodecOpus bitrate:0 sampleRate:44100 channels:1 containerFormat:@"m4a"];
    VGAudioOnlyExporter *sut = [[VGAudioOnlyExporter alloc]
        initWithAsset:asset profile:p outputURL:VGAOE_TempURL(@"m4a")];
    XCTestExpectation *exp = [self expectationWithDescription:@"opus"];
    [sut startWithCompletion:^(VGAudioExportManifest *m, NSError *e) {
        XCTAssertNil(m); XCTAssertNotNil(e);
        XCTAssertEqual(e.code, VGAudioOnlyExporterErrorUnsupportedCodec);
        [exp fulfill];
    }];
    [self waitForExpectationsWithTimeout:10 handler:nil];
    if (src) [[NSFileManager defaultManager] removeItemAtURL:src error:nil];
}

- (void)testTC_5E2_08_unsupportedFormatMismatchReturnsError {
    // AAC codec + wav container
    VGAudioExportProfile *p = [[VGAudioExportProfile alloc]
        initWithCodec:VGAudioCodecAAC bitrate:128000 sampleRate:44100 channels:2 containerFormat:@"wav"];
    AVAsset *asset = [AVAsset assetWithURL:[NSURL fileURLWithPath:@"/x"]];
    VGAudioOnlyExporter *sut = [[VGAudioOnlyExporter alloc]
        initWithAsset:asset profile:p outputURL:VGAOE_TempURL(@"wav")];
    XCTestExpectation *exp = [self expectationWithDescription:@"mismatch"];
    [sut startWithCompletion:^(VGAudioExportManifest *m, NSError *e) {
        XCTAssertNil(m); XCTAssertNotNil(e);
        XCTAssertEqual(e.code, VGAudioOnlyExporterErrorUnsupportedFormat);
        [exp fulfill];
    }];
    [self waitForExpectationsWithTimeout:10 handler:nil];
}

- (void)testTC_5E2_09_cancelBeforeStartReturnsCancellation {
    NSURL *src = VGAOE_CreateSineWave(1.0, 44100, 2);
    AVAsset *asset = src ? [AVAsset assetWithURL:src] : [AVAsset assetWithURL:[NSURL fileURLWithPath:@"/x"]];
    VGAudioOnlyExporter *sut = [[VGAudioOnlyExporter alloc]
        initWithAsset:asset profile:[VGAudioExportProfile m4aDefaultProfile] outputURL:VGAOE_TempURL(@"m4a")];
    [sut cancel];
    XCTestExpectation *exp = [self expectationWithDescription:@"cancelBefore"];
    [sut startWithCompletion:^(VGAudioExportManifest *m, NSError *e) {
        XCTAssertNil(m); XCTAssertNotNil(e);
        XCTAssertEqual(e.code, VGAudioOnlyExporterErrorCancelled);
        [exp fulfill];
    }];
    [self waitForExpectationsWithTimeout:10 handler:nil];
    if (src) [[NSFileManager defaultManager] removeItemAtURL:src error:nil];
}

- (void)testTC_5E2_10_cancelDuringExportReturnsCancellation {
    // Use long fixture to ensure cancel wins.
    NSURL *src = VGAOE_CreateSineWave(30.0, 44100, 2);
    XCTAssertNotNil(src);
    AVAsset *asset = [AVAsset assetWithURL:src];
    NSURL *out = VGAOE_TempURL(@"m4a");
    VGAudioOnlyExporter *sut = [[VGAudioOnlyExporter alloc]
        initWithAsset:asset profile:[VGAudioExportProfile m4aDefaultProfile] outputURL:out];
    XCTestExpectation *exp = [self expectationWithDescription:@"cancelDuring"];
    [sut startWithCompletion:^(VGAudioExportManifest *m, NSError *e) {
        XCTAssertNil(m); XCTAssertNotNil(e);
        XCTAssertEqual(e.code, VGAudioOnlyExporterErrorCancelled);
        [exp fulfill];
    }];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 50 * NSEC_PER_MSEC),
                   dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{ [sut cancel]; });
    [self waitForExpectationsWithTimeout:30 handler:nil];
    [[NSFileManager defaultManager] removeItemAtURL:src error:nil];
    [[NSFileManager defaultManager] removeItemAtURL:out error:nil];
}

- (void)testTC_5E2_11_completionFiresExactlyOnce {
    NSURL *src = VGAOE_CreateSineWave(1.0, 44100, 2);
    XCTAssertNotNil(src); AVAsset *asset = [AVAsset assetWithURL:src];
    NSURL *out = VGAOE_TempURL(@"m4a");
    VGAudioOnlyExporter *sut = [[VGAudioOnlyExporter alloc]
        initWithAsset:asset profile:[VGAudioExportProfile m4aDefaultProfile] outputURL:out];
    __block int count = 0;
    XCTestExpectation *exp = [self expectationWithDescription:@"once"];
    [sut startWithCompletion:^(VGAudioExportManifest *m, NSError *e) {
        count++; [exp fulfill];
    }];
    [sut startWithCompletion:^(VGAudioExportManifest *m, NSError *e) { count++; }];
    [self waitForExpectationsWithTimeout:30 handler:nil];
    [NSThread sleepForTimeInterval:0.2];
    XCTAssertEqual(count, 1);
    [[NSFileManager defaultManager] removeItemAtURL:src error:nil];
    [[NSFileManager defaultManager] removeItemAtURL:out error:nil];
}

- (void)testTC_5E2_12_secondStartIsNoOp {
    NSURL *src = VGAOE_CreateSineWave(1.0, 44100, 2);
    XCTAssertNotNil(src); AVAsset *asset = [AVAsset assetWithURL:src];
    NSURL *out = VGAOE_TempURL(@"m4a");
    VGAudioOnlyExporter *sut = [[VGAudioOnlyExporter alloc]
        initWithAsset:asset profile:[VGAudioExportProfile m4aDefaultProfile] outputURL:out];
    XCTestExpectation *first = [self expectationWithDescription:@"first"];
    [sut startWithCompletion:^(VGAudioExportManifest *m, NSError *e) { [first fulfill]; }];
    [self waitForExpectationsWithTimeout:30 handler:nil];
    XCTAssertTrue(sut.isFinished);
    __block int second = 0;
    [sut startWithCompletion:^(VGAudioExportManifest *m, NSError *e) { second++; }];
    [NSThread sleepForTimeInterval:0.3];
    XCTAssertEqual(second, 0);
    [[NSFileManager defaultManager] removeItemAtURL:src error:nil];
    [[NSFileManager defaultManager] removeItemAtURL:out error:nil];
}

- (void)testTC_5E2_13_videoWithAudioExtractsAudioOnly {
    NSURL *src = VGAOE_CreateVideoWithAudio();
    XCTAssertNotNil(src, @"video+audio fixture creation failed");
    AVAsset *asset = [AVAsset assetWithURL:src];
    NSURL *out = VGAOE_TempURL(@"m4a");
    VGAudioOnlyExporter *sut = [[VGAudioOnlyExporter alloc]
        initWithAsset:asset profile:[VGAudioExportProfile m4aDefaultProfile] outputURL:out];
    XCTestExpectation *exp = [self expectationWithDescription:@"videoWithAudio"];
    [sut startWithCompletion:^(VGAudioExportManifest *m, NSError *e) {
        XCTAssertNil(e, @"%@", e); XCTAssertNotNil(m);
        AVAsset *outAsset = [AVAsset assetWithURL:out];
        XCTAssertEqual([outAsset tracksWithMediaType:AVMediaTypeVideo].count, 0UL);
        XCTAssertGreaterThan([outAsset tracksWithMediaType:AVMediaTypeAudio].count, 0UL);
        [exp fulfill];
    }];
    [self waitForExpectationsWithTimeout:30 handler:nil];
    [[NSFileManager defaultManager] removeItemAtURL:src error:nil];
    [[NSFileManager defaultManager] removeItemAtURL:out error:nil];
}

- (void)testTC_5E2_14_boundedTrimProducesRequestedDuration {
    NSURL *src = VGAOE_CreateSineWave(5.0, 44100, 2);
    XCTAssertNotNil(src);
    AVAsset *asset = [AVAsset assetWithURL:src];
    NSURL *out = VGAOE_TempURL(@"m4a");
    CMTimeRange trim = CMTimeRangeMake(CMTimeMakeWithSeconds(1.0, 1000), CMTimeMakeWithSeconds(2.0, 1000));
    VGAudioOnlyExporter *sut = [[VGAudioOnlyExporter alloc]
        initWithAsset:asset profile:[VGAudioExportProfile m4aDefaultProfile] outputURL:out trimRange:trim];
    XCTestExpectation *exp = [self expectationWithDescription:@"boundedTrim"];
    [sut startWithCompletion:^(VGAudioExportManifest *m, NSError *e) {
        XCTAssertNil(e);
        XCTAssertNotNil(m);
        AVAsset *outAsset = [AVAsset assetWithURL:out];
        double seconds = CMTimeGetSeconds(outAsset.duration);
        XCTAssertEqualWithAccuracy(seconds, 2.0, 0.5);
        [exp fulfill];
    }];
    [self waitForExpectationsWithTimeout:30 handler:nil];
    [[NSFileManager defaultManager] removeItemAtURL:src error:nil];
    [[NSFileManager defaultManager] removeItemAtURL:out error:nil];
}

- (void)testTC_5E2_15_startOnlyTrimRunsToEOF {
    NSURL *src = VGAOE_CreateSineWave(5.0, 44100, 2);
    XCTAssertNotNil(src);
    AVAsset *asset = [AVAsset assetWithURL:src];
    NSURL *out = VGAOE_TempURL(@"m4a");
    CMTimeRange trim = CMTimeRangeMake(CMTimeMakeWithSeconds(2.0, 1000), kCMTimePositiveInfinity);
    VGAudioOnlyExporter *sut = [[VGAudioOnlyExporter alloc]
        initWithAsset:asset profile:[VGAudioExportProfile m4aDefaultProfile] outputURL:out trimRange:trim];
    XCTestExpectation *exp = [self expectationWithDescription:@"startOnlyTrim"];
    [sut startWithCompletion:^(VGAudioExportManifest *m, NSError *e) {
        XCTAssertNil(e);
        XCTAssertNotNil(m);
        AVAsset *outAsset = [AVAsset assetWithURL:out];
        double seconds = CMTimeGetSeconds(outAsset.duration);
        XCTAssertEqualWithAccuracy(seconds, 3.0, 0.5);
        [exp fulfill];
    }];
    [self waitForExpectationsWithTimeout:30 handler:nil];
    [[NSFileManager defaultManager] removeItemAtURL:src error:nil];
    [[NSFileManager defaultManager] removeItemAtURL:out error:nil];
}

- (void)testTC_5E2_16_invalidTrimDurationReturnsReaderSetupError {
    NSURL *src = VGAOE_CreateSineWave(2.0, 44100, 2);
    XCTAssertNotNil(src);
    AVAsset *asset = [AVAsset assetWithURL:src];
    NSURL *out = VGAOE_TempURL(@"m4a");
    CMTimeRange trim = CMTimeRangeMake(CMTimeMakeWithSeconds(1.0, 1000), CMTimeMakeWithSeconds(0.0, 1000));
    VGAudioOnlyExporter *sut = [[VGAudioOnlyExporter alloc]
        initWithAsset:asset profile:[VGAudioExportProfile m4aDefaultProfile] outputURL:out trimRange:trim];
    XCTestExpectation *exp = [self expectationWithDescription:@"invalidTrim"];
    [sut startWithCompletion:^(VGAudioExportManifest *m, NSError *e) {
        XCTAssertNil(m);
        XCTAssertNotNil(e);
        XCTAssertEqual(e.code, VGAudioOnlyExporterErrorReaderSetup);
        [exp fulfill];
    }];
    [self waitForExpectationsWithTimeout:10 handler:nil];
    [[NSFileManager defaultManager] removeItemAtURL:src error:nil];
    [[NSFileManager defaultManager] removeItemAtURL:out error:nil];
}

@end
