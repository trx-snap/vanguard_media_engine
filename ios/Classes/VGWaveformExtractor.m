// VGWaveformExtractor.m
// vanguard_media_engine — Phase 8.15C
//
// Offline audio waveform extraction: AVAssetReader → RMS Float32 samples.
//
// Pipeline:
//   AVAsset (source)
//   → AVAssetReader
//     → AVAssetReaderTrackOutput (Int16, interleaved, mono, LPCM)
//       → CMSampleBuffer iteration (CMBlockBufferGetDataPointer — no ABL)
//         → RMS window accumulator
//           → NSMutableData of Float32 samples
//
// Apple API contracts:
//   - AVAssetReaderTrackOutput with kAudioFormatLinearPCM uses only
//     AudioToolbox software codec — no coreaudiod XPC, no main-thread callback.
//   - alwaysCopiesSampleData = NO avoids buffer copy overhead.
//   - CMBlockBufferGetDataPointer returns a direct pointer valid for buffer lifetime.
//   - CFRelease(sampleBuffer) immediately after processing each buffer.
//   - @autoreleasepool inside the iteration loop drains transient ObjC objects.
//   - AVAssetReader sequential pull: copyNextSampleBuffer returns nil at EOF or error.
//   - cancelReading stops reader from producing more samples.
//
// Memory safety:
//   - Peak live memory ≈ 2-3 sample buffers (~8-24KB each) + output float array.
//   - 10 min clip at 48kHz mono Int16 = ~57MB raw PCM, but only one buffer
//     is live at a time — no accumulation of unprocessed PCM.
//   - Maximum output: 100 samples/s × 600s = 60,000 floats = 240KB.
//
// Forbidden imports:
//   VGAudioExportMuxer, VGExportScheduler, VGGraphDescriptor,
//   VGGraphValidator, VGGraphPlanner, VGGraphExecutionContext,
//   VGVideoEncoderSinkNode, VGImageEncoderSinkNode, VGExportGraphFactory,
//   VGFrameSink, VGFrameEnvelope, VGGraphSchedulerV2.

#import "VGWaveformExtractor.h"
#import <CoreMedia/CoreMedia.h>
#import <AudioToolbox/AudioToolbox.h>
#import <stdatomic.h>
#import <math.h>
#import <os/log.h>

// ─── Error domain ─────────────────────────────────────────────────────────────

NSString * const VGWaveformExtractorErrorDomain = @"VGWaveformExtractor";

// ─── Log handle ───────────────────────────────────────────────────────────────

static os_log_t sWaveLog;

__attribute__((constructor))
static void _VGWaveformExtractorLogInit(void) {
    sWaveLog = os_log_create("com.vanguard.audio.waveform", "VGWaveformExtractor");
}

// ─── VGWaveformResult ────────────────────────────────────────────────────────

@implementation VGWaveformResult

- (instancetype)initWithSamplesData:(NSData *)samplesData
                    durationSeconds:(double)durationSeconds
                   samplesPerSecond:(NSInteger)samplesPerSecond
                         pointCount:(NSInteger)pointCount {
    NSParameterAssert(samplesData != nil);
    self = [super init];
    if (!self) return nil;
    _samplesData     = [samplesData copy];
    _durationSeconds = durationSeconds;
    _samplesPerSecond = samplesPerSecond;
    _pointCount      = pointCount;
    return self;
}

@end

// ─── VGWaveformExtractor ─────────────────────────────────────────────────────

@implementation VGWaveformExtractor {
    AVAsset          *_asset;
    dispatch_queue_t  _extractQueue;

    _Atomic(int32_t)  _cancelledAtomic;
    _Atomic(int32_t)  _startedAtomic;
}

- (instancetype)initWithAsset:(AVAsset *)asset {
    NSParameterAssert(asset != nil);
    self = [super init];
    if (!self) return nil;

    _asset = asset;
    atomic_init(&_cancelledAtomic, 0);
    atomic_init(&_startedAtomic, 0);

    _extractQueue = dispatch_queue_create(
        "com.vanguard.audio.waveform.extract",
        DISPATCH_QUEUE_SERIAL
    );
    return self;
}

