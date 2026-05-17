// VGMetadataNodeAdapter.m
// Phase 3: Adapter only. No runtime wiring.

#import "VGMetadataNodeAdapter.h"
#import "VGSegmentationNode.h"
#import <UMF/VGGraphNodeDescriptor.h>
#import <UMF/VGGraphExecutionContext.h>
#import <UMF/VGMediaFormat.h>

@implementation VGMetadataNodeAdapter

// ─── Designated initialiser ──────────────────────────────────────────────────

- (instancetype)initWithSegmentationNode:(VGSegmentationNode *)node {
    NSParameterAssert(node != nil);
    self = [super init];
    if (!self) return nil;
    _node = node;
    return self;
}

// ─── VGNode — Identity ───────────────────────────────────────────────────────

- (NSString *)nodeId {
    return self.node.nodeId;
}

- (NSString *)nodeClass {
    // Adapter presents itself under its own class name, not the wrapped node's.
    return @"VGMetadataNodeAdapter";
}

- (VGNodeRole)nodeRole {
    // VGNodeRoleMetadata = 4, declared as static const NSInteger in
    // VGGraphNodeDescriptor.h. Cast required because the base NS_ENUM only
    // defines values 0–3. This cast is documented and intentional (Phase 2 design).
    return (VGNodeRole)VGNodeRoleMetadata;
}

// ─── VGNode — Port declaration ────────────────────────────────────────────────

- (NSArray<VGMediaPort *> *)declaredPorts {
    return @[
        [VGMediaPort inputPort:@"video_in"
                    mediaType:VGMediaTypeVideo
                     required:YES],
        [VGMediaPort metadataOutputPort:@"metadata_out"
                                    key:@"com.vanguard.mask.skin"],
    ];
}

// ─── VGNode — Lifecycle ───────────────────────────────────────────────────────

- (void)prepareWithContext:(VGGraphExecutionContext *)context
                completion:(void (^)(NSError * _Nullable))completion {
    // Context is ignored in Phase 3. Delegate to the legacy VGMediaNode surface.
    [self.node prepareWithCompletion:completion];
}

- (void)invalidate {
    [self.node invalidate];
}

// ─── VGNode — Format negotiation (Phase 3 stub) ───────────────────────────────

- (nullable VGMediaFormat *)negotiateFormatForPort:(NSString *)portId
                                      inputFormats:(NSDictionary<NSString *, VGMediaFormat *> *)inputFormats {
    // Phase 3 stub. Format negotiation deferred to Phase 5+.
    return nil;
}

// ─── VGMetadataNode — Envelope enrichment ────────────────────────────────────

- (VGFrameEnvelope)enrichEnvelope:(VGFrameEnvelope)envelope
                            device:(id<MTLDevice>)device {
    // Delegate directly to VGSegmentationNode.processEnvelope:device:.
    // VGSegmentationNode reads the video payload, runs face detection and mask
    // generation, and returns an envelope with metadata attached under
    // @"com.vanguard.mask.skin". The result is returned unchanged.
    return [self.node processEnvelope:envelope device:device];
}

@end
