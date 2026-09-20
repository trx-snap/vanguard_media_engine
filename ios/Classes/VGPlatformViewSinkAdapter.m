// VGPlatformViewSinkAdapter.m
// vanguard_media_engine — Phase 6B-POC2
//
// Implementation of VGPlatformViewSinkAdapter.

#import "VGPlatformViewSinkAdapter.h"
#import <UMF/VGGraphExecutionContext.h>
#import <UMF/VGMediaFormat.h>
#import <CoreVideo/CoreVideo.h>

@implementation VGPlatformViewSinkAdapter {
    // One-shot log flag — logs the first graph frame delivered, then never again.
    BOOL _poc2FirstFrameLogged;
}

// ─── Designated initializer ────────────────────────────────────────────────────

- (instancetype)initWithReceiver:(id<VanguardCameraFrameReceiver>)receiver {
    NSParameterAssert(receiver != nil);
    self = [super init];
    if (!self) return nil;
    _receiver = receiver;
    _poc2FirstFrameLogged = NO;
    return self;
}

// ─── VGNode — Identity ────────────────────────────────────────────────────────

- (NSString *)nodeId {
    return @"platform_view_sink";
}

- (NSString *)nodeClass {
    return @"VGPlatformViewSinkAdapter";
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
    // No setup required. Receiver preparation is performed externally.
    // Complete asynchronously to satisfy VGNode contract.
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
        completion(nil);
    });
}

- (void)invalidate {
    // No-op. Receiver lifecycle is managed externally.
}

// ─── VGNode — Format negotiation ─────────────────────────────────────────────

- (nullable VGMediaFormat *)negotiateFormatForPort:(NSString *)portId
                                      inputFormats:(NSDictionary<NSString *, VGMediaFormat *> *)inputFormats {
    // Phase stub. No format negotiation required for POC2.
    return nil;
}

// ─── VGFrameSink — Frame presentation ────────────────────────────────────────

- (void)presentEnvelope:(VGFrameEnvelope)envelope {
    // Guard: video frames only.
    if (envelope.mediaType != VGMediaTypeVideo) return;

    // Load weak receiver as strong local. If receiver was deallocated, drop silently.
    id<VanguardCameraFrameReceiver> r = self.receiver;
    if (!r) return;

    // Extract CVPixelBufferRef. Per VGFrameEnvelope contract, payload.videoBuffer
    // is a void* cast of a CVPixelBufferRef at +0. We cast it and pass at +0 to
    // onFrame:pts: — the receiver retains what it keeps (VanguardCameraPlatformView
    // via Swift ARC on assignment to latestBuffer; the Duet graph provider via an
    // explicit +1). No extra CVPixelBufferRetain needed here.
    CVPixelBufferRef pixelBuffer = (CVPixelBufferRef)envelope.payload.videoBuffer;
    if (!pixelBuffer) return;

    // One-shot log — first graph frame delivered to the receiver sink.
    if (!_poc2FirstFrameLogged) {
        _poc2FirstFrameLogged = YES;
        NSLog(@"[Vanguard] first graph frame delivered to processed-frame receiver sink ✓");
    }

    // Forward to the receiver's onFrame:pts:.
    // This call is on com.vanguard.cameraGraphExecution (graph exec queue) —
    // onFrame:pts: performs a fast os_unfair_lock swap and returns immediately.
    [r onFrame:pixelBuffer pts:envelope.pts];
}

@end
