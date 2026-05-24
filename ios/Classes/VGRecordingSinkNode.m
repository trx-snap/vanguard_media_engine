// VGRecordingSinkNode.m
// vanguard_media_engine — Phase 6E.1A / Phase 6E.1B / Phase 6E.1C
//
// Phase 6E.1C: Forwarding path wired to VanguardCameraMediaSource.
// presentEnvelope: forwards the processed CVPixelBuffer to the source via
// appendProcessedVideoFrame:pts: when the sink is enabled.
// The sink remains disabled by default (enabled = NO) and graphRecordingEnabled
// on the source also defaults to NO, so this path is unreachable at runtime.

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
    // Return immediately unless the sink is ready and enabled.
    // The sink defaults to disabled (enabled = NO set in init).
    // VGCameraGraphSession has not set enabled = YES in this phase.
    if (!_ready || !self.isEnabled) {
        return;
    }

    // Phase 6E.1C: Extract the processed video buffer from the graph envelope.
    // Envelope payload is +0 — owned by the graph runtime for the duration
    // of this synchronous call. appendProcessedVideoFrame:pts: retains the
    // buffer internally across its own async dispatch to _captureQueue.
    CVPixelBufferRef processedBuffer = envelope.payload.videoBuffer;
    if (!processedBuffer) {
        return;
    }

    // Strongify the weak source reference. _source is __weak; strongifying
    // prevents the source from being deallocated between the nil-check and
    // the method call.
    VanguardCameraMediaSource *source = _source;
    if (!source) {
        return;
    }

    // Delegate encoding to the source. The source gates on graphRecordingEnabled
    // (defaults NO) and _recordingState internally, then dispatches to
    // _captureQueue. No retain or dispatch happens in this node.
    [source appendProcessedVideoFrame:processedBuffer pts:envelope.pts];
}

// ─── State ────────────────────────────────────────────────────────────────────

- (BOOL)isReady {
    return _ready;
}

@end
