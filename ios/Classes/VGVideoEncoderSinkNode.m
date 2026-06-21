// VGVideoEncoderSinkNode.m
// vanguard_media_engine — Phase 5C-4
//
// Concrete VGFrameSink: VanguardVideoToolboxEncoder + AVAssetWriter.
//
// Pull-mode only. No VGGraphSchedulerV2. No push callbacks. No camera path.
//
// Key architectural invariants:
//   - presentEnvelope: blocks until append completes (corrected signal ordering).
//   - AVAssetWriterInput created lazily on first sample with sourceFormatHint:.
//   - VGRetainedBuffer ensures CVPixelBuffer survives async VT crossing.
//   - Semaphore signaled in encodedSampleHandler (success) or
//     frameCompletionHandler (error/drop) — exactly once per frame.
//
// NOT imported:
//   VGGraphSchedulerV2, VanguardFileMediaSource, VanguardGraphRuntime,
//   VanguardMetalRenderer, VGFrameDelegate.

#import "VGVideoEncoderSinkNode.h"
#import "VanguardVideoToolboxEncoder.h"
#import <UMF/VGRetainedBuffer.h>
#import <UMF/VGGraphExecutionContext.h>
#import <UMF/VGFrameEnvelope.h>
#import <UMF/VGMediaFormat.h>

#import <CoreVideo/CoreVideo.h>
#import <CoreMedia/CoreMedia.h>
#import <VideoToolbox/VideoToolbox.h>

NS_ASSUME_NONNULL_BEGIN

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - @implementation
// ─────────────────────────────────────────────────────────────────────────────

@implementation VGVideoEncoderSinkNode {
    // Identity
    NSString                        *_nodeId;

    // Init-time config
    NSURL                           *_outputURL;
    VGExportProfile                 *_profile;

    // State
    BOOL                             _ready;
    BOOL                             _invalidated;
    NSInteger                        _framesSubmitted;

    // Encoder (created in prepareWithContext:)
    VanguardVideoToolboxEncoder      *_encoder;

    // Writer (created in prepareWithContext:; input created lazily on first sample)
    AVAssetWriter                   *_writer;
    AVAssetWriterInput              *_writerInput;  // nil until first encoded sample
    BOOL                             _writerStarted; // YES after startWriting

    // Semaphore: signals exactly once per frame (see signal ordering comments)
    dispatch_semaphore_t             _encodeSemaphore;

    // Per-frame encode status (set by frameCompletionHandler before signal)
    OSStatus                         _lastEncodeStatus;
    VTEncodeInfoFlags                _lastEncodeFlags;
}

@synthesize ready = _ready;
@synthesize framesSubmitted = _framesSubmitted;

// ─── VGNode identity ──────────────────────────────────────────────────────────

- (NSString *)nodeId    { return _nodeId; }
- (NSString *)nodeClass { return @"VGVideoEncoderSinkNode"; }
- (VGNodeRole)nodeRole  { return VGNodeRoleSink; }

- (NSArray<VGMediaPort *> *)declaredPorts {
    // Sink: one required video_in port. No output ports.
    return @[ [VGMediaPort inputPort:@"video_in"
                           mediaType:VGMediaTypeVideo
                            required:YES] ];
}

- (nullable VGMediaFormat *)negotiateFormatForPort:(NSString *)portId
                                      inputFormats:(NSDictionary<NSString *, VGMediaFormat *> *)inputFormats {
    // Sink nodes do not produce output — no format negotiation needed.
    return nil;
}

// ─── Init ─────────────────────────────────────────────────────────────────────

- (instancetype)initWithOutputURL:(NSURL *)outputURL
                          profile:(VGExportProfile *)profile {
    NSParameterAssert(outputURL != nil);
    NSParameterAssert(profile != nil);

    self = [super init];
    if (!self) return nil;

    _nodeId         = [[NSUUID UUID] UUIDString];
    _outputURL      = outputURL;
    _profile        = profile;

    _ready          = NO;
    _invalidated    = NO;
    _framesSubmitted = 0;

    _encoder        = nil;
    _writer         = nil;
    _writerInput    = nil;
    _writerStarted  = NO;

    _encodeSemaphore = dispatch_semaphore_create(0);
    _lastEncodeStatus = noErr;
    _lastEncodeFlags  = 0;

    return self;
}

// ─── VGNode lifecycle ──────────────────────────────────────────────────────────

