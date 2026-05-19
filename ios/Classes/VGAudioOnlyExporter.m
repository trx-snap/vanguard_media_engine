// VGAudioOnlyExporter.m
// vanguard_media_engine — Phase 5E-2
//
// Offline audio-only export: AVAssetReader → AVAssetWriter pump.
//
// Pipeline:
//   AVAsset (source)
//   → AVAssetReader
//     → AVAssetReaderTrackOutput (decompresses audio to PCM)
//       → requestMediaDataWhenReadyOnQueue sample pump
//         → AVAssetWriterInput (encodes to AAC or PCM)
//           → AVAssetWriter (M4A or WAV container)
//             → output file
//   → VGAudioExportManifest (actual output metadata)
//
// Apple API contracts verified before implementation:
//   - AVAssetReaderTrackOutput inherits copyNextSampleBuffer (returns nil at EOF)
//   - Reader output settings kAudioFormatLinearPCM decompresses audio to PCM
//   - alwaysCopiesSampleData = NO avoids unnecessary buffer copies
//   - requestMediaDataWhenReadyOnQueue:usingBlock: is the correct offline pull pattern
//   - markAsFinished must be called before finishWritingWithCompletionHandler:
//   - finishWritingWithCompletionHandler: — check writer.status in handler
//   - AVFileTypeAppleM4A supported for audio-only M4A
//   - AVFileTypeWAVE supported; AVLinearPCMIsFloatKey must be NO
//   - cancelWriting blocks calling thread — dispatched to global queue to avoid deadlock
//   - cancelWriting deletes the output file automatically
//   - cancelReading stops reader from producing more samples
//   - expectsMediaDataInRealTime = NO for offline export
//   - AVAssetWriter cannot overwrite existing files — delete first
//
// Forbidden imports:
//   VGFrameSink, VGFrameEnvelope, VGGraphSchedulerV2, VGExportScheduler,
//   VGGraphDescriptor, VGGraphValidator, VGGraphPlanner, VGGraphExecutionContext,
//   VGVideoEncoderSinkNode, VGImageEncoderSinkNode, VGExportGraphFactory

#import "VGAudioOnlyExporter.h"
#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <CoreMedia/CoreMedia.h>
#import <stdatomic.h>
#import <os/log.h>

// ─── Error domain ─────────────────────────────────────────────────────────────

NSString * const VGAudioOnlyExporterErrorDomain = @"VGAudioOnlyExporter";

// ─── Log handle ───────────────────────────────────────────────────────────────

static os_log_t sExporterLog;

__attribute__((constructor))
static void _VGAudioOnlyExporterLogInit(void) {
    sExporterLog = os_log_create("com.vanguard.export.audio", "VGAudioOnlyExporter");
}

// ─── Implementation ───────────────────────────────────────────────────────────

@implementation VGAudioOnlyExporter {
    // Init-time inputs (strongly retained)
    AVAsset              *_asset;
    VGAudioExportProfile *_profile;
    NSURL                *_outputURL;

    // Private serial export queue
    dispatch_queue_t _exportQueue;

    // User completion block (copied on start)
    void (^_completion)(VGAudioExportManifest * _Nullable, NSError * _Nullable);

    // State flags (all int32, 0 = NO, 1 = YES)
    _Atomic(int32_t) _startedAtomic;
    _Atomic(int32_t) _completionFired;
    _Atomic(int32_t) _cancelledAtomic;
    _Atomic(int32_t) _finishedAtomic;

    // Pipeline objects (created in _runExport)
    AVAssetReader *_reader;
    AVAssetWriter *_writer;
}

// ─── Designated initializer ───────────────────────────────────────────────────

- (instancetype)initWithAsset:(AVAsset *)asset
                      profile:(VGAudioExportProfile *)profile
                    outputURL:(NSURL *)outputURL {
    NSParameterAssert(asset != nil);
    NSParameterAssert(profile != nil);
    NSParameterAssert(outputURL != nil);

    self = [super init];
    if (!self) return nil;

    _asset     = asset;
    _profile   = profile;
    _outputURL = [outputURL copy];

    atomic_init(&_startedAtomic,    0);
    atomic_init(&_completionFired,  0);
    atomic_init(&_cancelledAtomic,  0);
    atomic_init(&_finishedAtomic,   0);

    _exportQueue = dispatch_queue_create(
        "com.vanguard.export.audio.session",
        DISPATCH_QUEUE_SERIAL
    );

    os_log_debug(sExporterLog,
                 "[VGAudioOnlyExporter] init outputURL=%{public}@",
                 outputURL.lastPathComponent);
    return self;
}