- (void)cancel {
    atomic_store(&_cancelledAtomic, 1);
    os_log_debug(sWaveLog, "[VGWaveformExtractor] cancel requested");
}

// ─── Public entry point ───────────────────────────────────────────────────────

- (void)extractWithSamplesPerSecond:(NSInteger)samplesPerSecond
                 maxDurationSeconds:(double)maxDurationSeconds
                         completion:(void (^)(VGWaveformResult * _Nullable,
                                              NSError * _Nullable))completion {
    // Single-use gate.
    int32_t expected = 0;
    if (!atomic_compare_exchange_strong(&_startedAtomic, &expected, 1)) {
        os_log_debug(sWaveLog,
                     "[VGWaveformExtractor] already started — ignoring duplicate call");
        return;
    }

    // Validate parameters before dispatching.
    if (samplesPerSecond <= 0 || samplesPerSecond > 1000) {
        if (completion) {
            completion(nil, [self _errorCode:VGWaveformExtractorErrorReaderSetup
                                    message:@"samplesPerSecond must be in [1, 1000]"]);
        }
        return;
    }
    if (maxDurationSeconds <= 0.0) {
        if (completion) {
            completion(nil, [self _errorCode:VGWaveformExtractorErrorReaderSetup
                                    message:@"maxDurationSeconds must be > 0"]);
        }
        return;
    }

    dispatch_async(_extractQueue, ^{
        [self _runExtractionWithSamplesPerSecond:samplesPerSecond
                              maxDurationSeconds:maxDurationSeconds
                                     completion:completion];
    });
}

// ─── Private: main extraction ─────────────────────────────────────────────────