- (void)prepareWithContext:(VGGraphExecutionContext *)context
                completion:(void (^)(NSError *_Nullable))completion {
    NSAssert(completion != nil, @"VGVideoEncoderSinkNode: completion must not be nil");

    if (_invalidated) {
        completion([NSError errorWithDomain:@"VGVideoEncoderSinkNode"
                                       code:10
                                   userInfo:@{
            NSLocalizedDescriptionKey: @"Node is invalidated"
        }]);
        return;
    }

    // ── 1. Delete existing output file (Apple: AVAssetWriter cannot overwrite) ─
    NSFileManager *fm = [NSFileManager defaultManager];
    if ([fm fileExistsAtPath:_outputURL.path]) {
        NSError *deleteErr = nil;
        [fm removeItemAtURL:_outputURL error:&deleteErr];
        if (deleteErr) {
            completion(deleteErr);
            return;
        }
    }

    // ── 2. Create AVAssetWriter (eagerly, no startWriting yet) ────────────────
    NSError *writerErr = nil;
    _writer = [AVAssetWriter assetWriterWithURL:_outputURL
                                       fileType:AVFileTypeMPEG4
                                          error:&writerErr];
    if (!_writer || writerErr) {
        completion(writerErr ?: [NSError errorWithDomain:@"VGVideoEncoderSinkNode"
                                                    code:11
                                                userInfo:@{
            NSLocalizedDescriptionKey: @"Failed to create AVAssetWriter"
        }]);
        return;
    }
    // Note: _writerInput created lazily in _appendEncodedSample: on first sample.

    // ── 3. Create VanguardVideoToolboxEncoder ─────────────────────────────────
    _encoder = [[VanguardVideoToolboxEncoder alloc]
        initWithWidth:(int)_profile.width
               height:(int)_profile.height
              bitrate:(int)_profile.bitrateBps
                  fps:(int)_profile.fps
            codecType:_profile.codecType
         profileLevel:_profile.profileLevel
                usage:VGEncoderUsageOffline
             quality:(float)_profile.quality   // Phase 10-C: 0.0 = bitrate-driven; >0 = CQ mode
        packetHandler:nil];  // No Annex-B NAL path for export

    if (!_encoder.isReady) {
        completion([NSError errorWithDomain:@"VGVideoEncoderSinkNode"
                                       code:12
                                   userInfo:@{
            NSLocalizedDescriptionKey: @"VTCompressionSession creation failed"
        }]);
        return;
    }

    // ── 4. Wire encoder handlers ──────────────────────────────────────────────
    //
    // SEMAPHORE SIGNAL ORDERING (CRITICAL — see header comments):
    //
    //   vtOutputCallback fires in this order (Phase 5B):
    //     1. frameCompletionHandler  — UNCONDITIONAL, FIRST
    //     2. encodedSampleHandler    — SUCCESS ONLY
    //
    //   Signal rule (exactly once per frame):
    //     - On error (status != noErr):           signal in frameCompletionHandler
    //     - On drop (kVTEncodeInfo_FrameDropped): signal in frameCompletionHandler
    //     - On success (noErr, no drop):          signal in encodedSampleHandler
    //                                             AFTER appendSampleBuffer completes
    //
    //   This guarantees presentEnvelope: does NOT return before the compressed
    //   sample has been written to AVAssetWriterInput.

    __weak typeof(self) weakSelf = self;

    _encoder.frameCompletionHandler = ^(OSStatus status, VTEncodeInfoFlags flags) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;

        strongSelf->_lastEncodeStatus = status;
        strongSelf->_lastEncodeFlags  = flags;

        // Determine if encodedSampleHandler will follow.
        // Apple VT: noErr + no FrameDropped → sampleBuffer non-NULL → handler fires.
        BOOL willHaveSample = (status == noErr) &&
                              !(flags & kVTEncodeInfo_FrameDropped);
        if (!willHaveSample) {
            // Error or drop — no sample handler will fire → signal now.
            dispatch_semaphore_signal(strongSelf->_encodeSemaphore);
        }
        // Success path → encodedSampleHandler will signal after append.
    };

    _encoder.encodedSampleHandler = ^(CMSampleBufferRef sampleBuffer) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;

        // Append to writer (lazy init on first sample).
        [strongSelf _appendEncodedSample:sampleBuffer];

        // Signal AFTER append — presentEnvelope: may now return.
        dispatch_semaphore_signal(strongSelf->_encodeSemaphore);
    };

    _ready = YES;
    completion(nil);
}

- (void)invalidate {
    if (_invalidated) return;
    _invalidated = YES;
    _ready = NO;

    // Cancel writer if still writing (synchronous).
    if (_writer && _writer.status == AVAssetWriterStatusWriting) {
        [_writer cancelWriting];
    }

    // Idempotent encoder teardown.
    [_encoder invalidateOnce];

    // Nil out handlers to prevent callbacks after teardown.
    _encoder.frameCompletionHandler = nil;
    _encoder.encodedSampleHandler   = nil;
}