// ─── State accessors ──────────────────────────────────────────────────────────

- (BOOL)isExporting {
    return atomic_load(&_startedAtomic) != 0
        && atomic_load(&_finishedAtomic) == 0;
}

- (BOOL)isCancelled {
    return atomic_load(&_cancelledAtomic) != 0;
}

- (BOOL)isFinished {
    return atomic_load(&_finishedAtomic) != 0;
}

// ─── Cancel ───────────────────────────────────────────────────────────────────

- (void)cancel {
    atomic_store(&_cancelledAtomic, 1);
    // The sample pump checks this flag on each iteration and performs
    // safe cleanup (markAsFinished → cancelReading → cancelWriting on
    // global queue). We do not call cancelWriting here because it blocks
    // and the caller's thread is unknown.
    os_log_debug(sExporterLog, "[VGAudioOnlyExporter] cancel requested");
}

// ─── Start ────────────────────────────────────────────────────────────────────

- (void)startWithCompletion:(void (^)(VGAudioExportManifest * _Nullable,
                                      NSError * _Nullable))completion {
    // Single-use gate: CAS 0→1.
    int32_t expected = 0;
    if (!atomic_compare_exchange_strong(&_startedAtomic, &expected, 1)) {
        // Already started — no-op.
        os_log_debug(sExporterLog,
                     "[VGAudioOnlyExporter] startWithCompletion: already started, ignoring");
        return;
    }

    _completion = completion ? [completion copy] : nil;

    // Pre-cancelled path.
    if (atomic_load(&_cancelledAtomic) != 0) {
        dispatch_async(_exportQueue, ^{
            [self _fireCompletionWithManifest:nil
                                       error:[self _errorWithCode:VGAudioOnlyExporterErrorCancelled
                                                          message:@"Audio export was cancelled before it started"
                                                       underlying:nil]];
        });
        return;
    }

    dispatch_async(_exportQueue, ^{
        [self _runExport];
    });
}

// ─── Private: main export sequence ────────────────────────────────────────────