- (void)_runExtractionWithSamplesPerSecond:(NSInteger)samplesPerSecond
                        maxDurationSeconds:(double)maxDurationSeconds
                                completion:(void (^)(VGWaveformResult * _Nullable,
                                                     NSError * _Nullable))completion {

    // ── 1. Find first audio track ─────────────────────────────────────────────
    NSArray<AVAssetTrack *> *audioTracks =
        [_asset tracksWithMediaType:AVMediaTypeAudio];
    if (audioTracks.count == 0) {
        os_log_error(sWaveLog, "[VGWaveformExtractor] no audio track in asset");
        if (completion) {
            completion(nil, [self _errorCode:VGWaveformExtractorErrorNoAudioTrack
                                    message:@"Asset contains no audio track"]);
        }
        return;
    }
    AVAssetTrack *audioTrack = audioTracks.firstObject;

    // ── 2. Determine asset duration ───────────────────────────────────────────
    CMTime assetDuration = _asset.duration;
    double durationSecs = 0.0;
    if (CMTIME_IS_VALID(assetDuration) && CMTIME_IS_NUMERIC(assetDuration)) {
        durationSecs = CMTimeGetSeconds(assetDuration);
    }
    if (durationSecs <= 0.0) {
        os_log_error(sWaveLog, "[VGWaveformExtractor] asset has zero duration");
        if (completion) {
            completion(nil, [self _errorCode:VGWaveformExtractorErrorZeroDuration
                                    message:@"Asset has zero or invalid duration"]);
        }
        return;
    }

    // ── 3. Enforce duration limit ─────────────────────────────────────────────
    if (durationSecs > maxDurationSeconds) {
        os_log_error(sWaveLog,
                     "[VGWaveformExtractor] duration %.1fs exceeds limit %.1fs",
                     durationSecs, maxDurationSeconds);
        if (completion) {
            completion(nil,
                       [self _errorCode:VGWaveformExtractorErrorDurationExceeded
                               message:[NSString stringWithFormat:
                                        @"Duration %.1fs exceeds maxDurationSeconds %.1fs",
                                        durationSecs, maxDurationSeconds]]);
        }
        return;
    }

    // ── 4. Cancellation check ─────────────────────────────────────────────────
    if (atomic_load(&_cancelledAtomic) != 0) {
        if (completion) {
            completion(nil, [self _cancelledError]);
        }
        return;
    }

    // ── 5. Create AVAssetReader ───────────────────────────────────────────────
    NSError *readerErr = nil;
    AVAssetReader *reader = [AVAssetReader assetReaderWithAsset:_asset
                                                          error:&readerErr];
    if (!reader) {
        os_log_error(sWaveLog, "[VGWaveformExtractor] reader creation failed: %{public}@",
                     readerErr);
        if (completion) {
            completion(nil,
                       [self _errorCode:VGWaveformExtractorErrorReaderSetup
                               message:@"Failed to create AVAssetReader"
                            underlying:readerErr]);
        }
        return;
    }

    // ── 6. Configure AVAssetReaderTrackOutput ─────────────────────────────────
    // Int16, interleaved, mono, little-endian, no float, no forced sample rate.
    // Using only AudioToolbox software PCM codec — no coreaudiod IPC.
    NSDictionary *outputSettings = @{
        AVFormatIDKey:               @(kAudioFormatLinearPCM),
        AVLinearPCMBitDepthKey:      @16,
        AVLinearPCMIsFloatKey:       @NO,
        AVLinearPCMIsBigEndianKey:   @NO,
        AVLinearPCMIsNonInterleaved: @NO,
        AVNumberOfChannelsKey:       @1,    // mono downmix
    };
    AVAssetReaderTrackOutput *trackOutput =
        [AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:audioTrack
                                                  outputSettings:outputSettings];
    trackOutput.alwaysCopiesSampleData = NO;

    if (![reader canAddOutput:trackOutput]) {
        os_log_error(sWaveLog, "[VGWaveformExtractor] cannot add track output");
        if (completion) {
            completion(nil,
                       [self _errorCode:VGWaveformExtractorErrorReaderSetup
                               message:@"Cannot add AVAssetReaderTrackOutput to reader"]);
        }
        return;
    }
    [reader addOutput:trackOutput];

    // ── 7. Start reading ──────────────────────────────────────────────────────
    if (![reader startReading]) {
        os_log_error(sWaveLog, "[VGWaveformExtractor] startReading failed: %{public}@",
                     reader.error);
        if (completion) {
            completion(nil,
                       [self _errorCode:VGWaveformExtractorErrorReaderSetup
                               message:@"AVAssetReader failed to start reading"
                            underlying:reader.error]);
        }
        return;
    }

    os_log_debug(sWaveLog,
                 "[VGWaveformExtractor] starting extraction dur=%.2fs sps=%ld",
                 durationSecs, (long)samplesPerSecond);

    // ── 8. RMS extraction loop ────────────────────────────────────────────────
    // We accumulate sum-of-squares for each RMS window.
    // windowSize = sourceSampleRate / samplesPerSecond (determined from first buffer
    // or from asset track format description).
    // Since we do not force a sample rate, we read it from the track's ASBD.

    // Detect source sample rate from track format description.
    double sourceSampleRate = 44100.0; // safe fallback
    NSArray *fmtDescs = audioTrack.formatDescriptions;
    if (fmtDescs.count > 0) {
        CMAudioFormatDescriptionRef fmt =
            (__bridge CMAudioFormatDescriptionRef)fmtDescs.firstObject;
        if (fmt) {
            const AudioStreamBasicDescription *asbd =
                CMAudioFormatDescriptionGetStreamBasicDescription(fmt);
            if (asbd && asbd->mSampleRate > 0.0) {
                sourceSampleRate = asbd->mSampleRate;
            }
        }
    }

    // windowSize: number of Int16 samples per RMS output point.
    NSInteger windowSize = (NSInteger)round(sourceSampleRate / (double)samplesPerSecond);
    if (windowSize <= 0) windowSize = 441; // floor guard

    NSMutableData *outputData = [NSMutableData data];
    double sumOfSquares = 0.0;
    NSInteger samplesInWindow = 0;
    NSInteger totalPoints = 0;
    BOOL readerFailed = NO;

    while (YES) {
        @autoreleasepool {
            // Cancellation check inside loop.
            if (atomic_load(&_cancelledAtomic) != 0) {
                [reader cancelReading];
                if (completion) {
                    completion(nil, [self _cancelledError]);
                }
                return;
            }

            CMSampleBufferRef sampleBuffer = [trackOutput copyNextSampleBuffer];

            if (!sampleBuffer) {
                // EOF or reader error.
                if (reader.status == AVAssetReaderStatusFailed) {
                    os_log_error(sWaveLog,
                                 "[VGWaveformExtractor] reader failed: %{public}@",
                                 reader.error);
                    readerFailed = YES;
                }
                break;
            }

            // Extract raw Int16 data directly via CMBlockBuffer.
            // No AudioBufferList, no retained block buffer copy.
            CMBlockBufferRef blockBuf = CMSampleBufferGetDataBuffer(sampleBuffer);
            if (blockBuf) {
                size_t totalLength = 0;
                char *dataPointer = NULL;
                OSStatus status = CMBlockBufferGetDataPointer(
                    blockBuf, 0, NULL, &totalLength, &dataPointer);

                if (status == kCMBlockBufferNoErr && dataPointer && totalLength > 0) {
                    NSInteger sampleCount = (NSInteger)(totalLength / sizeof(int16_t));
                    const int16_t *samples = (const int16_t *)dataPointer;

                    for (NSInteger i = 0; i < sampleCount; i++) {
                        double normalised = (double)samples[i] / 32768.0;
                        sumOfSquares += normalised * normalised;
                        samplesInWindow++;

                        if (samplesInWindow >= windowSize) {
                            float rms = (float)sqrt(sumOfSquares / (double)windowSize);
                            [outputData appendBytes:&rms length:sizeof(float)];
                            totalPoints++;
                            sumOfSquares = 0.0;
                            samplesInWindow = 0;
                        }
                    }
                }
            }

            // Release immediately — do not retain across iterations.
            CFRelease(sampleBuffer);
        } // @autoreleasepool drains here
    }

    // Emit final partial window if it is >= 50% full.
    if (!readerFailed && samplesInWindow >= windowSize / 2 && samplesInWindow > 0) {
        float rms = (float)sqrt(sumOfSquares / (double)samplesInWindow);
        [outputData appendBytes:&rms length:sizeof(float)];
        totalPoints++;
    }

    if (readerFailed) {
        if (completion) {
            completion(nil,
                       [self _errorCode:VGWaveformExtractorErrorReaderFailed
                               message:@"AVAssetReader failed during extraction"
                            underlying:reader.error]);
        }
        return;
    }

    os_log_debug(sWaveLog,
                 "[VGWaveformExtractor] done — %ld points, dur=%.2fs",
                 (long)totalPoints, durationSecs);

    VGWaveformResult *waveResult =
        [[VGWaveformResult alloc] initWithSamplesData:outputData
                                      durationSeconds:durationSecs
                                     samplesPerSecond:samplesPerSecond
                                           pointCount:totalPoints];
    if (completion) {
        completion(waveResult, nil);
    }
}

// ─── Private: error helpers ───────────────────────────────────────────────────

- (NSError *)_errorCode:(VGWaveformExtractorErrorCode)code
                message:(NSString *)message {
    return [self _errorCode:code message:message underlying:nil];
}

- (NSError *)_errorCode:(VGWaveformExtractorErrorCode)code
                message:(NSString *)message
             underlying:(nullable NSError *)underlying {
    NSMutableDictionary *info = [NSMutableDictionary dictionary];
    info[NSLocalizedDescriptionKey] = message;
    if (underlying) {
        info[NSUnderlyingErrorKey] = underlying;
    }
    return [NSError errorWithDomain:VGWaveformExtractorErrorDomain
                               code:code
                           userInfo:[info copy]];
}

- (NSError *)_cancelledError {
    return [self _errorCode:VGWaveformExtractorErrorCancelled
                    message:@"Waveform extraction was cancelled"];
}

@end
