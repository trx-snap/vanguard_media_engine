// VGCameraSourceAdapter.m
// Phase 3: Adapter only. No runtime wiring.

#import "VGCameraSourceAdapter.h"
#import "VanguardCameraMediaSource.h"
#import <UMF/VGGraphExecutionContext.h>
#import <UMF/VGMediaFormat.h>
#import <UMF/VGFrameRequest.h>
#import <UMF/VGFrameResult.h>

@implementation VGCameraSourceAdapter

// ─── Designated initialiser ──────────────────────────────────────────────────

- (instancetype)initWithSource:(VanguardCameraMediaSource *)source {
    NSParameterAssert(source != nil);
    self = [super init];
    if (!self) return nil;
    _source = source;
    return self;
}

// ─── VGNode — Identity ───────────────────────────────────────────────────────

- (NSString *)nodeId {
    // VanguardCameraMediaSource does NOT conform to VGMediaNode and therefore
    // has no nodeId property. Synthesise a stable constant that uniquely
    // identifies this node class within a graph session.
    return @"camera_source";
}

- (NSString *)nodeClass {
    // Adapter presents itself under its own class name. The wrapped camera
    // source does not have a VGMediaNode identity surface.
    return @"VGCameraSourceAdapter";
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
    // Phase 3 stub. VanguardCameraMediaSource configures its AVCaptureSession
    // at init time (_configureSession). No warm-up work is needed here.
    // Camera lifecycle is managed externally by the Flutter plugin/runtime.
    // Fire completion(nil) asynchronously to satisfy the VGNode contract
    // that completion never fires synchronously on the caller's thread.
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
        completion(nil);
    });
}

- (void)invalidate {
    // No-op. VanguardCameraMediaSource lifecycle is managed externally by
    // the plugin (teardownCurrentMode). Calling stop() here would interfere
    // with the plugin's own orderly teardown sequence.
}

// ─── VGNode — Format negotiation (Phase 3 stub) ───────────────────────────────

- (nullable VGMediaFormat *)negotiateFormatForPort:(NSString *)portId
                                      inputFormats:(NSDictionary<NSString *, VGMediaFormat *> *)inputFormats {
    // Phase 3 stub. Format negotiation deferred to Phase 5+.
    return nil;
}

// ─── VGSourceNode — Push-mode production ─────────────────────────────────────

- (void)startProducing {
    // Delegates to VanguardMediaSource.start which calls
    // [_session startRunning] on the AVCaptureSession. The session then
    // begins delivering frames via captureOutput:didOutputSampleBuffer:
    // on _captureQueue (.userInteractive, serial).
    // VanguardCameraMediaSource.start asserts the session is not already running
    // (I-2 guard) — the caller must ensure stop was called before re-starting.
    [self.source start];
}

- (void)stopProducing {
    // Delegates to VanguardMediaSource.stop which stops the watchdog timer,
    // finalises any active recording, stops the AVCaptureSession, and releases
    // _latestBuffer under os_unfair_lock.
    [self.source stop];
}

// ─── VGSourceNode — Pull-mode (Phase 3 stub) ─────────────────────────────────

- (VGFrameResult *)pullFrame:(VGFrameRequest *)request {
    // Camera is a push-only live source. AVCaptureVideoDataOutputSampleBufferDelegate
    // delivers frames at hardware capture rate — there is no mechanism to produce
    // a frame at an arbitrary output-timeline PTS.
    //
    // Returning VGFrameStatusSkipped (not error) is semantically correct:
    //   - Skipped means "no frame available for this PTS window" — which is
    //     precisely the case for a live source in a pull request context.
    //   - Error would indicate a non-recoverable failure, which is not the case.
    //
    // In Phase 4, the scheduler will recognise VGClockPolicyPush for camera
    // nodes and never call pullFrame:. The push path is entirely driven by
    // startProducing/stopProducing + the existing _videoCallback mechanism.
    return [VGFrameResult skippedWithGeneration:request.generation];
}

// ─── VGSourceNode — Seek ──────────────────────────────────────────────────────

- (void)seekTo:(CMTime)time generation:(uint64_t)generation {
    // No-op. Camera is a live source with no concept of timeline position.
    // This mirrors VanguardCameraMediaSource.seekTo: which is explicitly
    // documented as a no-op for live sources in VanguardMediaSource.h.
}

@end