- (void)_runExport {
    // ── Step 1: Validate profile ──────────────────────────────────────────────

    if (!_profile || _profile.sampleRate <= 0 || _profile.channels == 0
        || _profile.containerFormat.length == 0) {
        [self _fireCompletionWithManifest:nil
                                   error:[self _errorWithCode:VGAudioOnlyExporterErrorInvalidProfile
                                                      message:@"Invalid export profile"
                                                   underlying:nil]];
        return;
    }

    if (_profile.codec == VGAudioCodecOpus) {
        [self _fireCompletionWithManifest:nil
                                   error:[self _errorWithCode:VGAudioOnlyExporterErrorUnsupportedCodec
                                                      message:@"VGAudioCodecOpus is not supported on iOS < 15"
                                                   underlying:nil]];
        return;
    }

    NSString *fmt = _profile.containerFormat;
    BOOL isM4A = [fmt isEqualToString:@"m4a"];
    BOOL isWAV = [fmt isEqualToString:@"wav"];

    if (!isM4A && !isWAV) {
        [self _fireCompletionWithManifest:nil
                                   error:[self _errorWithCode:VGAudioOnlyExporterErrorUnsupportedFormat
                                                      message:[NSString stringWithFormat:
                                                               @"Unsupported container format: %@", fmt]
                                                   underlying:nil]];
        return;
    }

    if (isM4A && _profile.codec != VGAudioCodecAAC) {
        [self _fireCompletionWithManifest:nil
                                   error:[self _errorWithCode:VGAudioOnlyExporterErrorUnsupportedFormat
                                                      message:@"M4A container requires VGAudioCodecAAC"
                                                   underlying:nil]];
        return;
    }

    if (isWAV && _profile.codec != VGAudioCodecPCM) {
        [self _fireCompletionWithManifest:nil
                                   error:[self _errorWithCode:VGAudioOnlyExporterErrorUnsupportedFormat
                                                      message:@"WAV container requires VGAudioCodecPCM"
                                                   underlying:nil]];
        return;
    }

    // ── Step 2: Remove existing output file ───────────────────────────────────
    // AVAssetWriter cannot overwrite. Ignore "file not found" errors.

    NSFileManager *fm = [NSFileManager defaultManager];
    if ([fm fileExistsAtPath:_outputURL.path]) {
        NSError *removeErr = nil;
        if (![fm removeItemAtURL:_outputURL error:&removeErr]) {
            [self _fireCompletionWithManifest:nil
                                       error:[self _errorWithCode:VGAudioOnlyExporterErrorInvalidOutputURL
                                                          message:@"Failed to remove existing output file"
                                                       underlying:removeErr]];
            return;
        }
    }

    // ── Step 3: Find first audio track ────────────────────────────────────────

    NSArray<AVAssetTrack *> *audioTracks = [_asset tracksWithMediaType:AVMediaTypeAudio];
    if (audioTracks.count == 0) {
        [self _fireCompletionWithManifest:nil
                                   error:[self _errorWithCode:VGAudioOnlyExporterErrorNoAudioTrack
                                                      message:@"Source asset contains no audio track"
                                                   underlying:nil]];
        return;
    }

    AVAssetTrack *audioTrack = audioTracks.firstObject;

    // ── Step 4: Cancellation check ────────────────────────────────────────────

    if (atomic_load(&_cancelledAtomic) != 0) {
        [self _fireCompletionWithManifest:nil
                                   error:[self _cancelledError]];
        return;
    }

    // ── Step 5: Create AVAssetReader ──────────────────────────────────────────

    NSError *readerErr = nil;
    _reader = [AVAssetReader assetReaderWithAsset:_asset error:&readerErr];
    if (!_reader) {
        [self _fireCompletionWithManifest:nil
                                   error:[self _errorWithCode:VGAudioOnlyExporterErrorReaderSetup
                                                      message:@"Failed to create AVAssetReader"
                                                   underlying:readerErr]];
        return;
    }

    // ── Step 6: Create AVAssetReaderTrackOutput ────────────────────────────────
    // Request PCM decompression so the pump produces raw samples
    // that can be re-encoded by AVAssetWriterInput.

    NSDictionary *readerSettings = @{
        AVFormatIDKey:             @(kAudioFormatLinearPCM),
        AVLinearPCMBitDepthKey:    @16,
        AVLinearPCMIsFloatKey:     @NO,
        AVLinearPCMIsBigEndianKey: @NO,
        AVLinearPCMIsNonInterleaved: @NO,
    };

    AVAssetReaderTrackOutput *trackOutput =
        [AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:audioTrack
                                                  outputSettings:readerSettings];
    // Avoid unnecessary buffer copies — we do not modify sample data in-place.
    trackOutput.alwaysCopiesSampleData = NO;

    if (![_reader canAddOutput:trackOutput]) {
        [self _fireCompletionWithManifest:nil
                                   error:[self _errorWithCode:VGAudioOnlyExporterErrorReaderSetup
                                                      message:@"Cannot add AVAssetReaderTrackOutput to reader"
                                                   underlying:nil]];
        return;
    }
    [_reader addOutput:trackOutput];

    // ── Step 7: Determine writer file type and input settings ──────────────────

    AVFileType fileType;
    NSDictionary *writerSettings;

    if (isM4A) {
        fileType = AVFileTypeAppleM4A;
        NSMutableDictionary *settings = [@{
            AVFormatIDKey:         @(kAudioFormatMPEG4AAC),
            AVSampleRateKey:       @(_profile.sampleRate),
            AVNumberOfChannelsKey: @(_profile.channels),
        } mutableCopy];
        // Include bitrate only if specified. If 0, let the encoder choose default.
        if (_profile.bitrate > 0) {
            settings[AVEncoderBitRateKey] = @(_profile.bitrate);
        }
        writerSettings = [settings copy];
    } else {
        // WAV / PCM — float LPCM is not supported by AVAssetWriter WAV container.
        fileType = AVFileTypeWAVE;
        writerSettings = @{
            AVFormatIDKey:               @(kAudioFormatLinearPCM),
            AVSampleRateKey:             @(_profile.sampleRate),
            AVNumberOfChannelsKey:       @(_profile.channels),
            AVLinearPCMBitDepthKey:      @16,
            AVLinearPCMIsFloatKey:       @NO,
            AVLinearPCMIsBigEndianKey:   @NO,
            AVLinearPCMIsNonInterleaved: @NO,
        };
    }

    // ── Step 8: Create AVAssetWriter ──────────────────────────────────────────

    NSError *writerErr = nil;
    _writer = [AVAssetWriter assetWriterWithURL:_outputURL
                                       fileType:fileType
                                          error:&writerErr];
    if (!_writer) {
        [self _fireCompletionWithManifest:nil
                                   error:[self _errorWithCode:VGAudioOnlyExporterErrorWriterSetup
                                                      message:@"Failed to create AVAssetWriter"
                                                   underlying:writerErr]];
        return;
    }

    // ── Step 9: Create AVAssetWriterInput ─────────────────────────────────────

    AVAssetWriterInput *writerInput =
        [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeAudio
                                          outputSettings:writerSettings];
    writerInput.expectsMediaDataInRealTime = NO;

    if (![_writer canAddInput:writerInput]) {
        [self _fireCompletionWithManifest:nil
                                   error:[self _errorWithCode:VGAudioOnlyExporterErrorWriterSetup
                                                      message:@"Cannot add AVAssetWriterInput to writer"
                                                   underlying:nil]];
        return;
    }
    [_writer addInput:writerInput];

    // ── Step 10: Start writer ─────────────────────────────────────────────────

    if (![_writer startWriting]) {
        [self _fireCompletionWithManifest:nil
                                   error:[self _errorWithCode:VGAudioOnlyExporterErrorWriterStart
                                                      message:@"AVAssetWriter failed to start writing"
                                                   underlying:_writer.error]];
        return;
    }
    [_writer startSessionAtSourceTime:kCMTimeZero];

    // ── Step 11: Start reader ─────────────────────────────────────────────────

    if (![_reader startReading]) {
        [self _fireCompletionWithManifest:nil
                                   error:[self _errorWithCode:VGAudioOnlyExporterErrorReaderStart
                                                      message:@"AVAssetReader failed to start reading"
                                                   underlying:_reader.error]];
        return;
    }

    os_log_debug(sExporterLog, "[VGAudioOnlyExporter] starting sample pump");

    // ── Step 12: Sample pump ──────────────────────────────────────────────────
    // Use requestMediaDataWhenReadyOnQueue on our private serial queue.
    // This is the correct offline "pull" pattern per Apple docs.
    // Do NOT dispatch_async inside the block — synchronous loop only.

    __weak typeof(self) weakSelf = self;

    [writerInput requestMediaDataWhenReadyOnQueue:_exportQueue usingBlock:^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;

        while (writerInput.readyForMoreMediaData) {

            // Cancellation check at the top of each iteration.
            if (atomic_load(&strongSelf->_cancelledAtomic) != 0) {
                [writerInput markAsFinished];
                // cancelReading stops the reader immediately.
                AVAssetReader *reader = strongSelf->_reader;
                [reader cancelReading];
                // cancelWriting blocks — dispatch to global queue to avoid
                // blocking the export queue from future use.
                AVAssetWriter *writer = strongSelf->_writer;
                dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
                    [writer cancelWriting];
                });
                [strongSelf _fireCompletionWithManifest:nil
                                                  error:[strongSelf _cancelledError]];
                return;
            }

            // Pull next sample from reader.
            CMSampleBufferRef sample = [trackOutput copyNextSampleBuffer];

            if (!sample) {
                // EOF or reader error.
                AVAssetReaderStatus readerStatus = strongSelf->_reader.status;

                if (readerStatus == AVAssetReaderStatusFailed) {
                    NSError *readErr = strongSelf->_reader.error;
                    os_log_error(sExporterLog,
                                 "[VGAudioOnlyExporter] reader failed: %{public}@", readErr);
                    [writerInput markAsFinished];
                    AVAssetWriter *writer = strongSelf->_writer;
                    dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
                        [writer cancelWriting];
                    });
                    [strongSelf _fireCompletionWithManifest:nil
                                                      error:[strongSelf
                                                             _errorWithCode:VGAudioOnlyExporterErrorWriterFailed
                                                             message:@"AVAssetReader failed during export"
                                                             underlying:readErr]];
                    return;
                }

                if (readerStatus == AVAssetReaderStatusCancelled) {
                    [writerInput markAsFinished];
                    [strongSelf _fireCompletionWithManifest:nil
                                                      error:[strongSelf _cancelledError]];
                    return;
                }

                // Reader completed (EOF) — mark input finished and finish writer.
                // markAsFinished MUST be called before finishWritingWithCompletionHandler:.
                [writerInput markAsFinished];
                os_log_debug(sExporterLog,
                             "[VGAudioOnlyExporter] EOF — finishing writer");
                [strongSelf->_writer finishWritingWithCompletionHandler:^{
                    [strongSelf _handleWriterFinished];
                }];
                return;
            }

            // Append sample to writer input.
            BOOL appended = [writerInput appendSampleBuffer:sample];
            CFRelease(sample);

            if (!appended) {
                NSError *appendErr = strongSelf->_writer.error;
                os_log_error(sExporterLog,
                             "[VGAudioOnlyExporter] append failed: %{public}@", appendErr);
                // Do not call markAsFinished — the input is in an error state.
                AVAssetReader *reader = strongSelf->_reader;
                [reader cancelReading];
                AVAssetWriter *writer = strongSelf->_writer;
                dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
                    [writer cancelWriting];
                });
                [strongSelf _fireCompletionWithManifest:nil
                                                  error:[strongSelf
                                                         _errorWithCode:VGAudioOnlyExporterErrorWriterFailed
                                                         message:@"Failed to append sample buffer"
                                                         underlying:appendErr]];
                return;
            }
        }
        // Block exits — system will call again when writer is ready for more data.
    }];
}

