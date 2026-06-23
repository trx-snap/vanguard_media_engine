// VGVideoEncoderSinkNode.m
// vanguard_media_engine — Phase 5C-4 / Phase 10 encoder pipeline fix
//
// Concrete VGFrameSink: VanguardVideoToolboxEncoder + AVAssetWriter.
//
// Pull-mode only. No VGGraphSchedulerV2. No push callbacks. No camera path.
//
// Key architectural invariants (Phase 10 bounded async path):
//   - presentEnvelope: acquires one in-flight slot (counting semaphore),
//     then returns immediately after encodePixelBuffer: — no per-frame wait.
//   - VGRetainedBuffer stored in _inFlightBuffers until VT callback fires,
//     ensuring CVPixelBuffer lifetime across the async VT boundary.
//   - _inFlightBuffers access is serialized on _inFlightQueue (private serial).
//   - frameCompletionHandler removes the oldest buffer and signals the slot.
//   - encodedSampleHandler appends the encoded sample to AVAssetWriterInput,
//     still called from the VT callback queue (unchanged from legacy path).
//   - AVAssetWriterInput created lazily on first sample with sourceFormatHint:.
//   - finalizeExportWithError: calls completeFrames (synchronous VT drain),
//     then asserts _inFlightBuffers.count == 0 before proceeding.
//
// In-flight semaphore timeout contract (Phase 10 hardening):
//   - If _inFlightSemaphore wait times out (10s), the VT session is assumed dead.
//   - The timeout path calls [self invalidate] (cancels writer, tears down encoder)
//     and returns immediately WITHOUT storing a buffer or submitting to VT.
//   - No slot was acquired, so no signal is emitted — semaphore count stays balanced.
//   - _invalidated = YES causes all subsequent presentEnvelope: calls to no-op.
//   - finalizeExportWithError: returns nil (writer is cancelled) → caller sees failure.
//   - This is fail-fast: producing a truncated/corrupt MP4 is not acceptable.
//
// Legacy synchronous path (kVGUseLegacySynchronousEncoderSink = YES):
//   - presentEnvelope: blocks until the VT callback signals _encodeSemaphore.
//   - Preserved verbatim for rollback safety.
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


// ─── Phase 10 encoder pipeline constants ──────────────────────────────────────

/// Rollback flag. Set to YES to revert to the original synchronous per-frame
/// semaphore wait. Defaults to NO (bounded async path active).
/// Temporary diagnostic — do not commit as permanent production code.
static const BOOL kVGUseLegacySynchronousEncoderSink = NO;

