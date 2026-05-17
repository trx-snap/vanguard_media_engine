// VGFileSourceAdapter.m
// Phase 3: Adapter only. No runtime wiring.

#import "VGFileSourceAdapter.h"
#import "VanguardFileMediaSource.h"
#import <UMF/VGGraphExecutionContext.h>
#import <UMF/VGMediaFormat.h>
#import <UMF/VGFrameRequest.h>
#import <UMF/VGFrameResult.h>

@implementation VGFileSourceAdapter

// ─── Designated initialiser ──────────────────────────────────────────────────

- (instancetype)initWithSource:(VanguardFileMediaSource *)source {
    NSParameterAssert(source != nil);
    self = [super init];
    if (!self) return nil;
    _source = source;
    return self;
}

// ─── VGNode — Identity ───────────────────────────────────────────────────────

- (NSString *)nodeId {
    // VanguardFileMediaSource conforms to VGMediaNode and assigns a NSUUID
    // at init time. The ID is stable and unique within a graph session.
    return self.source.nodeId;
}

- (NSString *)nodeClass {
    // nodeClass in V2 corresponds to nodeType in the V1 VGMediaNode protocol.
    // VanguardFileMediaSource.nodeType is always @"VanguardFileMediaSource".
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
    // Context is ignored in Phase 3. Delegate to VGMediaNode.prepareWithCompletion:
    // which pre-warms the AVAssetReader on _videoDecodeQueue and fires completion
    // on that background queue (never synchronously — guards RR-6/RR-8).
    [self.source prepareWithCompletion:completion];
}

- (void)invalidate {
    // Delegates to VGMediaNode.invalidate which uses an atomic CAS (_Atomic BOOL)
    // to ensure idempotency. Tears down AVAssetReader and audio engine.
    [self.source invalidate];
}

// ─── VGNode — Format negotiation (Phase 3 stub) ───────────────────────────────

- (nullable VGMediaFormat *)negotiateFormatForPort:(NSString *)portId
                                      inputFormats:(NSDictionary<NSString *, VGMediaFormat *> *)inputFormats {
    // Phase 3 stub. Format negotiation deferred to Phase 5+.
    return nil;
}

// ─── VGSourceNode — Push-mode production ─────────────────────────────────────

- (void)startProducing {
    // Delegates to VanguardMediaSource.start which pre-warms the AVAssetReader
    // (if not already warmed at init) and schedules the AVAudioEngine with a
    // deferred 1200ms startup (G-02-T3 fix). Safe to call multiple times —
    // VanguardFileMediaSource.start is guarded by _started flag.
    [self.source start];
}

- (void)stopProducing {
    // Delegates to VanguardMediaSource.stop which cancels the AVAssetReader
    // synchronously (thread-safe per Apple docs) and tears down the audio engine.
    [self.source stop];
}

// ─── VGSourceNode — Pull-mode (Phase 3 stub) ─────────────────────────────────

- (VGFrameResult *)pullFrame:(VGFrameRequest *)request {
    // Phase 3 stub. VanguardFileMediaSource has no synchronous pull API.
    //
    // Frame production is entirely callback-based:
    //   readNextFrameForPlayback → fires _videoCallback on _videoDecodeQueue
    //   pullNextFrameAsync / pullNextFrameAsyncWithCompletion: → async wrappers
    //
    // Callback-to-sync conversion (semaphore/dispatch_sync) is UNSAFE in Phase 3:
    //   - Risk of deadlock with _videoDecodeQueue (serial, .userInitiated)
    //   - Would block V2 scheduler's pull queue
    //   - Requires no modification to VanguardFileMediaSource (no sync API exists)
    //
    // In Phase 4, the scheduler will drive the file source exclusively via
    // startProducing/stopProducing (push-mode) and never call pullFrame:.
    // Pull-mode integration for export requires a new VGExportFileSourceNode
    // backed by AVAssetReader with direct copyNextSampleBuffer access.
    NSError *err = [NSError errorWithDomain:@"VGFileSourceAdapter"
                                       code:1
                                   userInfo:@{
        NSLocalizedDescriptionKey:
            @"Pull-mode not available — file source is push-only. "
             "Use startProducing/stopProducing. Phase 4 required "
             "for V2 pull-mode integration."
    }];
    return [VGFrameResult errorResult:err generation:request.generation];
}

// ─── VGSourceNode — Seek ──────────────────────────────────────────────────────

- (void)seekTo:(CMTime)time generation:(uint64_t)generation {
    // Forward only the time. The V2 generation parameter is not propagated.
    //
    // VanguardFileMediaSource maintains its own internal _seekGeneration
    // (NSUInteger) which is incremented on each seekToTime: call to discard
    // stale in-flight AVAssetImageGenerator completions. The V2 generation
    // (uint64_t, graph-global, reset at each session start) is a different
    // concept. Unification of the two generation systems is deferred to Phase 4.
    [self.source seekTo:time];
}

@end