// ─── Private: writer finish handler ───────────────────────────────────────────

- (void)_handleWriterFinished {
    // If cancelled while finishing, report cancellation.
    if (atomic_load(&_cancelledAtomic) != 0) {
        [self _fireCompletionWithManifest:nil error:[self _cancelledError]];
        return;
    }

    AVAssetWriterStatus status = _writer.status;
    switch (status) {
        case AVAssetWriterStatusCompleted:
            [self _buildManifestAndComplete];
            break;

        case AVAssetWriterStatusFailed: {
            NSError *writerErr = _writer.error;
            os_log_error(sExporterLog,
                         "[VGAudioOnlyExporter] writer finish failed: %{public}@", writerErr);
            [self _fireCompletionWithManifest:nil
                                       error:[self _errorWithCode:VGAudioOnlyExporterErrorWriterFailed
                                                          message:@"AVAssetWriter finishWriting failed"
                                                       underlying:writerErr]];
            break;
        }

        case AVAssetWriterStatusCancelled:
            [self _fireCompletionWithManifest:nil error:[self _cancelledError]];
            break;

        default: {
            NSError *err = [self _errorWithCode:VGAudioOnlyExporterErrorWriterFailed
                                        message:[NSString stringWithFormat:
                                                 @"AVAssetWriter finished with unexpected status: %ld",
                                                 (long)status]
                                     underlying:nil];
            [self _fireCompletionWithManifest:nil error:err];
            break;
        }
    }
}