/// Maximum number of frames that may be submitted to VideoToolbox and awaiting
/// their VT callback concurrently. First kVGMaxFramesInFlight frames submit
/// without blocking; subsequent frames block until a callback drains a slot.
/// Cap of 4 covers the B-frame reorder window (2–3 frames) + 1 headroom.
static const NSInteger kVGMaxFramesInFlight = 4;

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

    // ── Legacy synchronous path ───────────────────────────────────────────────
    // Binary semaphore: signals exactly once per frame (legacy path only).
    // In the bounded async path this semaphore is unused.
    dispatch_semaphore_t             _encodeSemaphore;

    // Per-frame encode status (set by frameCompletionHandler before signal)
    OSStatus                         _lastEncodeStatus;
    VTEncodeInfoFlags                _lastEncodeFlags;

    // ── Phase 10 bounded async path ───────────────────────────────────────────
    // Counting semaphore: initialized to kVGMaxFramesInFlight.
    // presentEnvelope: waits (acquires) before submitting each frame.
    // frameCompletionHandler signals (releases) after draining the slot.
    dispatch_semaphore_t             _inFlightSemaphore;

    // Serial queue protecting _inFlightBuffers from concurrent access.
    // Writer thread (scheduler/export queue) appends; VT callback queue removes.
    dispatch_queue_t                 _inFlightQueue;

    // Retained pixel buffers for frames currently in-flight with VideoToolbox.
    // Each entry is a VGRetainedBuffer* that holds +1 CVPixelBuffer retain.
    // Entries are appended in presentEnvelope: and removed (FIFO) in
    // frameCompletionHandler, which fires for every VT callback (success/drop/error).
    NSMutableArray<VGRetainedBuffer *> *_inFlightBuffers;

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

    // Legacy path semaphore (binary — starts at 0, signals once per frame).
    _encodeSemaphore = dispatch_semaphore_create(0);
    _lastEncodeStatus = noErr;
    _lastEncodeFlags  = 0;

    // Bounded async path: counting semaphore + serial protection queue + buffer array.
    _inFlightSemaphore = dispatch_semaphore_create(kVGMaxFramesInFlight);
    _inFlightQueue     = dispatch_queue_create("com.vanguard.encoder.inflight",
                                               DISPATCH_QUEUE_SERIAL);
    _inFlightBuffers   = [NSMutableArray arrayWithCapacity:(NSUInteger)kVGMaxFramesInFlight];



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
    // HANDLER WIRING DIFFERS BY PATH:
    //
    // Legacy path (kVGUseLegacySynchronousEncoderSink = YES):
    //   frameCompletionHandler signals _encodeSemaphore on error/drop.
    //   encodedSampleHandler appends sample, then signals _encodeSemaphore.
    //   presentEnvelope: blocks on _encodeSemaphore after every submit.
    //
    // Bounded async path (kVGUseLegacySynchronousEncoderSink = NO):
    //   frameCompletionHandler removes the oldest VGRetainedBuffer from
    //   _inFlightBuffers and signals _inFlightSemaphore (frees one slot).
    //   encodedSampleHandler appends sample (unchanged — still on VT queue).
    //   presentEnvelope: acquires _inFlightSemaphore before submitting, then
    //   returns immediately without waiting for the VT callback.
    //
    // vtOutputCallback fires in this order (Phase 5B):
    //   1. frameCompletionHandler  — UNCONDITIONAL, FIRST
    //   2. encodedSampleHandler    — SUCCESS ONLY (noErr + no drop)
    //
    // In the bounded async path, the slot is freed in frameCompletionHandler
    // regardless of success/error/drop — this is the correct drain point because
    // frameCompletionHandler fires unconditionally for every submitted frame.

    __weak typeof(self) weakSelf = self;

    if (kVGUseLegacySynchronousEncoderSink) {
        // ── Legacy handler wiring (unchanged from pre-Phase-10 behavior) ──────

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

    } else {
        // ── Bounded async handler wiring ──────────────────────────────────────

        _encoder.frameCompletionHandler = ^(OSStatus status, VTEncodeInfoFlags flags) {
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;

            strongSelf->_lastEncodeStatus = status;
            strongSelf->_lastEncodeFlags  = flags;

            // Remove the oldest in-flight buffer (FIFO — callbacks fire in
            // encode/DTS order, matching submission order).
            // Serialized on _inFlightQueue for thread safety.
            dispatch_sync(strongSelf->_inFlightQueue, ^{
                if (strongSelf->_inFlightBuffers.count > 0) {
                    [strongSelf->_inFlightBuffers removeObjectAtIndex:0];
                }
            });

            // Release one in-flight slot — allows the next blocked
            // presentEnvelope: call (if any) to proceed.
            dispatch_semaphore_signal(strongSelf->_inFlightSemaphore);
        };

        _encoder.encodedSampleHandler = ^(CMSampleBufferRef sampleBuffer) {
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;

            // Append to writer (lazy init on first sample).
            // Still called from the VT callback queue — same as legacy path.
            // appendSampleBuffer: is safe here because it runs serially on the
            // VT callback queue and no other writer appends overlap.
            [strongSelf _appendEncodedSample:sampleBuffer];

            // No semaphore signal here — slot was already freed in
            // frameCompletionHandler (which fired before this handler).
        };
    }

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

    // Drain _inFlightBuffers under the lock so any racing callback
    // that fires after invalidation finds the array empty.
    dispatch_sync(_inFlightQueue, ^{
        [self->_inFlightBuffers removeAllObjects];
    });
}

// ─── VGFrameSink — presentEnvelope: ──────────────────────────────────────────