// ─── VGFrameSink — presentEnvelope: ──────────────────────────────────────────

- (void)presentEnvelope:(VGFrameEnvelope)envelope {
    // Guard: sink must be ready and not invalidated.
    if (!_ready || _invalidated) return;
    if (!_encoder.isReady) return;
    if (_writer.status == AVAssetWriterStatusFailed) return;

    CVPixelBufferRef rawBuffer = (CVPixelBufferRef)envelope.payload.videoBuffer;
    if (!rawBuffer) return;

    // ── 1. Wrap CVPixelBuffer in VGRetainedBuffer (DEC-V2-010) ───────────────
    //
    // VGExportScheduler releases the buffer AFTER presentEnvelope: returns.
    // VTCompressionSessionEncodeFrame is async — VT may read the buffer after
    // encodeFrame returns. VGRetainedBuffer provides +1 ARC-managed retain,
    // ensuring the buffer remains valid until the VT callback fires.
    // Released by ARC when this scope exits (after semaphore wait).
    VGRetainedBuffer *retained = [[VGRetainedBuffer alloc]
                                      initWithPixelBuffer:rawBuffer];

    // ── 2. Submit to encoder (async — VT callback fires later) ───────────────
    [_encoder encodePixelBuffer:retained.pixelBuffer
               presentationTime:envelope.pts];

    // ── 3. Block until semaphore signals (exactly once per frame) ─────────────
    //
    //   Success: signal fires in encodedSampleHandler AFTER appendSampleBuffer.
    //   Error/drop: signal fires in frameCompletionHandler (no sample coming).
    //   Timeout: treat as encode error; prevents infinite hang on VT failure.
    intptr_t result = dispatch_semaphore_wait(
        _encodeSemaphore,
        dispatch_time(DISPATCH_TIME_NOW, 5LL * NSEC_PER_SEC));

    if (result != 0) {
        // Timeout — log and continue; encoder may be degraded.
        NSLog(@"[VGVideoEncoderSinkNode] presentEnvelope: semaphore timeout "
              @"(frame %ld) — encoder may have stalled", (long)_framesSubmitted);
    }

    // ── 4. retained released by ARC here ─────────────────────────────────────
    // By this point: VT callback has fired, encoder has consumed the buffer,
    // and (on success) appendSampleBuffer has completed. Safe to release.
    (void)retained;

    _framesSubmitted++;
}

// ─── Private: lazy writer init + append ──────────────────────────────────────

/// Called from encodedSampleHandler on VT callback queue.
/// On first call: creates AVAssetWriterInput with sourceFormatHint, adds to
/// writer, starts writing, starts session, then appends.
/// On subsequent calls: appends directly.
- (void)_appendEncodedSample:(CMSampleBufferRef)sampleBuffer {
    // Guard: writer must be active.
    if (!_writer) return;
    if (_writer.status == AVAssetWriterStatusCancelled ||
        _writer.status == AVAssetWriterStatusFailed) {
        return;
    }

    // ── Lazy writer input creation (first sample only) ────────────────────────
    //
    // Apple: sourceFormatHint provides "additional information for optimal output"
    // when outputSettings is nil (passthrough mode). We use the format description
    // from the first VT-encoded CMSampleBuffer.
    //
    // Apple constraint: addInput must precede startWriting.
    // Therefore: addInput + startWriting + startSessionAtSourceTime are all
    // performed in this lazy block before the first append.
    if (!_writerInput) {
        CMFormatDescriptionRef fmtDesc = CMSampleBufferGetFormatDescription(sampleBuffer);

        // Create passthrough input with sourceFormatHint for optimal MP4 headers.
        _writerInput = [AVAssetWriterInput
            assetWriterInputWithMediaType:AVMediaTypeVideo
                           outputSettings:nil       // passthrough: accepts VT-compressed samples
                         sourceFormatHint:fmtDesc];
        _writerInput.expectsMediaDataInRealTime = NO;  // offline export

        if (![_writer canAddInput:_writerInput]) {
            NSLog(@"[VGVideoEncoderSinkNode] _appendEncodedSample: canAddInput returned NO");
            _writerInput = nil;
            return;
        }
        [_writer addInput:_writerInput];
        [_writer startWriting];
        [_writer startSessionAtSourceTime:kCMTimeZero];
        _writerStarted = YES;
    }

    // ── Append sample ─────────────────────────────────────────────────────────
    //
    // Guard: writer still in writing state (teardown race protection).
    if (_writer.status != AVAssetWriterStatusWriting) return;
    if (!_writerInput.isReadyForMoreMediaData) {
        NSLog(@"[VGVideoEncoderSinkNode] _appendEncodedSample: not ready for media data");
        return;
    }

    BOOL appended = [_writerInput appendSampleBuffer:sampleBuffer];
    if (!appended) {
        NSLog(@"[VGVideoEncoderSinkNode] _appendEncodedSample: appendSampleBuffer failed, "
              @"writer status=%ld error=%@",
              (long)_writer.status, _writer.error);
    }
    // Semaphore is signaled by the caller (encodedSampleHandler) AFTER this returns.
}

