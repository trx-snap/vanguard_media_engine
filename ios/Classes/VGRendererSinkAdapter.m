// VGRendererSinkAdapter.m
// Phase 3: Adapter only. No runtime wiring.

#import "VGRendererSinkAdapter.h"
#import "VanguardMetalRenderer.h"
#import <UMF/VGGraphExecutionContext.h>
#import <UMF/VGMediaFormat.h>

@implementation VGRendererSinkAdapter

// ─── Designated initialiser ──────────────────────────────────────────────────

- (instancetype)initWithRenderer:(VanguardMetalRenderer *)renderer {
    NSParameterAssert(renderer != nil);
    self = [super init];
    if (!self) return nil;
    _renderer = renderer;
    return self;
}

// ─── VGNode — Identity ───────────────────────────────────────────────────────

- (NSString *)nodeId {
    // VanguardMetalRenderer has no nodeId property. Synthesise a stable constant.
    return @"renderer_sink";
}

- (NSString *)nodeClass {
    return @"VGRendererSinkAdapter";
}

- (VGNodeRole)nodeRole {
    return VGNodeRoleSink;
}

// ─── VGNode — Port declaration ────────────────────────────────────────────────

- (NSArray<VGMediaPort *> *)declaredPorts {
    return @[
        [VGMediaPort inputPort:@"video_in"
                    mediaType:VGMediaTypeVideo
                     required:YES],
    ];
}

// ─── VGNode — Lifecycle ───────────────────────────────────────────────────────

- (void)prepareWithContext:(VGGraphExecutionContext *)context
                completion:(void (^)(NSError * _Nullable))completion {
    // Phase 3 stub. Renderer is prepared externally by VanguardGraphRuntime.
    // Complete asynchronously to satisfy the VGNode contract that completion
    // never fires synchronously on the caller's thread.
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
        completion(nil);
    });
}

- (void)invalidate {
    // No-op. Renderer teardown is managed externally by VanguardGraphRuntime.
    // Do NOT call renderer.dispose here — the renderer lifetime is not owned
    // by this adapter.
}

// ─── VGNode — Format negotiation (Phase 3 stub) ───────────────────────────────

- (nullable VGMediaFormat *)negotiateFormatForPort:(NSString *)portId
                                      inputFormats:(NSDictionary<NSString *, VGMediaFormat *> *)inputFormats {
    // Phase 3 stub. Format negotiation deferred to Phase 5+.
    return nil;
}

// ─── VGFrameSink — Frame presentation ────────────────────────────────────────

- (void)presentEnvelope:(VGFrameEnvelope)envelope {
    // Load the weak reference once into a strong local to guarantee stability
    // for the duration of this call.
    VanguardMetalRenderer *r = self.renderer;
    if (!r) {
        // Renderer has been deallocated. Drop the envelope silently.
        return;
    }
    // Delegate to VanguardMetalRenderer.presentEnvelope: (P4-4, line 136).
    // The renderer retains the CVPixelBuffer, swaps it under os_unfair_lock,
    // and dispatches textureFrameAvailable: to the main queue.
    [r presentEnvelope:envelope];
}

@end
