// VGPhotoSinkNode.m
// vanguard_media_engine — Phase 6E.2A
//
// Phase 6E.2A: Skeleton only. presentEnvelope: is an unconditional no-op.
// No arming, buffer retention, encoding, dispatch, or file I/O is present.
// This node exists solely to establish the fan-out topology slot that
// Phase 6E.2B will activate with one-shot arming and JPEG capture.

#import "VGPhotoSinkNode.h"
#import <UMF/VGGraphExecutionContext.h>
#import <UMF/VGMediaFormat.h>

@implementation VGPhotoSinkNode {
    NSString *_nodeId;
    BOOL _ready;
}

// ─── Initializers ─────────────────────────────────────────────────────────────

- (nullable instancetype)initWithNodeId:(NSString *)nodeId {
    if (nodeId == nil || nodeId.length == 0) {
        return nil;
    }
    self = [super init];
    if (self) {
        _nodeId = [nodeId copy];
        // Live camera fan-out sinks are not prepared by the scheduler;
        // this skeleton has no async setup — mark ready immediately.
        _ready = YES;
    }
    return self;
}

// ─── VGNode Protocol Identity ─────────────────────────────────────────────────

- (NSString *)nodeId {
    return _nodeId;
}

- (NSString *)nodeClass {
    return @"VGPhotoSinkNode";
}

- (VGNodeRole)nodeRole {
    return VGNodeRoleSink;
}

// ─── VGNode Protocol Ports ────────────────────────────────────────────────────

- (NSArray<VGMediaPort *> *)declaredPorts {
    return @[
        [VGMediaPort inputPort:@"video_in"
                    mediaType:VGMediaTypeVideo
                     required:YES],
    ];
}

// ─── VGNode Protocol Lifecycle ────────────────────────────────────────────────

- (void)prepareWithContext:(VGGraphExecutionContext *)context
                completion:(void (^)(NSError * _Nullable))completion {
    NSParameterAssert(completion != nil);
    // Phase 6E.2A: No resources to initialize.
    // Mark ready and return immediately with no error.
    _ready = YES;
    completion(nil);
}

- (void)invalidate {
    // Phase 6E.2A: No resources to release.
    _ready = NO;
}

// ─── VGNode Protocol Format Negotiation ───────────────────────────────────────

- (nullable VGMediaFormat *)negotiateFormatForPort:(NSString *)portId
                                      inputFormats:(NSDictionary<NSString *, VGMediaFormat *> *)inputFormats {
    // Sink has no output ports to negotiate.
    return nil;
}

// ─── VGFrameSink Protocol Frame Presentation ──────────────────────────────────

- (void)presentEnvelope:(VGFrameEnvelope)envelope {
    // Phase 6E.2A: Unconditional no-op skeleton.
    // Do not inspect, retain, dispatch, encode, or write the buffer.
    // Phase 6E.2B will add one-shot arming and JPEG capture here.
    return;
}

// ─── State ────────────────────────────────────────────────────────────────────

- (BOOL)isReady {
    return _ready;
}

@end