// ─── Private: build manifest from actual output ───────────────────────────────

- (void)_buildManifestAndComplete {
    NSFileManager *fm = [NSFileManager defaultManager];

    // Verify output file exists.
    if (![fm fileExistsAtPath:_outputURL.path]) {
        [self _fireCompletionWithManifest:nil
                                   error:[self _errorWithCode:VGAudioOnlyExporterErrorOutputMissing
                                                      message:@"Output file missing after write"
                                                   underlying:nil]];
        return;
    }

    // Get actual file size.
    NSError *attrErr = nil;
    NSDictionary *attrs = [fm attributesOfItemAtPath:_outputURL.path error:&attrErr];
    int64_t fileSizeBytes = (int64_t)[attrs[NSFileSize] longLongValue];

    if (fileSizeBytes <= 0) {
        [self _fireCompletionWithManifest:nil
                                   error:[self _errorWithCode:VGAudioOnlyExporterErrorOutputMissing
                                                      message:@"Output file is empty after write"
                                                   underlying:nil]];
        return;
    }

    // Read actual output metadata from the written file.
    // Default to profile values as safe fallback.
    float actualSampleRate   = _profile.sampleRate;
    uint32_t actualChannels  = _profile.channels;
    NSTimeInterval actualDuration = 0.0;

    AVAsset *outputAsset = [AVAsset assetWithURL:_outputURL];
    CMTime duration = outputAsset.duration;
    if (CMTIME_IS_VALID(duration) && CMTIME_IS_NUMERIC(duration)) {
        actualDuration = CMTimeGetSeconds(duration);
    }
    if (actualDuration < 0.0) actualDuration = 0.0;

    NSArray<AVAssetTrack *> *outputTracks =
        [outputAsset tracksWithMediaType:AVMediaTypeAudio];

    if (outputTracks.count > 0) {
        AVAssetTrack *outTrack = outputTracks.firstObject;
        NSArray *fmtDescs = outTrack.formatDescriptions;
        if (fmtDescs.count > 0) {
            CMFormatDescriptionRef fmt =
                (__bridge CMFormatDescriptionRef)fmtDescs.firstObject;
            if (fmt) {
                const AudioStreamBasicDescription *asbd =
                    CMAudioFormatDescriptionGetStreamBasicDescription(fmt);
                if (asbd) {
                    if (asbd->mSampleRate > 0.0) {
                        actualSampleRate = (float)asbd->mSampleRate;
                    }
                    if (asbd->mChannelsPerFrame > 0) {
                        actualChannels = asbd->mChannelsPerFrame;
                    }
                }
            }
        }
    }

    // Bitrate: PCM/WAV is always 0 (lossless). AAC uses profile bitrate.
    uint32_t actualBitrate = 0;
    if (_profile.codec == VGAudioCodecAAC) {
        actualBitrate = _profile.bitrate; // 0 = codec default; preserved as-is.
    }

    os_log_debug(sExporterLog,
                 "[VGAudioOnlyExporter] manifest — %.0fHz ch=%u dur=%.2fs size=%lld fmt=%{public}@",
                 actualSampleRate, actualChannels, actualDuration,
                 fileSizeBytes, _profile.containerFormat);

    VGAudioExportManifest *manifest =
        [[VGAudioExportManifest alloc] initWithCodec:_profile.codec
                                          sampleRate:actualSampleRate
                                            channels:actualChannels
                                             bitrate:actualBitrate
                                     durationSeconds:actualDuration
                                       fileSizeBytes:fileSizeBytes
                                     containerFormat:_profile.containerFormat];

    [self _fireCompletionWithManifest:manifest error:nil];
}

