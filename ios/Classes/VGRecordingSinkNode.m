// VGRecordingSinkNode.m
// vanguard_media_engine — Phase 6E.1A / Phase 6E.1B
//
// Phase 6E.1B: Wired into VGFanOutSink via VGCameraGraphFactory (disabled).
// All VGFrameSink/VGNode protocol methods remain behavior-neutral.
// presentEnvelope: returns immediately unless ready and enabled.
// No frames are forwarded, retained, or encoded in this step.

#import "VGRecordingSinkNode.h"
#import "VanguardCameraMediaSource.h"
#import <UMF/VGGraphExecutionContext.h>
#import <UMF/VGMediaFormat.h>

@implementation VGRecordingSinkNode {
    NSString *_nodeId;
    __weak VanguardCameraMediaSource *_source;
    BOOL _ready;
}

// ─── Initializers ─────────────────────────────────────────────────────────────

- (nullable instancetype)initWithNodeId:(NSString *)nodeId
                                 source:(VanguardCameraMediaSource *)source {
    if (nodeId == nil || nodeId.length == 0) {
        return nil;
    }
    if (source == nil) {
        return nil;
    }
    self = [super init];
    if (self) {
        _nodeId = [nodeId copy];
        _source = source;
        _ready = NO;
        _enabled = NO;
    }
    return self;
}

// ─── VGNode Protocol Identity ─────────────────────────────────────────────────

- (NSString *)nodeId {
    return _nodeId;
}

- (NSString *)nodeClass {
    return @"VGRecordingSinkNode";
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
    // Phase 6E.1A: No resources to initialize.
    // Mark ready and return immediately with no error.
    _ready = YES;
    NSLog(@"[VGRecordingSinkNode] Phase 6E.1A skeleton ready — frame forwarding not yet implemented.");
    completion(nil);
}

- (void)invalidate {
    // Phase 6E.1A: No resources to release.
    _ready = NO;
    _enabled = NO;
}

// ─── VGNode Protocol Format Negotiation ───────────────────────────────────────

- (nullable VGMediaFormat *)negotiateFormatForPort:(NSString *)portId
                                      inputFormats:(NSDictionary<NSString *, VGMediaFormat *> *)inputFormats {
    // Sink has no output ports to negotiate.
    return nil;
}

// ─── VGFrameSink Protocol Frame Presentation ──────────────────────────────────

- (void)presentEnvelope:(VGFrameEnvelope)envelope {
    // Phase 6E.1A: Return immediately unless ready and enabled.
    // No frames are forwarded, retained, or encoded in this step.
    // Future Phase 6E.1 steps will add bounded async handoff and processed-frame recording.
    if (!_ready || !self.isEnabled) {
        return;
    }
}

// ─── State ────────────────────────────────────────────────────────────────────

- (BOOL)isReady {
    return _ready;
}

@end