- (void)presentEnvelope:(VGFrameEnvelope)envelope {
    // Guard: sink must be ready and not invalidated.
    if (!_ready || _invalidated) return;
    if (!_encoder.isReady) return;
    if (_writer.status == AVAssetWriterStatusFailed) return;

    CVPixelBufferRef rawBuffer = (CVPixelBufferRef)envelope.payload.videoBuffer;
    if (!rawBuffer) return;



    if (kVGUseLegacySynchronousEncoderSink) {
        // ═══════════════════════════════════════════════════════════════════════
        // LEGACY SYNCHRONOUS PATH — preserved verbatim for rollback
        // ═══════════════════════════════════════════════════════════════════════

        // ── 1. Wrap CVPixelBuffer in VGRetainedBuffer (DEC-V2-010) ───────────
        //
        // VGExportScheduler releases the buffer AFTER presentEnvelope: returns.
        // VTCompressionSessionEncodeFrame is async — VT may read the buffer after
        // encodeFrame returns. VGRetainedBuffer provides +1 ARC-managed retain,
        // ensuring the buffer remains valid until the VT callback fires.
        // Released by ARC when this scope exits (after semaphore wait).
        VGRetainedBuffer *retained = [[VGRetainedBuffer alloc]
                                          initWithPixelBuffer:rawBuffer];

        // ── 2. Submit to encoder (async — VT callback fires later) ────────────
        [_encoder encodePixelBuffer:retained.pixelBuffer
                   presentationTime:envelope.pts];

        // ── 3. Block until semaphore signals (exactly once per frame) ──────────
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



        // ── 4. retained released by ARC here ──────────────────────────────────
        // By this point: VT callback has fired, encoder has consumed the buffer,
        // and (on success) appendSampleBuffer has completed. Safe to release.
        (void)retained;

        _framesSubmitted++;

    } else {
        // ═══════════════════════════════════════════════════════════════════════
        // BOUNDED ASYNC PATH — Phase 10 encoder pipeline fix
        // ═══════════════════════════════════════════════════════════════════════
        //
        // Model:
        //   - Up to kVGMaxFramesInFlight (4) frames may be in-flight concurrently.
        //   - First 4 frames acquire a slot and return immediately.
        //   - Frame 5 blocks only if no callback has drained a slot yet.
        //   - This ensures VideoToolbox always has enough frames to satisfy
        //     its B-frame reordering window, eliminating the 15-second startup
        //     deadlock caused by the legacy single-frame synchronous wait.
        //
        // Buffer lifetime:
        //   - VGRetainedBuffer holds +1 CVPixelBuffer retain.
        //   - It is stored in _inFlightBuffers until frameCompletionHandler fires.
        //   - frameCompletionHandler removes it (FIFO) — VT is done reading by then.
        //   - ARC releases the VGRetainedBuffer, which releases the CVPixelBuffer.
        //
        // Thread safety:
        //   - _inFlightBuffers is mutated from the export queue (here, in append)
        //     and from the VT callback queue (in frameCompletionHandler remove).
        //   - All accesses are wrapped in dispatch_sync on _inFlightQueue (serial).

        // ── 1. Wrap CVPixelBuffer in VGRetainedBuffer (DEC-V2-010) ───────────
        // Retain BEFORE acquiring the in-flight slot and BEFORE storing in
        // _inFlightBuffers, so the buffer survives any reorder between this call
        // and the VT callback.
        VGRetainedBuffer *retained = [[VGRetainedBuffer alloc]
                                          initWithPixelBuffer:rawBuffer];

        // ── 2. Acquire one in-flight slot (backpressure) ──────────────────────
        //
        // Blocks only when all kVGMaxFramesInFlight slots are occupied.
        // 10-second timeout is a last-resort safety valve: if VT stops firing
        // callbacks (session death), this prevents an infinite hang.
        intptr_t slotResult = dispatch_semaphore_wait(
            _inFlightSemaphore,
            dispatch_time(DISPATCH_TIME_NOW, 10LL * NSEC_PER_SEC));

        if (slotResult != 0) {
            // ── TIMEOUT: in-flight slot was NOT acquired ───────────────────────
            //
            // VT session has stopped firing callbacks. This is a fatal encoder
            // condition. Fail-fast rather than producing a corrupt or truncated MP4:
            //
            //   1. Do NOT store retained in _inFlightBuffers (no slot was acquired).
            //   2. Do NOT submit to VideoToolbox.
            //   3. Do NOT signal _inFlightSemaphore (count is already balanced).
            //   4. Call [self invalidate] to cancel the writer and tear down the
            //      encoder. _invalidated = YES causes all subsequent presentEnvelope:
            //      calls to exit at the top guard. finalizeExportWithError: will
            //      subsequently return nil because the writer is cancelled.
            //
            // Note: frameCompletionHandler will NOT fire for this frame because no
            // submit occurred — so the semaphore count remains correct.
            NSLog(@"[VGVideoEncoderSinkNode] FATAL: in-flight slot timeout "
                  @"(frame %ld, 10s elapsed) — VT session has stalled. "
                  @"Aborting export to prevent corrupt output.",
                  (long)_framesSubmitted);

            // invalidate tears down encoder + writer and sets _invalidated = YES.
            // ARC releases retained here since it was never stored or submitted.
            [self invalidate];
            return;
        }

        // Guard: re-check ready state after potentially blocking on the semaphore.
        // If invalidated while waiting (e.g. by a concurrent cancel), discard this
        // frame safely. The slot was acquired — release it immediately.
        if (_invalidated || !_ready) {
            dispatch_semaphore_signal(_inFlightSemaphore);
            (void)retained;
            return;
        }

        // ── 3. Store retained buffer (must precede encodePixelBuffer:) ─────────
        //
        // The buffer is stored BEFORE encoding so that if the VT callback fires
        // synchronously (possible on some VT configurations), frameCompletionHandler
        // will find a non-empty array. In practice VT callbacks are async, but
        // FIFO ordering is preserved regardless: callbacks fire in DTS order
        // (matching submission order), so removeObjectAtIndex:0 is always correct.
        dispatch_sync(_inFlightQueue, ^{
            [self->_inFlightBuffers addObject:retained];
        });

        // ── 4. Submit to encoder (async — VT callback fires later) ────────────
        [_encoder encodePixelBuffer:retained.pixelBuffer
                   presentationTime:envelope.pts];

        // ── 5. Return immediately — no per-frame wait ─────────────────────────
        //
        // The VT callback (frameCompletionHandler) will:
        //   a. Remove the oldest VGRetainedBuffer from _inFlightBuffers.
        //   b. Signal _inFlightSemaphore to free the slot.
        // The retained buffer survives in _inFlightBuffers until that point.



        _framesSubmitted++;
    }
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


    // In the legacy path: semaphore is signaled by encodedSampleHandler AFTER this returns.
    // In the bounded async path: no semaphore signal here — slot freed in frameCompletionHandler.
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
    //
    // VTCompressionSessionCompleteFrames blocks until every pending VT callback
    // has fired. After this returns:
    //   - All frameCompletionHandler calls have completed.
    //   - All encodedSampleHandler calls have completed.
    //   - All appendSampleBuffer: calls have completed.
    //   - In the bounded async path: _inFlightBuffers must be empty.
    BOOL flushed = [_encoder completeFrames];
    if (!flushed) {
        NSLog(@"[VGVideoEncoderSinkNode] finalizeExport: completeFrames returned NO");
    }

    // ── 1a. Drain invariant check (bounded async path) ────────────────────────
    if (!kVGUseLegacySynchronousEncoderSink) {
        __block NSUInteger remainingCount = 0;
        dispatch_sync(_inFlightQueue, ^{
            remainingCount = self->_inFlightBuffers.count;
        });
        if (remainingCount > 0) {
            // This should never happen: completeFrames guarantees all VT callbacks
            // have fired, which means all frameCompletionHandlers have run, which
            // means all _inFlightBuffers entries have been removed.
            NSLog(@"[VGVideoEncoderSinkNode] finalizeExport: WARNING — %lu in-flight "
                  @"buffers remain after completeFrames (expected 0). "
                  @"Draining defensively.", (unsigned long)remainingCount);
            dispatch_sync(_inFlightQueue, ^{
                [self->_inFlightBuffers removeAllObjects];
            });
        }

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
