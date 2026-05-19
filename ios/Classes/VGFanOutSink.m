// VGFanOutSink.m
// vanguard_media_engine — Phase 6A-1
//
// Implementation of VGFanOutSink.

#import "VGFanOutSink.h"
#import <UMF/VGGraphExecutionContext.h>
#import <UMF/VGMediaFormat.h>

@implementation VGFanOutSink

// ─── Initializers ─────────────────────────────────────────────────────────────

- (nullable instancetype)initWithNodeId:(NSString *)nodeId
                                  sinks:(NSArray<id<VGFrameSink>> *)sinks {
    if (nodeId == nil || nodeId.length == 0) {
        return nil;
    }
    if (sinks == nil || sinks.count == 0) {
        return nil;
    }
    for (id child in sinks) {
        if (child == nil || ![child conformsToProtocol:@protocol(VGFrameSink)]) {
            return nil;
        }
    }
    self = [super init];
    if (self) {
        _nodeId = [nodeId copy];
        _sinks = [sinks copy];
    }
    return self;
}

- (nullable instancetype)initWithSinks:(NSArray<id<VGFrameSink>> *)sinks {
    return [self initWithNodeId:@"fan_out_sink" sinks:sinks];
}

// ─── VGNode Protocol Identity ─────────────────────────────────────────────────

- (NSString *)nodeClass {
    return @"VGFanOutSink";
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

    dispatch_group_t group = dispatch_group_create();
    __block NSError *lastError = nil;
    // Lock for protecting lastError write
    __block os_unfair_lock errorLock = OS_UNFAIR_LOCK_INIT;

    for (id<VGFrameSink> child in self.sinks) {
        dispatch_group_enter(group);
        [child prepareWithContext:context completion:^(NSError * _Nullable error) {
            if (error) {
                os_unfair_lock_lock(&errorLock);
                lastError = error;
                os_unfair_lock_unlock(&errorLock);
            }
            dispatch_group_leave(group);
        }];
    }

    dispatch_group_notify(group, dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
        completion(lastError);
    });
}

- (void)invalidate {
    for (id<VGFrameSink> child in self.sinks) {
        [child invalidate];
    }
}

// ─── VGNode Protocol Format Negotiation ───────────────────────────────────────

- (nullable VGMediaFormat *)negotiateFormatForPort:(NSString *)portId
                                      inputFormats:(NSDictionary<NSString *, VGMediaFormat *> *)inputFormats {
    // Sink has no output ports to negotiate.
    return nil;
}

// ─── VGFrameSink Protocol Frame Presentation ──────────────────────────────────

- (void)presentEnvelope:(VGFrameEnvelope)envelope {
    // Synchronously forward the unmodified envelope to each child in order.
    // As per VGFrameSink protocol guidelines:
    // "Ownership: The envelope is delivered at +0. If the sink needs to retain
    // the payload pointer beyond this call, it MUST call CVPixelBufferRetain."
    // VGFanOutSink does not hold onto the envelope past this call and does not retain it.
    for (id<VGFrameSink> child in self.sinks) {
        [child presentEnvelope:envelope];
    }
}

@end
