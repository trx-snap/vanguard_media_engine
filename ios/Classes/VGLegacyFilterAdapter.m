// VGLegacyFilterAdapter.m
// Phase 3: Adapter only. No runtime wiring.

#import "VGLegacyFilterAdapter.h"
#import <UMF/VGMetalFilterNode.h>
#import <UMF/VGGraphExecutionContext.h>
#import <UMF/VGMediaFormat.h>

@implementation VGLegacyFilterAdapter

// ─── Designated initialiser ──────────────────────────────────────────────────

- (instancetype)initWithFilter:(id<VGMetalFilterNode>)filter {
    NSParameterAssert(filter != nil);
    self = [super init];
    if (!self) return nil;
    _filter = filter;
    return self;
}

// ─── VGNode — Identity ───────────────────────────────────────────────────────

- (NSString *)nodeId {
    return self.filter.nodeId;
}

- (NSString *)nodeClass {
    // VGMetalFilterNode inherits nodeType from VGMediaNode.
    // nodeClass in V2 corresponds to nodeType in V1.
    return self.filter.nodeType;
}

- (VGNodeRole)nodeRole {
    return VGNodeRoleFilter;
}

// ─── VGNode — Port declaration ────────────────────────────────────────────────

- (NSArray<VGMediaPort *> *)declaredPorts {
    return @[
        [VGMediaPort inputPort:@"video_in"
                    mediaType:VGMediaTypeVideo
                     required:YES],
        [VGMediaPort outputPort:@"video_out"
                     mediaType:VGMediaTypeVideo],
    ];
}

// ─── VGNode — Lifecycle ───────────────────────────────────────────────────────

- (void)prepareWithContext:(VGGraphExecutionContext *)context
                completion:(void (^)(NSError * _Nullable))completion {
    // Context is ignored in Phase 3. Delegate to the legacy VGMediaNode surface.
    [self.filter prepareWithCompletion:completion];
}

- (void)invalidate {
    [self.filter invalidate];
}

// ─── VGNode — Format negotiation (Phase 3 stub) ───────────────────────────────

- (nullable VGMediaFormat *)negotiateFormatForPort:(NSString *)portId
                                      inputFormats:(NSDictionary<NSString *, VGMediaFormat *> *)inputFormats {
    // Phase 3 stub. Format negotiation deferred to Phase 5+.
    return nil;
}

// ─── VGTransformNode — Control ────────────────────────────────────────────────

- (BOOL)enabled {
    return self.filter.enabled;
}

- (void)setEnabled:(BOOL)enabled {
    self.filter.enabled = enabled;
}

- (float)estimatedGPUCostMs {
    return self.filter.estimatedGPUCostMs;
}

// ─── VGTransformNode — Frame processing ──────────────────────────────────────

- (VGFrameEnvelope)processEnvelope:(VGFrameEnvelope)envelope
                             device:(id<MTLDevice>)device {
    // Direct delegation. Signature is identical on VGMetalFilterNode and
    // VGTransformNode. No transformation required.
    return [self.filter processEnvelope:envelope device:device];
}

@end