// ─── Private: completion gate ─────────────────────────────────────────────────

/// Fire user completion exactly once via CAS gate (0→1).
- (void)_fireCompletionWithManifest:(nullable VGAudioExportManifest *)manifest
                              error:(nullable NSError *)error {
    int32_t expected = 0;
    if (!atomic_compare_exchange_strong(&_completionFired, &expected, 1)) {
        return; // Already fired.
    }

    atomic_store(&_finishedAtomic, 1);

    void (^cb)(VGAudioExportManifest *, NSError *) = _completion;
    _completion = nil; // Release block.

    if (cb) {
        cb(manifest, error);
    }
}

// ─── Private: error helpers ───────────────────────────────────────────────────

- (NSError *)_errorWithCode:(VGAudioOnlyExporterErrorCode)code
                    message:(NSString *)message
                 underlying:(nullable NSError *)underlying {
    NSMutableDictionary *info = [NSMutableDictionary dictionary];
    info[NSLocalizedDescriptionKey] = message;
    if (underlying) {
        info[NSUnderlyingErrorKey] = underlying;
    }
    return [NSError errorWithDomain:VGAudioOnlyExporterErrorDomain
                               code:code
                           userInfo:[info copy]];
}

- (NSError *)_cancelledError {
    return [self _errorWithCode:VGAudioOnlyExporterErrorCancelled
                        message:@"Audio export was cancelled"
                     underlying:nil];
}

// ─── Dealloc ──────────────────────────────────────────────────────────────────

- (void)dealloc {
    // Safety net: set cancel flag. The pump will see it on next iteration.
    // Do not block in dealloc.
    atomic_store(&_cancelledAtomic, 1);
}

@end