// ─── Export finalization ──────────────────────────────────────────────────────

- (nullable VGExportManifest *)finalizeExportWithError:(NSError *_Nullable *_Nullable)outError {
    if (!_ready && !_framesSubmitted) {
        if (outError) {
            *outError = [NSError errorWithDomain:@"VGVideoEncoderSinkNode"
                                            code:20
                                        userInfo:@{
                NSLocalizedDescriptionKey: @"Node was not prepared or no frames submitted"
            }];
        }
        return nil;
    }

    // ── 1. Flush all pending VT callbacks ─────────────────────────────────────
    BOOL flushed = [_encoder completeFrames];
    if (!flushed) {
        NSLog(@"[VGVideoEncoderSinkNode] finalizeExport: completeFrames returned NO");
    }

    // ── 2. Mark writer input finished (no more samples) ───────────────────────
    if (_writerInput) {
        [_writerInput markAsFinished];
    }

    // ── 3. Handle case: no frames written (encoder produced nothing) ──────────
    if (!_writerStarted || !_writerInput) {
        if (outError) {
            *outError = [NSError errorWithDomain:@"VGVideoEncoderSinkNode"
                                            code:21
                                        userInfo:@{
                NSLocalizedDescriptionKey: @"No encoded samples were written"
            }];
        }
        return nil;
    }

    // ── 4. Finish writing (async — block with semaphore, 30s timeout) ─────────
    dispatch_semaphore_t finishSem = dispatch_semaphore_create(0);
    [_writer finishWritingWithCompletionHandler:^{
        dispatch_semaphore_signal(finishSem);
    }];
    intptr_t finishResult = dispatch_semaphore_wait(
        finishSem,
        dispatch_time(DISPATCH_TIME_NOW, 30LL * NSEC_PER_SEC));

    if (finishResult != 0) {
        if (outError) {
            *outError = [NSError errorWithDomain:@"VGVideoEncoderSinkNode"
                                            code:22
                                        userInfo:@{
                NSLocalizedDescriptionKey: @"finishWriting timed out (30s)"
            }];
        }
        return nil;
    }

    if (_writer.status != AVAssetWriterStatusCompleted) {
        if (outError) {
            *outError = _writer.error ?: [NSError errorWithDomain:@"VGVideoEncoderSinkNode"
                                                              code:23
                                                          userInfo:@{
                NSLocalizedDescriptionKey: @"AVAssetWriter did not complete successfully"
            }];
        }
        return nil;
    }

    // ── 5. Build VGExportManifest ─────────────────────────────────────────────
    NSString *codec = (_profile.codecType == kCMVideoCodecType_HEVC) ? @"hevc" : @"h264";

    // Measure actual output file size.
    NSError *attrErr = nil;
    NSDictionary *attrs = [[NSFileManager defaultManager]
                            attributesOfItemAtPath:_outputURL.path
                                             error:&attrErr];
    int64_t fileSizeBytes = (int64_t)[attrs[NSFileSize] longLongValue];

    // Measure duration: use framesSubmitted / fps as approximation.
    NSTimeInterval durationSeconds = (double)_framesSubmitted / (double)MAX(_profile.fps, 1);

    VGExportManifest *manifest = [[VGExportManifest alloc]
        initWithCodec:codec
                width:(int32_t)_profile.width
               height:(int32_t)_profile.height
           bitrateBps:(int32_t)_profile.bitrateBps
                  fps:(int32_t)_profile.fps
           colorRange:@""
           colorSpace:@""
      durationSeconds:durationSeconds
        hasAudioTrack:NO
        fileSizeBytes:fileSizeBytes];

    _ready = NO;  // Finalized — no more frames accepted.
    return manifest;
}

// ─── dealloc ──────────────────────────────────────────────────────────────────

- (void)dealloc {
    [self invalidate];
}

@end

NS_ASSUME_NONNULL_END
