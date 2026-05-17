// VGImageSourceAdapter.m
// Phase 3: Adapter only. No runtime wiring.

#import "VGImageSourceAdapter.h"
#import "VanguardImageMediaSource.h"
#import <UMF/VGGraphExecutionContext.h>
#import <UMF/VGMediaFormat.h>
#import <UMF/VGFrameEnvelope.h>
#import <UMF/VGFrameRequest.h>
#import <UMF/VGFrameResult.h>
#import <CoreVideo/CoreVideo.h>

@implementation VGImageSourceAdapter

// ─── Designated initialiser ──────────────────────────────────────────────────

- (instancetype)initWithSource:(VanguardImageMediaSource *)source {
    NSParameterAssert(source != nil);
    self = [super init];
    if (!self) return nil;
    _source = source;
    return self;
}

// ─── VGNode — Identity ───────────────────────────────────────────────────────

- (NSString *)nodeId {
    return self.source.nodeId;
}

- (NSString *)nodeClass {
    return self.source.nodeType;
}

- (VGNodeRole)nodeRole {
    return VGNodeRoleSource;
}

// ─── VGNode — Port declaration ────────────────────────────────────────────────

- (NSArray<VGMediaPort *> *)declaredPorts {
    return @[
        [VGMediaPort outputPort:@"video_out"
                     mediaType:VGMediaTypeVideo],
    ];
}

// ─── VGNode — Lifecycle ───────────────────────────────────────────────────────

- (void)prepareWithContext:(VGGraphExecutionContext *)context
                completion:(void (^)(NSError * _Nullable))completion {
    // Context is ignored in Phase 3. Delegate to the legacy VGMediaNode surface.
    // VanguardImageMediaSource.prepareWithCompletion: decodes the image
    // asynchronously on a USER_INITIATED queue and fires completion on that queue.
    [self.source prepareWithCompletion:completion];
}

- (void)invalidate {
    [self.source invalidate];
}

// ─── VGNode — Format negotiation (Phase 3 stub) ───────────────────────────────

- (nullable VGMediaFormat *)negotiateFormatForPort:(NSString *)portId
                                      inputFormats:(NSDictionary<NSString *, VGMediaFormat *> *)inputFormats {
    // Phase 3 stub. Format negotiation deferred to Phase 5+.
    return nil;
}

// ─── VGSourceNode — Push-mode (no-op for single-frame image source) ───────────

- (void)startProducing {
    // No-op. VanguardImageMediaSource is a pull-only source.
    // The image is decoded during prepareWithCompletion: and accessed via pullFrame:.
}

- (void)stopProducing {
    // No-op. No push-mode emission to cease.
}

// ─── VGSourceNode — Pull-mode ─────────────────────────────────────────────────

- (VGFrameResult *)pullFrame:(VGFrameRequest *)request {
    // 1. Cancellation check — must happen before any expensive work.
    if (request.isCancelled) {
        return [VGFrameResult skippedWithGeneration:request.generation];
    }

    // 2. Acquire buffer.
    // copyRawBuffer returns a +1 CVPixelBufferRef via CVPixelBufferRetain
    // (verified: VanguardImageMediaSource.m line 334).
    // Returns NULL before prepareWithCompletion: succeeds or after invalidation.
    CVPixelBufferRef buf = [self.source copyRawBuffer];
    if (!buf) {
        NSError *err = [NSError errorWithDomain:@"VGImageSourceAdapter"
                                           code:1
                                       userInfo:@{
            NSLocalizedDescriptionKey:
                @"copyRawBuffer returned NULL — source not yet prepared or invalidated"
        }];
        return [VGFrameResult errorResult:err generation:request.generation];
    }

    // 3. Construct envelope.
    // All creation sites must zero-initialise (VGFrameEnvelope.h mandate).
    VGFrameEnvelope envelope;
    memset(&envelope, 0, sizeof(VGFrameEnvelope));
    envelope.pts        = request.requestedPTS;
    envelope.dts        = request.requestedPTS;
    envelope.duration   = kCMTimeIndefinite; // static images hold indefinitely
    envelope.generation = request.generation;
    envelope.mediaType  = VGMediaTypeVideo;
    envelope.payload.videoBuffer = (void *)buf;
    envelope.metadata   = NULL;

    // 4. Return delivered result.
    //
    // Buffer ownership transfer:
    //   copyRawBuffer returned a +1 CVPixelBufferRef. That +1 is now held by
    //   envelope.payload.videoBuffer. The adapter does NOT release buf here.
    //   The VGFrameResult consumer (Phase 4 scheduler) is responsible for
    //   calling CVPixelBufferRelease(envelope.payload.videoBuffer) when the
    //   frame is no longer needed.
    //   Phase 4 must validate the complete runtime release path before
    //   graph activation (RR-V2-003).
    return [VGFrameResult deliveredWithEnvelope:envelope
                                     generation:request.generation];
}

// ─── VGSourceNode — Seek ──────────────────────────────────────────────────────

- (void)seekTo:(CMTime)time generation:(uint64_t)generation {
    // No-op. VanguardImageMediaSource is a single-frame source; it always
    // returns the same image regardless of PTS. The generation change is
    // acknowledged implicitly — subsequent pullFrame: calls carry the new
    // generation in their request.
}

@end
